// Selective undo/redo for a text type, ported from yjs v13.6.31
// `utils/UndoManager.js`. Captures each tracked transaction as a StackItem
// (inserted id ranges + deleted id ranges); undo deletes what was inserted and
// re-creates what was deleted, redo does the inverse. Deleted items are `keep`-ed
// so the GC preserves their content for re-creation.
//
// The scope is a set of root text types and the types nested in them (yjs `scope`, an array of
// types). Stack items are yjs `DeleteSet`s and are walked like
// `iterateDeletedStructs`, so the order in which items are re-created — and with it the clocks
// and bytes of every undo/redo — follows yjs.

import Synchronization

final class NativeUndoManager {
    private struct StackItem {
        var insertions: DeleteSet
        var deletions: DeleteSet
    }

    private let doc: NativeDoc
    /// The scope's root names, for the capture check against `changedParentRootNames`.
    private let scopeNames: Set<String>
    /// The scope's root types, for the item check. A root is never replaced in `NativeDoc.share`,
    /// so its identity is stable for the manager's lifetime.
    private let scopeRoots: Set<ObjectIdentifier>
    private let trackedOrigins: Set<Origin>
    private let captureTimeout: Duration
    private let managerOrigin: Origin
    private var afterTransactionID: Int?

    private var undoStack: [StackItem] = []
    private var redoStack: [StackItem] = []
    private var undoing = false
    private var redoing = false
    private var lastChange: ContinuousClock.Instant?

    private static let counter = Mutex(0)

    /// `scopeNames` must not be empty; a name listed twice counts once (`addToScope`).
    init(doc: NativeDoc, scopeNames: [String], trackedOrigins: Set<Origin>, captureTimeoutMillis: UInt64) {
        let uid = Self.counter.withLock { count -> Int in
            count += 1
            return count
        }
        self.doc = doc
        self.scopeNames = Set(scopeNames)
        self.scopeRoots = Set(scopeNames.map { ObjectIdentifier(doc.get($0)) })
        self.managerOrigin = Origin("__undo_manager_\(uid)")
        // The manager's own undo/redo transactions must be tracked so their inverse
        // is captured onto the opposite stack.
        self.trackedOrigins = trackedOrigins.union([self.managerOrigin])
        self.captureTimeout = .milliseconds(captureTimeoutMillis)
        self.afterTransactionID = doc.onAfterTransaction { [weak self] info in self?.capture(info) }
    }

    deinit {
        if let id = self.afterTransactionID { self.doc.removeAfterTransactionHandler(id) }
    }

    var canUndo: Bool { !self.undoStack.isEmpty }
    var canRedo: Bool { !self.redoStack.isEmpty }

    func stopCapturing() { self.lastChange = nil }

    @discardableResult
    func undo() -> Bool {
        self.undoing = true
        defer { self.undoing = false }
        return self.popStackItem(fromRedo: false)
    }

    @discardableResult
    func redo() -> Bool {
        self.redoing = true
        defer { self.redoing = false }
        return self.popStackItem(fromRedo: true)
    }

    // MARK: Capture

