// Selective undo/redo for a text type, ported from yjs v13.6.31
// `utils/UndoManager.js`. Captures each tracked transaction as a StackItem
// (inserted id ranges + deleted id ranges); undo deletes what was inserted and
// re-creates what was deleted, redo does the inverse. Deleted items are `keep`-ed
// so the GC preserves their content for re-creation.
//
// The scope is one root text type and the types nested in it. Stack items are yjs `DeleteSet`s and are walked like
// `iterateDeletedStructs`, so the order in which items are re-created — and with it the clocks
// and bytes of every undo/redo — follows yjs.

import Synchronization

final class NativeUndoManager {
    /// yjs `DeleteSet`: id ranges per client, clients in the order they were first added (a JS
    /// `Map`), ranges clock-ascending and merged once `sortAndMerge` has run.
    private struct DeleteSet {
        var clients: [(client: UInt64, ranges: [(clock: UInt64, length: UInt64)])] = []

        /// `addToDeleteSet`.
        mutating func add(_ client: UInt64, _ clock: UInt64, _ length: UInt64) {
            if let index = self.clients.firstIndex(where: { $0.client == client }) {
                self.clients[index].ranges.append((clock, length))
            } else {
                self.clients.append((client, [(clock, length)]))
            }
        }

        /// `sortAndMergeDeleteSet`.
        mutating func sortAndMerge() {
            for index in self.clients.indices {
                var merged: [(clock: UInt64, length: UInt64)] = []
                for range in self.clients[index].ranges.sorted(by: { $0.clock < $1.clock }) {
                    if let last = merged.last, last.clock + last.length >= range.clock {
                        let length = max(last.length, range.clock + range.length - last.clock)
                        merged[merged.count - 1] = (last.clock, length)
                    } else {
                        merged.append(range)
                    }
                }
                self.clients[index].ranges = merged
            }
        }

        /// `mergeDeleteSets([self, other])`.
        func merged(with other: DeleteSet) -> DeleteSet {
            var result = DeleteSet()
            for entry in self.clients {
                let tail = other.clients.first { $0.client == entry.client }?.ranges ?? []
                result.clients.append((entry.client, entry.ranges + tail))
            }
            for entry in other.clients where !self.clients.contains(where: { $0.client == entry.client }) {
                result.clients.append(entry)
            }
            result.sortAndMerge()
            return result
        }

        /// `isDeleted`.
        func contains(_ id: YID) -> Bool {
            guard let entry = self.clients.first(where: { $0.client == id.client }) else { return false }
            return entry.ranges.contains { id.clock >= $0.clock && id.clock < $0.clock + $0.length }
        }
    }

    private struct StackItem {
        var insertions: DeleteSet
        var deletions: DeleteSet
    }

    private let doc: NativeDoc
    private let typeName: String
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

