// The pure-Swift document engine core: applies a decoded v1 update into the arena
// store and materialises text / state vectors. Ports yjs `utils/encoding.js`
// (`readClientsStructRefs` + `integrateStructs` + the struct/delete-set apply
// order of `readUpdateV2`). Updates that causally depend on data not yet present
// are buffered and retried as later updates arrive (see `pendingUpdates`), so
// out-of-order / partial delivery converges.

import Synchronization

/// One client's not-yet-integrated structs plus a cursor, matching the
/// `{ i, refs }` records in yjs `readClientsStructRefs`.
private final class ClientRefs {
    var i = 0
    let refs: [Struct]
    init(refs: [Struct]) { self.refs = refs }
}

final class NativeDoc {
    let clientID: UInt64
    /// When false, deleted content is kept verbatim (no GC to `ContentDeleted`) —
    /// matches `new Y.Doc({ gc: false })`.
    let gc: Bool
    let store = NativeStore()
    /// Root types by name (yjs `doc.share`).
    private(set) var share: [String: YTypeImpl] = [:]

    init(clientID: UInt64 = 0, gc: Bool = true) {
        self.clientID = clientID
        self.gc = gc
    }

    /// Fetches or creates the root type `name` (yjs `doc.get`).
    func get(_ name: String) -> YTypeImpl {
        if let existing = share[name] { return existing }
        let type = YTypeImpl(name: name)
        self.share[name] = type
        return type
    }

    /// A locally-editable text handle over root type `name`.
    func text(_ name: String) -> NativeText {
        NativeText(doc: self, type: self.get(name))
    }

    private var txnDepth = 0
    private var txnBeforeState: [UInt64: UInt64] = [:]
    private var txnOrigin: Origin?

    /// Update handlers, behind their own lock so `removeUpdateHandler` (called from
    /// a `YSubscription.cancel()` that can't reach `YDoc.sync`) never races
    /// registration or commit-time iteration.
    private struct HandlerBook {
        var next = 0
        var list: [(id: Int, handler: @Sendable ([UInt8], Origin?) -> Void)] = []
    }
    private let handlers = Mutex(HandlerBook())

    /// Registers a handler fired with each transaction's v1 update (yjs `on('update')`).
    /// Returns an id for `removeUpdateHandler`.
    @discardableResult
    func onUpdate(_ handler: @escaping @Sendable ([UInt8], Origin?) -> Void) -> Int {
        self.handlers.withLock { book in
            let id = book.next
            book.next += 1
            book.list.append((id, handler))
            return id
        }
    }

    func removeUpdateHandler(_ id: Int) {
        self.handlers.withLock { $0.list.removeAll { $0.id == id } }
    }

    /// Opens (or joins) a transaction. Only the outermost `begin`/`commit` pair
    /// snapshots state, cleans up, and emits — nested ops just join it.
    func beginTransaction(origin: Origin? = nil) {
        if self.txnDepth == 0 {
            self.txnBeforeState = self.store.snapshotState()
            self.store.deleteLog = []
            self.txnOrigin = origin
        }
        self.txnDepth += 1
    }

    /// Closes a transaction; on the outermost close, cleans up (GC deleted content +
    /// merge structs) and emits the transaction's incremental update.
    func commitTransaction() {
        guard self.txnDepth > 0 else { return }
        self.txnDepth -= 1
        guard self.txnDepth == 0 else { return }
        self.store.cleanup(gc: self.gc)
        let deletes = self.store.deleteLog ?? []
        self.store.deleteLog = nil
        let origin = self.txnOrigin
        self.txnOrigin = nil

        // Snapshot handlers under the lock, then invoke them WITHOUT holding it (a
        // handler may register/cancel or open a transaction — the lock isn't reentrant).
        let snapshot = self.handlers.withLock { $0.list }
        guard !snapshot.isEmpty else { return }
        if let update = self.encodeTransactionUpdate(beforeState: self.txnBeforeState, deletes: deletes) {
            for entry in snapshot { entry.handler(update, origin) }
        }
    }

    /// Runs a local edit inside a transaction, cleaning up and emitting on the
    /// outermost call. Nested calls join the active transaction.
    func transact(origin: Origin? = nil, _ body: () -> Void) {
        self.beginTransaction(origin: origin)
        body()
        self.commitTransaction()
    }

