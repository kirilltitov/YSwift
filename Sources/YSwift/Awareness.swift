#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Ephemeral presence information — cursors, selections, who-is-online
/// (requirements §4.5).
///
/// Wire-compatible with `y-protocols/awareness`. Never persisted and never
/// routed through the commit journal (requirements §9.7).
///
/// Not `Sendable`: awareness state is mutated in place and its yrs operations
/// require exclusive access. Drive it from a single context (or wrap in an actor
/// per room).
public final class Awareness {
    /// The clients whose awareness state was added / updated / removed.
    public struct Change: Sendable, Hashable {
        public let added: [UInt64]
        public let updated: [UInt64]
        public let removed: [UInt64]
    }

    private let doc: YDoc
    private let handle: AnyObject?
    private var localState: [String: YValue] = [:]

    public init(_ doc: YDoc) {
        self.doc = doc
        self.handle = doc.engine.makeAwareness()
    }

    /// Sets a field of this client's local awareness state (`nil` clears it).
    /// Fields are merged, matching Yjs `setLocalStateField`.
    public func setLocalStateField(_ field: String, _ value: YValue?) {
        guard let handle = self.handle else { return }
        if let value {
            self.localState[field] = value
        } else {
            self.localState.removeValue(forKey: field)
        }
        let json = (try? JSONEncoder().encode(self.localState)) ?? Data("{}".utf8)
        self.doc.engine.awarenessSetLocalState(handle, json: json)
    }

    /// All currently-known client states, keyed by client id.
    public func states() -> [UInt64: [String: YValue]] {
        guard let handle = self.handle else { return [:] }
        let data = self.doc.engine.awarenessStates(handle)
        guard let raw = try? JSONDecoder().decode([String: YValue].self, from: data) else { return [:] }
        var result: [UInt64: [String: YValue]] = [:]
        for (key, value) in raw {
            if let id = UInt64(key), case .object(let fields) = value {
                result[id] = fields
            }
        }
        return result
    }

    /// Observes awareness changes. The callback fires synchronously during
    /// `applyUpdate` / local-state changes.
    @discardableResult
    public func onChange(_ callback: @escaping @Sendable (Change) -> Void) -> YSubscription {
        guard let handle = self.handle else { return YSubscription {} }
        return self.doc.engine.awarenessOnChange(handle, callback)
    }

    /// Encodes an awareness update. Pass `clients` to restrict it to specific
    /// clients; otherwise all known clients are included.
    public func encodeUpdate(clients: [UInt64]? = nil) -> Data {
        guard let handle = self.handle else { return Data() }
        return self.doc.engine.awarenessEncodeUpdate(handle, clients: clients)
    }

    /// Applies a remote awareness update.
    public func applyUpdate(_ data: Data, origin: Origin? = nil) {
        guard let handle = self.handle else { return }
        _ = self.doc.engine.awarenessApplyUpdate(handle, data)
    }

    /// Removes the given clients' states (e.g. on disconnect).
    public func removeStates(_ clients: [UInt64]) {
        guard let handle = self.handle else { return }
        for client in clients {
            self.doc.engine.awarenessRemoveState(handle, client: client)
        }
    }
}
