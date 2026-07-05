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
public final class Awareness: Sendable {
    /// The clients whose awareness state was added / updated / removed.
    public struct Change: Sendable, Hashable {
        public let added: [UInt64]
        public let updated: [UInt64]
        public let removed: [UInt64]

        public init(added: [UInt64], updated: [UInt64], removed: [UInt64]) {
            self.added = added
            self.updated = updated
            self.removed = removed
        }
    }

    // Strong reference: the awareness protocol is tied to its document's lifetime.
    private let doc: YDoc

    public init(_ doc: YDoc) {
        self.doc = doc
    }

    /// Sets a field of this client's local awareness state (`nil` clears it).
    public func setLocalStateField(_ field: String, _ value: YValue?) {
        fatalError("YSwift: Awareness.setLocalStateField is not implemented yet. See DECISIONS.md.")
    }

    /// All currently-known client states.
    public func states() -> [UInt64: [String: YValue]] {
        fatalError("YSwift: Awareness.states is not implemented yet. See DECISIONS.md.")
    }

    /// Observes awareness changes. Callback fires outside the txn lock.
    @discardableResult
    public func onChange(_ callback: @escaping @Sendable (Change) -> Void) -> YSubscription {
        fatalError("YSwift: Awareness.onChange is not implemented yet. See DECISIONS.md.")
    }

    /// Encodes an awareness update for the given `clients` (default: all changed).
    public func encodeUpdate(clients: [UInt64]? = nil) -> Data {
        fatalError("YSwift: Awareness.encodeUpdate is not implemented yet. See DECISIONS.md.")
    }

    /// Applies a remote awareness update.
    public func applyUpdate(_ data: Data, origin: Origin? = nil) {
        fatalError("YSwift: Awareness.applyUpdate is not implemented yet. See DECISIONS.md.")
    }

    /// Removes the given clients' states (e.g. on disconnect).
    public func removeStates(_ clients: [UInt64]) {
        fatalError("YSwift: Awareness.removeStates is not implemented yet. See DECISIONS.md.")
    }
}