    /// Encodes the update emitted by a transaction: structs added since
    /// `beforeState` plus the transaction's own (sorted, merged) delete set. Returns
    /// nil when nothing changed (`writeUpdateMessageFromTransaction`).
    private func encodeTransactionUpdate(
        beforeState: [UInt64: UInt64], deletes: [(client: UInt64, clock: UInt64, length: UInt64)]
    ) -> [UInt8]? {
        let structsChanged = self.store.clients.keys.contains { self.store.getState($0) != (beforeState[$0] ?? 0) }
        guard structsChanged || !deletes.isEmpty else { return nil }
        var encoder = Lib0Encoder()
        self.writeClientsStructs(&encoder, target: beforeState)
        self.writeTransactionDeleteSet(&encoder, deletes)
        return encoder.bytes
    }

    private func writeTransactionDeleteSet(
        _ encoder: inout Lib0Encoder, _ deletes: [(client: UInt64, clock: UInt64, length: UInt64)]
    ) {
        var byClient: [UInt64: [(clock: UInt64, length: UInt64)]] = [:]
        for delete in deletes { byClient[delete.client, default: []].append((delete.clock, delete.length)) }
        var perClient: [(client: UInt64, ranges: [(clock: UInt64, length: UInt64)])] = []
        for (client, ranges) in byClient {
            let sorted = ranges.sorted { $0.clock < $1.clock }
            var merged: [(clock: UInt64, length: UInt64)] = []
            for range in sorted {
                if let last = merged.last, last.clock + last.length >= range.clock {
                    let end = max(last.clock + last.length, range.clock + range.length)
                    merged[merged.count - 1] = (last.clock, end - last.clock)
                } else {
                    merged.append(range)
                }
            }
            perClient.append((client, merged))
        }
        perClient.sort { $0.client > $1.client }
        encoder.writeVarUint(UInt64(perClient.count))
        for entry in perClient {
            encoder.writeVarUint(entry.client)
            encoder.writeVarUint(UInt64(entry.ranges.count))
            for range in entry.ranges {
                encoder.writeVarUint(range.clock)
                encoder.writeVarUint(range.length)
            }
        }
    }

    // MARK: Apply

    /// Updates that could not fully integrate yet (they reference structs/clocks
    /// not present). Retried as later updates arrive, so out-of-order or partial
    /// delivery converges (the role of yjs `pendingStructs` / `pendingDs`).
    private var pendingUpdates: [[UInt8]] = []

    /// Decodes and integrates a v1 update; buffers and retries anything that
    /// depends on data not yet present.
    func applyUpdate(_ bytes: [UInt8]) throws {
        if try self.integrate(bytes) { self.pendingUpdates.append(bytes) }
        try self.retryPending()
    }

    /// Integrates one update in place. Returns true if some structs or deletes were
    /// left unapplied (missing causal dependencies).
    private func integrate(_ bytes: [UInt8]) throws -> Bool {
        let parsed = try UpdateCodec.readUpdate(bytes)
        let refs = self.buildClientRefs(parsed.clientBlocks)
        let structsDropped = self.integrateStructs(refs)
        let deletesDropped = self.store.applyDeleteSet(parsed.deleteSet)
        return structsDropped || deletesDropped
    }

    /// Re-applies buffered updates until a full pass integrates nothing new. Each
    /// re-application is idempotent (already-present structs are skipped by offset;
    /// re-deletes are no-ops), and a fully-integrated update leaves the buffer.
    private func retryPending() throws {
        guard !self.pendingUpdates.isEmpty else { return }
        while true {
            let before = self.store.integratedCount
            var stillPending: [[UInt8]] = []
            for update in self.pendingUpdates {
                if try self.integrate(update) { stillPending.append(update) }
            }
            self.pendingUpdates = stillPending
            if self.pendingUpdates.isEmpty || self.store.integratedCount == before { break }
        }
    }

