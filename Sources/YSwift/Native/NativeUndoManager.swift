// Selective undo/redo for a text type, ported from yjs v13.6.31
// `utils/UndoManager.js`. Captures each tracked transaction as a StackItem
// (inserted id ranges + deleted id ranges); undo deletes what was inserted and
// re-creates what was deleted, redo does the inverse. Deleted items are `keep`-ed
// so the GC preserves their content for re-creation.
//
// Scoped to a single text type and list content; complex multi-level redo tracing
// and map/xml scopes are simplified.

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
                for item in toRedo where self.redoItem(item) != nil { performed = true }

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

    /// Re-creates a deleted item at its original position (`redoItem`), returning the
    /// new item (or nil if it can't be redone).
    private func redoItem(_ item: Item) -> Item? {
        if let redone = item.redone { return self.doc.store.getItem(redone) as? Item }
        guard let parent = item.parent else { return nil }

        var left = item.left as? Item
        while let current = left, let redone = current.redone { left = self.doc.store.getItem(redone) as? Item }
        let right = item.right as? Item

        let newItem = Item(
            id: YID(client: self.doc.clientID, clock: self.doc.store.getState(self.doc.clientID)),
            origin: left?.lastId,
            rightOrigin: right?.id,
            parent: parent,
            parentID: nil,
            parentSub: item.parentSub,
            content: item.content
        )
        item.redone = newItem.id
        newItem.setKeep(true)
        newItem.left = left
        newItem.right = right
        newItem.integrate(self.doc.store, offset: 0)
        return newItem
    }
}