    private func capture(_ info: NativeDoc.TransactionInfo) {
        // `scope.some(type => transaction.changedParentTypes.has(type))`.
        guard !self.scopeNames.isDisjoint(with: info.changedParentRootNames) else { return }
        guard let origin = info.origin, self.trackedOrigins.contains(origin) else { return }

        if self.undoing {
            self.stopCapturing()  // the next undo must start a fresh redo step
        } else if !self.redoing {
            self.clearRedoStack()  // a fresh edit invalidates the redo stack
        }

        // `transaction.afterState` iterates the store's clients in insertion order.
        var insertions = DeleteSet()
        for client in self.doc.store.clientOrder {
            let before = info.beforeState[client] ?? 0
            if let after = info.afterState[client], after > before { insertions.add(client, before, after - before) }
        }
        // `transaction.deleteSet`, sorted and merged by the transaction cleanup before yjs calls
        // `afterTransaction` handlers.
        let deletions = info.deleteSet

        let now = ContinuousClock.now
        if self.undoing {
            self.redoStack.append(StackItem(insertions: insertions, deletions: deletions))
        } else if self.redoing {
            self.undoStack.append(StackItem(insertions: insertions, deletions: deletions))
        } else {
            let canMerge =
                self.lastChange.map { now - $0 < self.captureTimeout } ?? false
            if canMerge, let last = self.undoStack.last {
                self.undoStack[self.undoStack.count - 1] = StackItem(
                    insertions: last.insertions.merged(with: insertions),
                    deletions: last.deletions.merged(with: deletions)
                )
            } else {
                self.undoStack.append(StackItem(insertions: insertions, deletions: deletions))
            }
            self.lastChange = now
        }

        // Protect deleted content in scope from GC so it can be re-created on redo/undo.
        var inScope: [ObjectIdentifier: Bool] = [:]
        self.iterateDeletedStructs(deletions) { s in
            if let item = s as? Item, self.isInScope(item, &inScope) { Self.keepItem(item, true) }
        }
    }

    /// `clear(false, true)`: drops the redo stack and lifts its protection from GC — of its deleted
    /// items in scope and, through `keepItem`, of their parent items — so a later delete collects
    /// them as in yjs. Yjs runs it in a transaction of its own that changes no content; its splits
    /// are merged here with those of the transaction being captured, which merges the same structs.
    private func clearRedoStack() {
        var inScope: [ObjectIdentifier: Bool] = [:]
        for stackItem in self.redoStack {
            self.iterateDeletedStructs(stackItem.deletions) { s in
                if let item = s as? Item, self.isInScope(item, &inScope) { Self.keepItem(item, false) }
            }
        }
        self.redoStack.removeAll()
    }

    // MARK: Pop

    /// `popStackItem`: pops stack items until one changes the document.
    private func popStackItem(fromRedo: Bool) -> Bool {
        let store = self.doc.store
        var performedAny = false
        self.doc.transact(origin: self.managerOrigin) {
            while !performedAny, let stackItem = fromRedo ? self.redoStack.popLast() : self.undoStack.popLast() {
                var itemsToRedo: [Item] = []
                var redoSet = Set<ObjectIdentifier>()
                var itemsToDelete: [Item] = []
                var inScope: [ObjectIdentifier: Bool] = [:]
                self.iterateDeletedStructs(stackItem.insertions) { s in
                    guard var item = s as? Item else { return }
                    if item.redone != nil {
                        // The insertion was deleted and re-created since: act on the copy.
                        let (redone, diff) = self.followRedone(item.id)
                        var next = redone
                        if diff > 0 {
                            next = store.getItemCleanStart(YID(client: next.id.client, clock: next.id.clock + diff))
                        }
                        guard let nextItem = next as? Item else { return }
                        item = nextItem
                    }
                    if !item.deleted, self.isInScope(item, &inScope) { itemsToDelete.append(item) }
                }
                self.iterateDeletedStructs(stackItem.deletions) { s in
                    // Never redo what the same step inserted: it was created and deleted within it.
                    guard let item = s as? Item, self.isInScope(item, &inScope), !stackItem.insertions.contains(item.id)
                    else {
                        return
                    }
                    if redoSet.insert(ObjectIdentifier(item)).inserted { itemsToRedo.append(item) }
                }
                for item in itemsToRedo
                where self.redoItem(item, redoSet, itemsToDelete: stackItem.insertions) != nil {
                    performedAny = true
                }
                // Delete in reverse order so children are deleted before their parents.
                for item in itemsToDelete.reversed() {
                    store.deleteItem(item)
                    performedAny = true
                }
            }
        }
        return performedAny
    }

    // MARK: yjs helpers