    /// Turns parsed `ClientBlock`s into integrable structs, resolving root-key
    /// parents eagerly (as `readClientsStructRefs` does via `doc.get`).
    private func buildClientRefs(_ blocks: [ClientBlock]) -> [UInt64: ClientRefs] {
        var result: [UInt64: ClientRefs] = [:]
        for block in blocks {
            var structs: [Struct] = []
            structs.reserveCapacity(block.structs.count)
            for structRef in block.structs {
                switch structRef {
                case .gc(let id, let length):
                    structs.append(GCStruct(id: id, length: length))
                case .skip(let id, let length):
                    structs.append(SkipStruct(id: id, length: length))
                case .item(let itemRef):
                    structs.append(self.makeItem(itemRef))
                }
            }
            result[block.client] = ClientRefs(refs: structs)
        }
        return result
    }

    private func makeItem(_ ref: ItemRef) -> Item {
        var parentType: YTypeImpl?
        var parentID: YID?
        switch ref.parent {
        case .rootKey(let name): parentType = self.get(name)
        case .id(let id): parentID = id
        case .none: break
        }
        return Item(
            id: ref.id,
            origin: ref.origin,
            rightOrigin: ref.rightOrigin,
            parent: parentType,
            parentID: parentID,
            parentSub: ref.parentSub,
            content: Self.content(from: ref.content)
        )
    }

    private static func content(from ref: ContentRef) -> Content {
        switch ref {
        case .string(let string): .string(Array(string.utf16))
        case .format(let key, let value): .format(key: key, valueJSON: value)
        case .embed(let json): .embed(json: json)
        case .deleted(let count): .deleted(count)
        case .any(let items): .any(items)
        case .json(let items): .json(items)
        case .binary(let bytes): .binary(bytes)
        case .type(let typeRef, let name): .type(YTypeImpl(name: name), typeRef: typeRef, name: name)
        case .doc(let guid, let options): .doc(guid: guid, options: options)
        }
    }

    /// Integrates structs honouring causal dependencies (yjs `integrateStructs`).
    /// The dependency stack lets a struct from a higher client wait for referenced
    /// data in a lower client. Returns true if some structs could not integrate
    /// (missing causal deps) — the caller buffers the update and retries it later.
    private func integrateStructs(_ clientsStructRefs: [UInt64: ClientRefs]) -> Bool {
        var ids = clientsStructRefs.keys.sorted()
        guard !ids.isEmpty else { return false }

        var stack: [Struct] = []
        var droppedStructs = false
        var state: [UInt64: UInt64] = [:]
        func cachedState(_ client: UInt64) -> UInt64 {
            if let value = state[client] { return value }
            let value = self.store.getState(client)
            state[client] = value
            return value
        }

        func nextTarget() -> ClientRefs? {
            while let last = ids.last {
                let target = clientsStructRefs[last]!
                if target.i < target.refs.count { return target }
                ids.removeLast()
            }
            return nil
        }

        // Sets aside the current stack when a dependency isn't satisfiable yet.
        func dropStack() {
            if !stack.isEmpty { droppedStructs = true }
            for item in stack { ids.removeAll { $0 == item.id.client } }
            stack.removeAll(keepingCapacity: true)
        }

        guard var current = nextTarget() else { return false }
        var head = current.refs[current.i]
        current.i += 1

        while true {
            if !(head is SkipStruct) {
                let localClock = cachedState(head.id.client)
                let offset = Int(localClock) - Int(head.id.clock)
                if offset < 0 {
                    stack.append(head)
                    dropStack()
                } else if let missing = head.getMissing(self.store) {
                    stack.append(head)
                    let dependency = clientsStructRefs[missing]
                    if let dependency, dependency.i < dependency.refs.count {
                        head = dependency.refs[dependency.i]
                        dependency.i += 1
                        continue
                    }
                    dropStack()
                } else if offset == 0 || offset < Int(head.length) {
                    head.integrate(self.store, offset: offset)
                    state[head.id.client] = head.id.clock + head.length
                }
            }

            if let popped = stack.popLast() {
                head = popped
            } else if current.i < current.refs.count {
                head = current.refs[current.i]
                current.i += 1
            } else if let target = nextTarget() {
                current = target
                head = current.refs[current.i]
                current.i += 1
            } else {
                break
            }
        }
        return droppedStructs
    }

    // MARK: Materialisation

