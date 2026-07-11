// Pure-Swift awareness (ephemeral presence), wire-compatible with
// `y-protocols/awareness`. Per client: a JSON state string and a monotonic clock.
// An update is `writeVarUint(count)` then, per client, `writeVarUint(clientID)`,
// `writeVarUint(clock)`, `writeVarString(JSON.stringify(state) | "null")`. A state
// is adopted only when its clock is newer. Independent of the CRDT store.
//
// Single-context by contract (the public `Awareness` is not `Sendable`); no lock.

final class NativeAwareness: @unchecked Sendable {
    let clientID: UInt64
    /// Client → state JSON (absent once removed).
    private var states: [UInt64: String] = [:]
    /// Client → clock (present for every client ever seen).
    private var clocks: [UInt64: Int] = [:]
    private var onChangeHandlers: [(id: Int, callback: @Sendable (Awareness.Change) -> Void)] = []
    private var nextHandlerID = 0

    init(clientID: UInt64) {
        self.clientID = clientID
        // Mirrors y-protocols' constructor `setLocalState({})`: clock starts at 0 so
        // the first real field bumps it to 1 (a fresh peer at clock 0 then adopts it).
        self.states[clientID] = "{}"
        self.clocks[clientID] = 0
    }

    func setLocalState(_ json: String) {
        let clock = self.clocks[self.clientID].map { $0 + 1 } ?? 0
        let hadState = self.states[self.clientID] != nil
        self.states[self.clientID] = json
        self.clocks[self.clientID] = clock
        self.fire(added: hadState ? [] : [self.clientID], updated: hadState ? [self.clientID] : [], removed: [])
    }

    func cleanLocalState() {
        self.removeState(self.clientID)
    }

    func removeState(_ client: UInt64) {
        let hadState = self.states[client] != nil
        self.states.removeValue(forKey: client)
        self.clocks[client] = (self.clocks[client] ?? 0) + 1
        if hadState { self.fire(added: [], updated: [], removed: [client]) }
    }

    /// `{"<client>": <state JSON>, …}` for clients that currently have state.
    func statesJSON() -> [UInt8] {
        let body = self.states.keys.sorted()
            .compactMap { client in self.states[client].map { "\"\(client)\":\($0)" } }
            .joined(separator: ",")
        return Array("{\(body)}".utf8)
    }

    func encodeUpdate(clients: [UInt64]?) -> [UInt8] {
        let list = clients ?? self.states.keys.sorted()
        var encoder = Lib0Encoder()
        encoder.writeVarUint(UInt64(list.count))
        for client in list {
            encoder.writeVarUint(client)
            encoder.writeVarUint(UInt64(self.clocks[client] ?? 0))
            encoder.writeVarString(self.states[client] ?? "null")
        }
        return encoder.bytes
    }

    @discardableResult
    func applyUpdate(_ bytes: [UInt8]) -> Bool {
        var decoder = Lib0Decoder(bytes)
        guard let count = try? decoder.readVarUint() else { return false }
        var added: [UInt64] = []
        var updated: [UInt64] = []
        var removed: [UInt64] = []
        for _ in 0..<count {
            guard let client = try? decoder.readVarUint(),
                let clockValue = try? decoder.readVarUint(),
                let stateJSON = try? decoder.readVarString()
            else { return false }
            let clock = Int(clockValue)
            let isNull = stateJSON == "null"
            let hadMeta = self.clocks[client] != nil
            let currClock = self.clocks[client] ?? 0
            let hasState = self.states[client] != nil
            guard currClock < clock || (currClock == clock && isNull && hasState) else { continue }
            if isNull {
                if client == self.clientID, self.states[self.clientID] != nil {
                    // Never let a remote peer clear our own state; just bump the clock.
                    self.clocks[self.clientID] = clock + 1
                } else {
                    self.states.removeValue(forKey: client)
                    self.clocks[client] = clock
                }
            } else {
                self.states[client] = stateJSON
                self.clocks[client] = clock
            }
            if !hadMeta, !isNull {
                added.append(client)
            } else if hadMeta, isNull {
                removed.append(client)
            } else if !isNull {
                updated.append(client)
            }
        }
        if !added.isEmpty || !updated.isEmpty || !removed.isEmpty {
            self.fire(added: added, updated: updated, removed: removed)
        }
        return true
    }

    func onChange(_ callback: @escaping @Sendable (Awareness.Change) -> Void) -> Int {
        let id = self.nextHandlerID
        self.nextHandlerID += 1
        self.onChangeHandlers.append((id, callback))
        return id
    }

    func removeOnChange(_ id: Int) {
        self.onChangeHandlers.removeAll { $0.id == id }
    }

    private func fire(added: [UInt64], updated: [UInt64], removed: [UInt64]) {
        let change = Awareness.Change(added: added, updated: updated, removed: removed)
        for entry in self.onChangeHandlers { entry.callback(change) }
    }
}
