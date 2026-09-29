// The pure-Swift document engine core: applies a decoded v1 update into the arena
// store and materialises text / state vectors. Ports yjs `utils/encoding.js`
// (`readClientsStructRefs` + `integrateStructs` + the struct/delete-set apply
// order of `readUpdateV2`). Structs and deletions that causally depend on data not
// yet present wait, as in yjs, and are retried as later updates arrive (see
// `pendingStructs`), so out-of-order / partial delivery converges.

import Synchronization

/// One client's not-yet-integrated structs plus a cursor, matching the
/// `{ i, refs }` records in yjs `readClientsStructRefs`.
private final class ClientRefs {
    var i = 0
    var refs: [Struct]
    init(refs: [Struct]) { self.refs = refs }
}

final class NativeDoc {
    /// This document's client id. A transaction that applied an update which advanced it takes a new
    /// one (see `commitTransaction`). Atomic because `YDoc.clientID` reads it outside any transaction.
    var clientID: UInt64 { self.clientIDStorage.load(ordering: .relaxed) }
    private let clientIDStorage: Atomic<UInt64>
    /// When false, deleted content is kept verbatim (no GC to `ContentDeleted`) —
    /// matches `new Y.Doc({ gc: false })`.
    let gc: Bool
    let store = NativeStore()
    /// Root types by name (yjs `doc.share`).
    private(set) var share: [String: YTypeImpl] = [:]