    /// `iterateDeletedStructs`: calls `body` for every struct in `set`, splitting items at the
    /// range edges so only the covered part is visited. The store arrays are re-read after
    /// every call because `body` may split items too.
    private func iterateDeletedStructs(_ set: DeleteSet, _ body: (Struct) -> Void) {
        let store = self.doc.store
        for entry in set.clients {
            guard store.clients[entry.client]?.isEmpty == false else { continue }
            let clockState = store.getState(entry.client)
            for range in entry.ranges {
                guard range.clock < clockState else { break }
                guard range.length > 0 else { continue }
                // `iterateStructs`
                let clockEnd = range.clock + range.length
                var index = store.findIndexCleanStart(entry.client, range.clock)
                while true {
                    let s = store.clients[entry.client]![index]
                    index += 1
                    if clockEnd < s.id.clock + s.length { _ = store.findIndexCleanStart(entry.client, clockEnd) }
                    body(s)
                    let structs = store.clients[entry.client]!
                    guard index < structs.count, structs[index].id.clock < clockEnd else { break }
                }
            }
        }
    }

    /// Scope check (`scope.some(type => isParentOf(type, item))`): the item lives in one of this
    /// manager's texts or in a type nested inside one. Every scope type is a root, so `isParentOf`
    /// holds for one of them exactly when the item's topmost type is in the scope. `known` keeps the
    /// answer for every type climbed through, so that the items of one walk climb the nesting they
    /// share once rather than once each: deeply nested items made each walk quadratic.
    private func isInScope(_ item: Item, _ known: inout [ObjectIdentifier: Bool]) -> Bool {
        var climbed: [ObjectIdentifier] = []
        var type = item.parent
        var inScope = false
        while let current = type {
            let id = ObjectIdentifier(current)
            if self.scopeRoots.contains(id) {
                inScope = true
                break
            }
            if let answer = known[id] {
                inScope = answer
                break
            }
            climbed.append(id)
            type = current.item?.parent
        }
        for id in climbed { known[id] = inScope }
        return inScope
    }

    /// `keepItem`: protects the item and its parent items from GC, or lifts that protection, up to
    /// the first one already in the requested state.
    private static func keepItem(_ item: Item, _ keep: Bool) {
        var current: Item? = item
        while let next = current, next.keep != keep {
            next.setKeep(keep)
            current = next.parent?.item
        }
    }

    /// `followRedone`: the latest copy of the item at `id` and the offset of `id` inside it. A chain of
    /// copies that leads back into itself, which a malformed update can build, ends at the first repeat.
    private func followRedone(_ id: YID) -> (item: Struct, diff: UInt64) {
        var nextID: YID? = id
        var diff: UInt64 = 0
        var item: Struct
        var seen = Set<ObjectIdentifier>()
        repeat {
            let current = nextID!
            if diff > 0 { nextID = YID(client: current.client, clock: current.clock + diff) }
            item = self.doc.store.getItem(nextID!)
            diff = nextID!.clock - item.id.clock
            nextID = (item as? Item)?.redone
        } while nextID != nil && item is Item && seen.insert(ObjectIdentifier(item)).inserted
        return (item, diff)
    }

    /// `redoItem` (yjs `structs/Item.js`): re-creates a deleted item at its old position — right
    /// before the original, after the nearest left neighbour that lives in the same parent — and
    /// returns the copy, or the existing copy if the item was already re-created.
    ///
    /// Yjs first redoes a deleted parent by recursing into it; the chain of deleted parents is
    /// collected here instead and redone outermost first, without a stack frame per level.
    private func redoItem(_ item: Item, _ redoItems: Set<ObjectIdentifier>, itemsToDelete: DeleteSet) -> Struct? {
        if let redone = item.redone { return self.doc.store.getItemCleanStart(redone) }
        var chain = [item]
        while let parent = chain.last?.parent?.item, parent.deleted, parent.redone == nil {
            // A deleted parent this step does not redo cannot be redone, nor anything inside it.
            guard redoItems.contains(ObjectIdentifier(parent)) else { return nil }
            chain.append(parent)
        }
        var redone: Struct?
        for item in chain.reversed() {
            redone = self.redoItem(item, itemsToDelete: itemsToDelete)
            if redone == nil { return nil }
        }
        return redone
    }