    init(doc: NativeDoc, typeName: String, trackedOrigins: Set<Origin>, captureTimeoutMillis: UInt64) {
        let uid = Self.counter.withLock { count -> Int in
            count += 1
            return count
        }
        self.doc = doc
        self.typeName = typeName
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
        guard info.changedNames.contains(self.typeName) else { return }
        guard let origin = info.origin, self.trackedOrigins.contains(origin) else { return }

        if self.undoing {
            self.stopCapturing()  // the next undo must start a fresh redo step
        } else if !self.redoing {
            self.redoStack.removeAll()  // a fresh edit invalidates the redo stack
        }

        // `transaction.afterState` iterates the store's clients in insertion order.
        var insertions = DeleteSet()
        for client in self.doc.store.clientOrder {
            let before = info.beforeState[client] ?? 0
            if let after = info.afterState[client], after > before { insertions.add(client, before, after - before) }
        }
        // `transaction.deleteSet`, sorted and merged by the transaction cleanup before yjs calls
        // `afterTransaction` handlers.
        var deletions = DeleteSet()
        for delete in info.deletes { deletions.add(delete.client, delete.clock, delete.length) }
        deletions.sortAndMerge()

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
        self.iterateDeletedStructs(deletions) { s in
            if let item = s as? Item, self.isInScope(item) { Self.keepItem(item) }
        }
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
                    if !item.deleted, self.isInScope(item) { itemsToDelete.append(item) }
                }
                self.iterateDeletedStructs(stackItem.deletions) { s in
                    // Never redo what the same step inserted: it was created and deleted within it.
                    guard let item = s as? Item, self.isInScope(item), !stackItem.insertions.contains(item.id)
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

    /// Scope check (`isParentOf(scope, item)`): the item lives in this manager's text or in a
    /// type nested inside it.
    private func isInScope(_ item: Item) -> Bool {
        let scope = self.doc.get(self.typeName)
        var child: Item? = item
        while let current = child {
            if current.parent === scope { return true }
            child = current.parent?.item
        }
        return false
    }

    /// `keepItem(item, true)`: protects the item and its parent items from GC.
    private static func keepItem(_ item: Item) {
        var current: Item? = item
        while let next = current, !next.keep {
            next.setKeep(true)
            current = next.parent?.item
        }
    }

    /// `followRedone`: the latest copy of the item at `id` and the offset of `id` inside it.
    private func followRedone(_ id: YID) -> (item: Struct, diff: UInt64) {
        var nextID: YID? = id
        var diff: UInt64 = 0
        var item: Struct
        repeat {
            let current = nextID!
            if diff > 0 { nextID = YID(client: current.client, clock: current.clock + diff) }
            item = self.doc.store.getItem(nextID!)
            diff = nextID!.clock - item.id.clock
            nextID = (item as? Item)?.redone
        } while nextID != nil && item is Item
        return (item, diff)
    }

    /// `redoItem` (yjs `structs/Item.js`): re-creates a deleted item at its old position — right
    /// before the original, after the nearest left neighbour that lives in the same parent — and
    /// returns the copy, or the existing copy if the item was already re-created.
    private func redoItem(_ item: Item, _ redoItems: Set<ObjectIdentifier>, itemsToDelete: DeleteSet) -> Struct? {
        let store = self.doc.store
        if let redone = item.redone { return store.getItemCleanStart(redone) }
        guard let itemParent = item.parent else { return nil }
        var parentItem = itemParent.item
        // Make sure the parent is redone.
        if let deletedParent = parentItem, deletedParent.deleted {
            if deletedParent.redone == nil,
                !redoItems.contains(ObjectIdentifier(deletedParent))
                    || self.redoItem(deletedParent, redoItems, itemsToDelete: itemsToDelete) == nil
            {
                return nil
            }
            while let redone = parentItem?.redone { parentItem = store.getItemCleanStart(redone) as? Item }
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
            while let current = trace, current.parent?.item !== parentItem {
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
            while let current = left {
                if let trace = traceToParent(current) {
                    left = trace
                    break
                }
                left = current.left as? Item
            }
            while let current = right {
                if let trace = traceToParent(current) {
                    right = trace
                    break
                }
                right = current.right as? Item
            }
        } else if let parentSub = item.parentSub {
            if item.right != nil {
                left = item
                // Skip right neighbours that are re-created or deleted by this or a stacked step: the
                // item is meant to replace them.
                while let current = left, let next = current.right as? Item,
                    next.redone != nil || itemsToDelete.contains(next.id)
                        || self.undoStack.contains(where: { $0.deletions.contains(next.id) })
                        || self.redoStack.contains(where: { $0.deletions.contains(next.id) })
                {
                    left = next
                    while let redone = left?.redone { left = store.getItemCleanStart(redone) as? Item }
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
        Self.keepItem(newItem)
        newItem.left = left
        newItem.right = right
        newItem.integrate(store, offset: 0)
        return newItem
    }
}