    init(clientID: UInt64 = 0, gc: Bool = true) {
        self.clientIDStorage = Atomic(clientID)
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

    /// A locally-editable array handle over root type `name`.
    func array(_ name: String) -> NativeArray {
        NativeArray(doc: self, type: self.get(name))
    }

    /// A locally-editable map handle over root type `name`.
    func map(_ name: String) -> NativeMap {
        NativeMap(doc: self, type: self.get(name))
    }

    private var txnDepth = 0
    private var txnBeforeState: [UInt64: UInt64] = [:]
    private var txnStartIntegratedCount = 0
    private var txnStartSplitCount = 0
    private var txnOrigin: Origin?
    /// Whether the transaction applied an update (yjs: it is not `local`).
    private var txnAppliedUpdate = false

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

    /// Text-change observers, keyed by root type name, behind their own lock.
    private struct ObserverBook {
        var next = 0
        var byName: [String: [(id: Int, callback: @Sendable (YTextEvent) -> Void)]] = [:]
    }
    private let observers = Mutex(ObserverBook())

    @discardableResult
    func observeText(_ name: String, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> Int {
        self.observers.withLock { book in
            let id = book.next
            book.next += 1
            book.byName[name, default: []].append((id, callback))
            return id
        }
    }

    func removeTextObserver(_ name: String, _ id: Int) {
        self.observers.withLock { $0.byName[name]?.removeAll { $0.id == id } }
    }

    /// Opens (or joins) a transaction. Only the outermost `begin`/`commit` pair
    /// snapshots state, cleans up, and emits — nested ops just join it.
    func beginTransaction(origin: Origin? = nil) {
        if self.txnDepth == 0 {
            self.txnBeforeState = self.store.snapshotState()
            self.txnStartIntegratedCount = self.store.integratedCount
            self.txnStartSplitCount = self.store.splitCount
            self.store.deleteSet = DeleteSet()
            self.store.deletedItemInTransaction = false
            self.store.deletedTypeInTransaction = false
            self.store.changedTypeNames = []
            self.store.changedTypes = [:]
            self.store.transactionBeforeState = self.txnBeforeState
            self.store.changedRootNamesAreComplete = true
            self.txnOrigin = origin
            self.txnAppliedUpdate = false
        }
        self.txnDepth += 1
    }

    /// Closes a transaction; on the outermost close, fires text observers (on the
    /// pre-cleanup store, as yjs does), cleans up (GC + merge), and emits the
    /// transaction's incremental update.
    func commitTransaction() {
        guard self.txnDepth > 0 else { return }
        self.txnDepth -= 1
        guard self.txnDepth == 0 else { return }
        // `sortAndMergeDeleteSet`, before observers and handlers see the delete set.
        self.store.deleteSet?.sortAndMerge()
        let deletes = self.store.deleteSet ?? DeleteSet()
        let changed = self.store.changedTypeNames ?? []
        let origin = self.txnOrigin
        let beforeState = self.txnBeforeState
        // A read-only transaction (no structs added, no deletes) needs no cleanup,
        // observer firing, or emission — skip the whole-store scan.
        let mutated = self.store.integratedCount != self.txnStartIntegratedCount || !deletes.isEmpty

        // 1. Text observers run BEFORE cleanup — merging/GC would hide which items
        //    were added this transaction (yjs fires observers, then merges).
        if mutated { self.fireTextObservers(changed: changed, deletes: deletes) }

        // 2. afterTransaction handlers (e.g. UndoManager capture) — also BEFORE
        //    cleanup, so `keepItem` can protect deleted content from the GC below.
        if mutated, !self.afterTransactionHandlers.isEmpty {
            let info = TransactionInfo(
                beforeState: beforeState, afterState: self.store.snapshotState(),
                deleteSet: deletes, changedNames: changed,
                changedParentRootNames: self.store.changedParentRootNames(), origin: origin)
            for entry in self.afterTransactionHandlers { entry.handler(info) }
        }

        // 3. Cleanup so the emitted update encodes the merged/GC'd store byte-exactly. A transaction
        //    that only split items (e.g. an undo that found nothing to change) merges them back too,
        //    as yjs merges every transaction's `_mergeStructs`.
        if mutated || self.store.splitCount != self.txnStartSplitCount {
            self.store.cleanup(gc: self.gc, deleteSet: deletes)
        }
        self.store.deleteSet = nil
        self.store.changedTypeNames = nil
        self.store.changedTypes = nil
        self.txnOrigin = nil

        // An applied update that advanced this document's own client shows that another peer writes under
        // its id: yjs takes a new random 32-bit one, so that later edits do not reuse that peer's clocks.
        if self.txnAppliedUpdate, self.store.getState(self.clientID) != beforeState[self.clientID] ?? 0 {
            self.clientIDStorage.store(UInt64.random(in: 0..<(1 << 32)), ordering: .relaxed)
        }

        // 4. Emit the incremental update to onUpdate handlers.
        let snapshot = self.handlers.withLock { $0.list }
        guard !snapshot.isEmpty else { return }
        if let update = self.encodeTransactionUpdate(beforeState: beforeState, deletes: deletes) {
            for entry in snapshot { entry.handler(update, origin) }
        }
    }

    /// Post-commit transaction summary, for stateful helpers like `UndoManager`.
    struct TransactionInfo {
        let beforeState: [UInt64: UInt64]
        let afterState: [UInt64: UInt64]
        /// The transaction's delete set, sorted and merged.
        let deleteSet: DeleteSet
        let changedNames: Set<String>
        /// The roots in yjs `transaction.changedParentTypes`: changed directly or through a type
        /// nested in them.
        let changedParentRootNames: Set<String>
        let origin: Origin?
    }
    private var afterTransactionHandlers: [(id: Int, handler: (TransactionInfo) -> Void)] = []
    private var nextAfterTransactionID = 0

    @discardableResult
    func onAfterTransaction(_ handler: @escaping (TransactionInfo) -> Void) -> Int {
        let id = self.nextAfterTransactionID
        self.nextAfterTransactionID += 1
        self.afterTransactionHandlers.append((id, handler))
        return id
    }

    func removeAfterTransactionHandler(_ id: Int) {
        self.afterTransactionHandlers.removeAll { $0.id == id }
    }

    private func fireTextObservers(changed: Set<String>, deletes: DeleteSet) {
        guard !changed.isEmpty else { return }
        func isDeleted(_ id: YID) -> Bool { deletes.contains(id) }
        for name in changed {
            let callbacks = self.observers.withLock { $0.byName[name] ?? [] }
            guard !callbacks.isEmpty, let type = share[name] else { continue }
            let delta = NativeText(doc: self, type: type)
                .changeDelta(beforeState: self.txnBeforeState, isDeleted: isDeleted)
            let event = YTextEvent(delta: delta)
            for entry in callbacks { entry.callback(event) }
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
    private func encodeTransactionUpdate(beforeState: [UInt64: UInt64], deletes: DeleteSet) -> [UInt8]? {
        let structsChanged = self.store.clients.keys.contains { self.store.getState($0) != (beforeState[$0] ?? 0) }
        guard structsChanged || !deletes.isEmpty else { return nil }
        var encoder = Lib0Encoder()
        self.writeClientsStructs(&encoder, target: beforeState)
        deletes.write(into: &encoder)
        return encoder.bytes
    }

    // MARK: Apply

    /// Structs waiting for clocks the document lacks (yjs `store.pendingStructs`).
    private var pendingStructs: PendingStructs?
    /// Deletions of clocks the document lacks (yjs `store.pendingDs`), tried again with every update.
    private var pendingDeletes: DeleteRanges?

    var hasPendingUpdates: Bool { self.pendingStructs != nil || self.pendingDeletes != nil }

    /// Decodes and integrates a v1 update; what depends on data not yet present waits for it.
    func applyUpdate(_ bytes: [UInt8]) throws {
        self.txnAppliedUpdate = true
        let parsed = try UpdateCodec.readUpdate(bytes)
        let deletes = parsed.deleteSet.clients.map { entry in
            (client: entry.client, ranges: entry.ranges.map { (clock: $0.clock, length: $0.length) })
        }
        // Where yjs runs out of stack deleting nested types, the update is rejected, as it is there
        // once partly applied, and so is nesting deeper than browsers can delete.
        self.store.limitsDeletionDepth = true
        defer { self.store.limitsDeletionDepth = false }
        try self.readUpdate(self.buildClientRefs(parsed.clientBlocks), deletes: deletes)
        // Yjs collects the transaction's deletions when it ends, and throws where that fails; this
        // update is rejected instead, as the commit that collects has no error to report.
        if self.gc, let deletes = self.store.deleteSet, self.store.collectionFails(deletes) {
            throw YError.invalidUpdate
        }
    }

    /// Yjs `readUpdateV2`: integrates the structs and merges what cannot integrate yet into the waiting
    /// structs, applies the deletions and then the waiting ones, and, once a clock the waiting structs
    /// miss has arrived, integrates them again as one update. A retry that throws has dropped them.
    private func readUpdate(_ refs: [UInt64: ClientRefs], deletes: DeleteRanges) throws {
        self.store.remoteDeletionFailed = false
        let rest = try self.integrateStructs(refs)
        guard !self.store.remoteDeletionFailed else { throw YError.invalidUpdate }
        var retry = false
        if let pending = self.pendingStructs {
            retry = pending.missing.contains { $0.value < self.store.getState($0.key) }
            if let rest { self.pendingStructs = pending.merged(with: rest) }
        } else {
            self.pendingStructs = rest
        }
        let deletesRest = self.store.applyDeleteSet(deletes)
        if let pendingDeletes = self.pendingDeletes {
            let pendingRest = self.store.applyDeleteSet(pendingDeletes)
            self.pendingDeletes =
                deletesRest.isEmpty || pendingRest.isEmpty
                ? [deletesRest, pendingRest].first { !$0.isEmpty }
                : mergeDeleteRanges(deletesRest, pendingRest)
        } else {
            self.pendingDeletes = deletesRest.isEmpty ? nil : deletesRest
        }
        guard !self.store.remoteDeletionFailed else { throw YError.invalidUpdate }
        if retry, let pending = self.pendingStructs {
            self.pendingStructs = nil
            try self.readUpdate(pending.structs.mapValues { ClientRefs(refs: $0) }, deletes: [])
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
        case .string(let string): .string(Array(string.utf16)[...])
        case .format(let key, let value): .format(key: key, valueJSON: value)
        case .embed(let json): .embed(json: json)
        case .deleted(let count): .deleted(count)
        case .any(let items): .any(items[...])
        case .json(let items): .json(items[...])
        case .binary(let bytes): .binary(bytes)
        case .type(let typeRef, let name): .type(YTypeImpl(name: name), typeRef: typeRef, name: name)
        case .doc(let guid, let options): .doc(guid: guid, options: options)
        }
    }

    /// Integrates structs honouring causal dependencies (yjs `integrateStructs`).
    /// The dependency stack lets a struct from a higher client wait for referenced
    /// data in a lower client. Returns the structs that could not integrate (missing
    /// causal deps) with the lowest missing clock per client, or nil. Throws on a
    /// reference that can never resolve (`Item.getMissing`).
    private func integrateStructs(_ refs: [UInt64: ClientRefs]) throws -> PendingStructs? {
        var clientsStructRefs = refs
        var ids = clientsStructRefs.keys.sorted()
        guard !ids.isEmpty else { return nil }

        var stack: [Struct] = []
        var rest = PendingStructs(missing: [:], structs: [:])
        func updateMissing(_ client: UInt64, _ clock: UInt64) {
            if rest.missing[client].map({ $0 > clock }) ?? true { rest.missing[client] = clock }
        }
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

        // Sets aside the current stack when a dependency isn't satisfiable yet, with the rest of each
        // of its clients' structs (`addStackToRestSS`): those are not even looked at until it is.
        func addStackToRest() {
            for item in stack {
                let client = item.id.client
                if let target = clientsStructRefs[client] {
                    // The item was the last one taken from its client's structs.
                    target.i -= 1
                    rest.structs[client] = Array(target.refs[target.i...])
                    clientsStructRefs[client] = nil
                    target.i = 0
                    target.refs = []
                } else {
                    rest.structs[client] = [item]
                }
                ids.removeAll { $0 == client }
            }
            stack.removeAll(keepingCapacity: true)
        }

        guard var current = nextTarget() else { return nil }
        var head = current.refs[current.i]
        current.i += 1

        while true {
            if !(head is SkipStruct) {
                let localClock = cachedState(head.id.client)
                let offset = Int(localClock) - Int(head.id.clock)
                if offset < 0 {
                    stack.append(head)
                    updateMissing(head.id.client, head.id.clock - 1)
                    addStackToRest()
                } else if let missing = try head.getMissing(self.store) {
                    stack.append(head)
                    let dependency = clientsStructRefs[missing]
                    if let dependency, dependency.i < dependency.refs.count {
                        head = dependency.refs[dependency.i]
                        dependency.i += 1
                        continue
                    }
                    updateMissing(missing, self.store.getState(missing))
                    addStackToRest()
                } else if offset == 0 || offset < Int(head.length) {
                    // Yjs links a run resent from its middle in after the struct just before its first
                    // new clock and reads that struct's right neighbour; a GC struct has none, and yjs
                    // throws before changing anything. In a valid update that struct is the part of the
                    // same run already held; one under another parent or key would lie in a list its
                    // parent does not own, which yjs accepts, nesting types deeper than their parents
                    // say. It is rejected, so that every item lies in its parent's list.
                    if offset > 0, let item = head as? Item, item.parent != nil {
                        let left = self.store.getItem(YID(client: item.id.client, clock: localClock - 1)) as? Item
                        guard let left else {
                            throw YError.invalidUpdate
                        }
                        if self.store.rejectsRunsUnderAnotherParent,
                            left.parent !== item.parent || left.parentSub != item.parentSub
                        {
                            throw YError.invalidUpdate
                        }
                    }
                    // Nesting that browsers could not delete is not built at all.
                    if let parent = (head as? Item)?.parent, parent.depth >= self.store.nestingLimit {
                        throw YError.invalidUpdate
                    }
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
        return rest.structs.isEmpty ? nil : rest
    }

    // MARK: Materialisation

    /// Concatenated string content of root type `name`, skipping deleted items and
    /// non-string content (yjs `YText.toString`).
    func getText(_ name: String) -> String {
        guard let type = share[name] else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(type.length)
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
        let structCount = self.store.clients.values.reduce(0) { $0 + $1.count }
        encoder.reserveCapacity(structCount * 8 + 64)
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
                // GC structs count as deleted too (`GC.deleted`). One load per struct keeps this
                // whole-store walk to a single retain per struct.
                let first = structs[index]
                guard first.isDeleted else {
                    index += 1
                    continue
                }
                let clock = first.id.clock
                var length = first.length
                var next = index + 1
                while next < structs.count {
                    let following = structs[next]
                    guard following.isDeleted else { break }
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