    /// `redoItem` for an item whose parent is not deleted or already redone.
    ///
    /// A malformed update can link lists and key chains into each other so that the `redone`, `left` and
    /// `right` links followed here lead back to where they started, where yjs loops without end. Each
    /// walk stops at the first item it reaches twice, and the item then cannot be redone.
    private func redoItem(_ item: Item, itemsToDelete: DeleteSet) -> Struct? {
        let store = self.doc.store
        if let redone = item.redone { return store.getItemCleanStart(redone) }
        guard let itemParent = item.parent else { return nil }
        var parentItem = itemParent.item
        if let deletedParent = parentItem, deletedParent.deleted {
            guard deletedParent.redone != nil else { return nil }
            var seen = Set<ObjectIdentifier>()
            while let current = parentItem, let redone = current.redone {
                guard seen.insert(ObjectIdentifier(current)).inserted else { return nil }
                parentItem = store.getItemCleanStart(redone) as? Item
            }
        }
        let parentType: YTypeImpl
        if let parentItem {
            guard case .type(let type, _, _) = parentItem.content else { return nil }
            parentType = type
        } else {
            parentType = itemParent
        }

        /// Follows `redone` links from `start` until an item in the (re-created) parent is found.
        func traceToParent(_ start: Item) -> Item? {
            var trace: Item? = start
            var seen = Set<ObjectIdentifier>()
            while let current = trace, current.parent?.item !== parentItem {
                guard seen.insert(ObjectIdentifier(current)).inserted else { return nil }
                trace = current.redone.flatMap { store.getItemCleanStart($0) as? Item }
            }
            return trace
        }

        var left: Item?
        var right: Item?
        if item.parentSub == nil {
            // An array item: insert at the old position.
            left = item.left as? Item
            right = item
            var seenLeft = Set<ObjectIdentifier>()
            while let current = left {
                guard seenLeft.insert(ObjectIdentifier(current)).inserted else { return nil }
                if let trace = traceToParent(current) {
                    left = trace
                    break
                }
                left = current.left as? Item
            }
            var seenRight = Set<ObjectIdentifier>()
            while let current = right {
                guard seenRight.insert(ObjectIdentifier(current)).inserted else { return nil }
                if let trace = traceToParent(current) {
                    right = trace
                    break
                }
                right = current.right as? Item
            }
        } else if let parentSub = item.parentSub {
            if item.right != nil {
                left = item
                var seen: Set<ObjectIdentifier> = [ObjectIdentifier(item)]
                // Skip right neighbours that are re-created or deleted by this or a stacked step: the
                // item is meant to replace them.
                while let current = left, let next = current.right as? Item,
                    next.redone != nil || itemsToDelete.contains(next.id)
                        || self.undoStack.contains(where: { $0.deletions.contains(next.id) })
                        || self.redoStack.contains(where: { $0.deletions.contains(next.id) })
                {
                    guard seen.insert(ObjectIdentifier(next)).inserted else { return nil }
                    left = next
                    while let current = left, let redone = current.redone {
                        left = store.getItemCleanStart(redone) as? Item
                        if let copy = left, !seen.insert(ObjectIdentifier(copy)).inserted { return nil }
                    }
                }
                // A newer value from another client wins; the item cannot be redone.
                if left?.right != nil { return nil }
            } else {
                left = parentType.map[parentSub]
            }
            // Drop a cross-parent left so its origin does not mislead other peers.
            if let current = left, current.parent?.item !== parentItem { left = parentType.map[parentSub] }
        }

        var content = item.content
        if case .type(_, let typeRef, let name) = content {
            // ContentType.copy: a fresh, empty type of the same kind.
            content = .type(YTypeImpl(name: name), typeRef: typeRef, name: name)
        }
        let newItem = Item(
            id: YID(client: self.doc.clientID, clock: store.getState(self.doc.clientID)),
            origin: left?.lastId,
            rightOrigin: right?.id,
            parent: parentType,
            parentID: nil,
            parentSub: item.parentSub,
            content: content
        )
        item.redone = newItem.id
        Self.keepItem(newItem, true)
        newItem.left = left
        newItem.right = right
        newItem.integrate(store, offset: 0)
        return newItem
    }
}
