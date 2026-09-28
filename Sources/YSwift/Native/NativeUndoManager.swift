// Selective undo/redo for a text type, ported from yjs v13.6.31
// `utils/UndoManager.js`. Captures each tracked transaction as a StackItem
// (inserted id ranges + deleted id ranges); undo deletes what was inserted and
// re-creates what was deleted, redo does the inverse. Deleted items are `keep`-ed
// so the GC preserves their content for re-creation.
//
// Scoped to a single text type; map/xml scopes are simplified.

import Synchronization

final class NativeUndoManager {
    private struct StackItem {
        var insertions: [(client: UInt64, clock: UInt64, length: UInt64)]
        var deletions: [(client: UInt64, clock: UInt64, length: UInt64)]
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

        var insertions: [(client: UInt64, clock: UInt64, length: UInt64)] = []
        for (client, after) in info.afterState {
            let before = info.beforeState[client] ?? 0
            if after > before { insertions.append((client, before, after - before)) }
        }

        let now = ContinuousClock.now
        if self.undoing {
            self.redoStack.append(StackItem(insertions: insertions, deletions: info.deletes))
        } else if self.redoing {
            self.undoStack.append(StackItem(insertions: insertions, deletions: info.deletes))
        } else {
            let canMerge =
                self.lastChange.map { now - $0 < self.captureTimeout } ?? false
            if canMerge, !self.undoStack.isEmpty {
                self.undoStack[self.undoStack.count - 1].insertions += insertions
                self.undoStack[self.undoStack.count - 1].deletions += info.deletes
            } else {
                self.undoStack.append(StackItem(insertions: insertions, deletions: info.deletes))
            }
            self.lastChange = now
        }

        // Protect deleted content from GC so it can be re-created on redo/undo.
        for item in self.items(in: info.deletes) { item.setKeep(true) }
    }

    // MARK: Pop

    private func popStackItem(fromRedo: Bool) -> Bool {
        var performedAny = false
        self.doc.transact(origin: self.managerOrigin) {
            while true {
                let stackItem: StackItem? = fromRedo ? self.redoStack.popLast() : self.undoStack.popLast()
                guard let stackItem else { break }
                var performed = false

                let toRedo = self.items(in: stackItem.deletions).filter { item in
                    !stackItem.insertions.contains {
                        $0.client == item.id.client && item.id.clock >= $0.clock
                            && item.id.clock < $0.clock + $0.length
                    }
                }
                let redoSet = Set(toRedo.map(ObjectIdentifier.init))
                for item in toRedo where self.redoItem(item, redoSet, itemsToDelete: stackItem.insertions) != nil {
                    performed = true
                }

                for item in self.items(in: stackItem.insertions).reversed() where !item.deleted {
                    self.doc.store.deleteItem(item)
                    performed = true
                }

                if performed {
                    performedAny = true
                    break
                }
            }
        }
        return performedAny
    }

    /// Items overlapping the given id ranges (no mid-item split; adequate for
    /// boundary-aligned text ranges).
    private func items(in ranges: [(client: UInt64, clock: UInt64, length: UInt64)]) -> [Item] {
        var result: [Item] = []
        for range in ranges {
            guard let structs = self.doc.store.clients[range.client] else { continue }
            let end = range.clock + range.length
            for s in structs where s.id.clock < end && s.id.clock + s.length > range.clock {
                if let item = s as? Item { result.append(item) }
            }
        }
        return result
    }

    /// `isDeleted`: whether `id` falls inside one of the ranges.
    private static func contains(_ ranges: [(client: UInt64, clock: UInt64, length: UInt64)], _ id: YID) -> Bool {
        ranges.contains { $0.client == id.client && id.clock >= $0.clock && id.clock < $0.clock + $0.length }
    }

    /// `keepItem(item, true)`: protects the item and its parent items from GC.
    private static func keepItem(_ item: Item) {
        var current: Item? = item
        while let next = current, !next.keep {
            next.setKeep(true)
            current = next.parent?.item
        }
    }

    /// `redoItem` (yjs `structs/Item.js`): re-creates a deleted item at its old position — right
    /// before the original, after the nearest left neighbour that lives in the same parent — and
    /// returns the copy, or the existing copy if the item was already re-created.
    private func redoItem(
        _ item: Item,
        _ redoItems: Set<ObjectIdentifier>,
        itemsToDelete: [(client: UInt64, clock: UInt64, length: UInt64)]
    ) -> Struct? {
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
                    next.redone != nil || Self.contains(itemsToDelete, next.id)
                        || self.undoStack.contains(where: { Self.contains($0.deletions, next.id) })
                        || self.redoStack.contains(where: { Self.contains($0.deletions, next.id) })
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
