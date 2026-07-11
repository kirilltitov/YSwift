// The pure-Swift document engine core: applies a decoded v1 update into the arena
// store and materialises text / state vectors. Ports yjs `utils/encoding.js`
// (`readClientsStructRefs` + `integrateStructs` + the struct/delete-set apply
// order of `readUpdateV2`). Out-of-order updates that causally depend on data not
// yet present are dropped for now (the pending buffer is M4); complete updates —
// which every golden vector is — integrate fully.

/// One client's not-yet-integrated structs plus a cursor, matching the
/// `{ i, refs }` records in yjs `readClientsStructRefs`.
private final class ClientRefs {
    var i = 0
    let refs: [Struct]
    init(refs: [Struct]) { self.refs = refs }
}

final class NativeDoc {
    let clientID: UInt64
    let store = NativeStore()
    /// Root types by name (yjs `doc.share`).
    private(set) var share: [String: YTypeImpl] = [:]

    init(clientID: UInt64 = 0) {
        self.clientID = clientID
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

    /// Runs a local edit and cleans up (GC deleted content + merge structs) so the
    /// store matches yjs after the equivalent transaction.
    func transact(_ body: () -> Void) {
        body()
        self.store.cleanup()
    }

    // MARK: Apply

    /// Decodes and integrates a v1 update (structs then delete set).
    func applyUpdate(_ bytes: [UInt8]) throws {
        let parsed = try UpdateCodec.readUpdate(bytes)
        let refs = self.buildClientRefs(parsed.clientBlocks)
        self.integrateStructs(refs)
        self.store.applyDeleteSet(parsed.deleteSet)
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
    /// data in a lower client. Structs whose dependencies never arrive are dropped
    /// (pending re-buffering is deferred to M4).
    private func integrateStructs(_ clientsStructRefs: [UInt64: ClientRefs]) {
        var ids = clientsStructRefs.keys.sorted()
        guard !ids.isEmpty else { return }

        var stack: [Struct] = []
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

        // Drops the current stack when a dependency can never be satisfied.
        func dropStack() {
            for item in stack { ids.removeAll { $0 == item.id.client } }
            stack.removeAll(keepingCapacity: true)
        }

        guard var current = nextTarget() else { return }
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