    /// Concatenated string content of root type `name`, skipping deleted items and
    /// non-string content (yjs `YText.toString`).
    func getText(_ name: String) -> String {
        guard let type = share[name] else { return "" }
        var units: [UInt16] = []
        var node = type.start
        while let item = node {
            if !item.deleted, case .string(let value) = item.content {
                units.append(contentsOf: value)
            }
            node = item.right as? Item
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// v1 state-vector bytes (`encodeStateVector`).
    func encodeStateVector() -> [UInt8] {
        var encoder = Lib0Encoder()
        let vector = self.store.stateVector()
        encoder.writeVarUint(UInt64(vector.count))
        for entry in vector {
            encoder.writeVarUint(entry.client)
            encoder.writeVarUint(entry.clock)
        }
        return encoder.bytes
    }

    // MARK: Encode

    /// v1 update bytes for everything the target is missing (`encodeStateAsUpdate`).
    /// An empty `target` writes the whole document.
    func encodeStateAsUpdate(target: [UInt64: UInt64] = [:]) -> [UInt8] {
        var encoder = Lib0Encoder()
        self.writeClientsStructs(&encoder, target: target)
        self.writeDeleteSet(&encoder)
        return encoder.bytes
    }

    /// Decodes v1 state-vector bytes into a `client -> clock` map.
    static func decodeStateVector(_ bytes: [UInt8]) throws -> [UInt64: UInt64] {
        var decoder = Lib0Decoder(bytes)
        let count = try decoder.readVarUint()
        var result: [UInt64: UInt64] = [:]
        for _ in 0..<count {
            let client = try decoder.readVarUint()
            result[client] = try decoder.readVarUint()
        }
        return result
    }

    private func writeClientsStructs(_ encoder: inout Lib0Encoder, target: [UInt64: UInt64]) {
        // Clients with structs the target lacks, written highest-id first (this
        // ordering is what makes the integration conflict algorithm cheap).
        var pending: [(client: UInt64, clock: UInt64)] = []
        for client in self.store.clients.keys {
            let targetClock = target[client] ?? 0
            if self.store.getState(client) > targetClock { pending.append((client, targetClock)) }
        }
        pending.sort { $0.client > $1.client }
        encoder.writeVarUint(UInt64(pending.count))
        for entry in pending { self.writeStructs(&encoder, client: entry.client, clock: entry.clock) }
    }

    private func writeStructs(_ encoder: inout Lib0Encoder, client: UInt64, clock rawClock: UInt64) {
        let structs = self.store.clients[client]!
        let clock = max(rawClock, structs[0].id.clock)
        let start = self.store.findIndex(structs, clock)
        encoder.writeVarUint(UInt64(structs.count - start))
        encoder.writeVarUint(client)
        encoder.writeVarUint(clock)
        structs[start].write(into: &encoder, offset: Int(clock - structs[start].id.clock))
        for index in (start + 1)..<structs.count { structs[index].write(into: &encoder, offset: 0) }
    }

    /// Writes the delete set derived from the store, coalescing consecutive deleted
    /// structs (`createDeleteSetFromStructStore` + `writeDeleteSet`).
    private func writeDeleteSet(_ encoder: inout Lib0Encoder) {
        var perClient: [(client: UInt64, ranges: [(clock: UInt64, length: UInt64)])] = []
        for (client, structs) in self.store.clients {
            var ranges: [(clock: UInt64, length: UInt64)] = []
            var index = 0
            while index < structs.count {
                guard let item = structs[index] as? Item, item.deleted else {
                    index += 1
                    continue
                }
                let clock = item.id.clock
                var length = item.length
                var next = index + 1
                while next < structs.count, let following = structs[next] as? Item, following.deleted {
                    length += following.length
                    next += 1
                }
                ranges.append((clock, length))
                index = next
            }
            if !ranges.isEmpty { perClient.append((client, ranges)) }
        }
        perClient.sort { $0.client > $1.client }
        encoder.writeVarUint(UInt64(perClient.count))
        for entry in perClient {
            encoder.writeVarUint(entry.client)
            encoder.writeVarUint(UInt64(entry.ranges.count))
            for range in entry.ranges {
                encoder.writeVarUint(range.clock)
                encoder.writeVarUint(range.length)
            }
        }
    }
}
