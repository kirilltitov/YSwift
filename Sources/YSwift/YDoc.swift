#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization

/// A collaborative document: the root container for the CRDT text state.
///
/// Backend-agnostic — behind it sits a `YEngine` (Phase 1: Yrs facade,
/// Phase 2: native Swift). The public surface never changes between phases.
public final class YDoc: Sendable {
    /// This client's unique id (Yjs 53-bit client id).
    public let clientID: UInt64

    let engine: any YEngine

    /// Serializes transactions: at most one active write transaction per
    /// document (requirements §9.5). Both engines rely on this.
    private let sync = Mutex<Void>(())

    /// Creates a document with a random 53-bit client id.
    public init(gc: Bool = true) {
        let engine = makeDefaultEngine(clientID: nil, gc: gc)
        self.engine = engine
        self.clientID = engine.clientID
    }

    /// Creates a document with an explicit client id.
    ///
    /// Yjs allows setting the client id directly; an explicit id makes encoding
    /// deterministic (required for byte-exact conformance testing and useful for
    /// stable server-assigned ids).
    public init(clientID: UInt64, gc: Bool = true) {
        let engine = makeDefaultEngine(clientID: clientID, gc: gc)
        self.engine = engine
        self.clientID = engine.clientID
    }

    /// Returns the top-level text type under `name` (analogue of Yjs `getText`).
    public func text(_ name: String) -> YText {
        YText(doc: self, handle: engine.textHandle(name))
    }

    /// Runs `body` inside a single transaction, bundling all edits into one
    /// update. `origin` is attached to the transaction and forwarded to
    /// `onUpdate` listeners.
    @discardableResult
    public func transact<T>(origin: Origin? = nil, _ body: (YTransaction) -> T) -> T {
        sync.withLock { _ in
            let txn = engine.beginTransaction(origin: origin, writable: true)
            defer { engine.endTransaction(txn) }
            return body(txn)
        }
    }

    /// Throwing variant of `transact(origin:_:)`.
    @discardableResult
    public func transact<T>(origin: Origin? = nil, _ body: (YTransaction) throws -> T) throws -> T {
        try sync.withLock { _ in
            let txn = engine.beginTransaction(origin: origin, writable: true)
            defer { engine.endTransaction(txn) }
            return try body(txn)
        }
    }

    /// Subscribes to locally-produced updates. Send only these to the backend to
    /// avoid echo loops (requirements §9.3). Callbacks fire outside the txn lock.
    @discardableResult
    public func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription {
        // Serialize with transactions so registration never races a live txn.
        sync.withLock { _ in engine.onUpdate(callback) }
    }

    /// Releases the resident document.
    public func destroy() { engine.destroy() }
}

// MARK: - Synchronization & encoding (requirements §4.3)

extension YDoc {
    /// Encodes the document state as an update. With `sv`, only the difference
    /// the peer is missing is written.
    public func encodeStateAsUpdate(_ txn: YTransaction, since sv: StateVector? = nil) -> Data {
        engine.encodeStateAsUpdate(in: txn, since: sv)
    }

    /// Encodes the current state vector (`client -> clock`).
    public func encodeStateVector(_ txn: YTransaction) -> StateVector {
        engine.encodeStateVector(in: txn)
    }

    /// Applies a remote update. `origin` marks the source (e.g. remote) so
    /// `onUpdate` listeners can skip echoing it back.
    public func applyUpdate(_ txn: YTransaction, _ update: Data, origin: Origin? = nil) {
        engine.applyUpdate(in: txn, update, origin: origin)
    }
}
