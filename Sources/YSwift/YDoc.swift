import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A collaborative document: the root container for CRDT shared state.
///
/// Backed by the package's pure-Swift `NativeEngine` implementation.
public final class YDoc: Sendable {
    /// This client's unique id (Yjs 53-bit client id).
    public let clientID: UInt64

    let engine: any YEngine

    /// Serializes transactions: at most one active write transaction per
    /// document (requirements §9.5). The native engine relies on this.
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

    /// Injects an engine through the internal seam. Public initializers always
    /// construct the native implementation through `makeDefaultEngine`.
    init(engine: any YEngine) {
        self.engine = engine
        self.clientID = engine.clientID
    }

    /// Returns the top-level text type under `name` (analogue of Yjs `getText`).
    public func text(_ name: String) -> YText {
        YText(doc: self, handle: self.engine.textHandle(name))
    }

    /// Returns the top-level array type under `name` (analogue of Yjs `getArray`).
    public func array(_ name: String) -> YArray {
        YArray(doc: self, name: name)
    }

    /// Returns the top-level map type under `name` (analogue of Yjs `getMap`).
    public func map(_ name: String) -> YMap {
        YMap(doc: self, name: name)
    }

    /// Returns the top-level XML fragment under `name` (analogue of Yjs
    /// `getXmlFragment`).
    public func xmlFragment(_ name: String) -> YXmlFragment {
        YXmlFragment(doc: self, name: name)
    }

    /// Runs `body` inside a single transaction, bundling all edits into one
    /// update. `origin` is attached to the transaction and forwarded to
    /// `onUpdate` listeners.
    @discardableResult
    public func transact<T>(origin: Origin? = nil, _ body: (YTransaction) -> T) -> T {
        self.sync.withLock { _ in
            let txn = self.engine.beginTransaction(origin: origin, writable: true)
            defer { self.engine.endTransaction(txn) }
            return body(txn)
        }
    }

    /// Throwing variant of `transact(origin:_:)`.
    @discardableResult
    public func transact<T>(origin: Origin? = nil, _ body: (YTransaction) throws -> T) throws -> T {
        try self.sync.withLock { _ in
            let txn = self.engine.beginTransaction(origin: origin, writable: true)
            defer { self.engine.endTransaction(txn) }
            return try body(txn)
        }
    }

    /// Subscribes to locally-produced updates. Send only these to the backend to
    /// avoid echo loops (requirements §9.3). Callbacks fire during commit.
    @discardableResult
    public func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription {
        // Serialize with transactions so registration never races a live txn.
        self.sync.withLock { _ in self.engine.onUpdate(callback) }
    }

    /// Runs `body` while holding the document's transaction lock. Used by stateful
    /// helpers (e.g. `UndoManager`) whose operations open their own transaction and
    /// must not race the document's transactions.
    func performExclusively<T>(_ body: () -> T) -> T {
        self.sync.withLock { _ in body() }
    }

    /// Releases the resident document.
    public func destroy() { self.engine.destroy() }
}

// MARK: - Synchronization & encoding (requirements §4.3)

extension YDoc {
    /// Encodes the document state as an update. With `sv`, only the difference
    /// the peer is missing is written.
    public func encodeStateAsUpdate(_ txn: YTransaction, since sv: StateVector? = nil) -> Data {
        self.engine.encodeStateAsUpdate(in: txn, since: sv)
    }

    /// Returns top-level roots integrated or deleted so far in this transaction.
    ///
    /// Read inside `transact` after applying an update. The returned set is an immutable value.
    /// Buffered causal updates count when they integrate; duplicate deliveries return no roots.
    /// Nil means complete root coverage could not be established (for example a nested type).
    /// Callers using this set to validate content must take a full-validation fallback on nil.
    /// Failed untrusted candidates must still be discarded: application is not rollback-atomic.
    public func changedRootNames(_ txn: YTransaction) -> Set<String>? {
        guard txn.engine === self.engine else {
            return nil
        }
        return self.engine.changedRootNames(in: txn)
    }

    /// Reports buffered causal structs or deletes omitted from `encodeStateAsUpdate`.
    /// A false result proves no hidden pending update is carried by this document. Nil means the
    /// transaction belongs to another document; callers must not treat that as absence of pending work.
    public func hasPendingUpdates(_ txn: YTransaction) -> Bool? {
        guard txn.engine === self.engine else {
            return nil
        }
        return self.engine.hasPendingUpdates(in: txn)
    }

    /// Encodes the current state vector (`client -> clock`).
    public func encodeStateVector(_ txn: YTransaction) -> StateVector {
        self.engine.encodeStateVector(in: txn)
    }

    /// Applies a remote update while preserving the legacy nonthrowing contract.
    ///
    /// Structural validation runs before engine integration, but every failure
    /// is swallowed. A late engine error may therefore leave a valid prefix
    /// integrated without telling the caller. Retain this API only for source
    /// compatibility; external input must use `applyUpdateChecked(_:_:origin:)`
    /// with a disposable document.
    ///
    /// The `origin` argument is retained for source compatibility and does not
    /// retag the open transaction. Pass origin to `transact(origin:_:)` instead.
    public func applyUpdate(_ txn: YTransaction, _ update: Data, origin: Origin? = nil) {
        try? self.applyUpdateChecked(txn, update, origin: origin)
    }

    /// Strictly validates and applies a remote v1 update.
    ///
    /// `YUpdate.validateV1` first verifies one complete, bounded v1 wire value
    /// without touching the engine. Structural failures and later engine
    /// integration errors are both reported as `YError.invalidUpdate`.
    /// Structural success alone does not prove causal integrability or
    /// materialisability by the document engine.
    ///
    /// The `origin` argument is retained for source compatibility and does not
    /// retag the open transaction. Use `transact(origin:_:)` to mark the source
    /// for `onUpdate` listeners.
    ///
    /// Application is not rollback-atomic: integration may discover a semantic
    /// integration error after integrating an earlier valid prefix. Callers must
    /// therefore apply untrusted input to a disposable document and discard that
    /// document whenever this method throws.
    public func applyUpdateChecked(
        _ txn: YTransaction, _ update: Data, origin: Origin? = nil
    ) throws {
        do {
            try YUpdate.validateV1(update)
            try self.engine.applyUpdate(in: txn, update, origin: origin)
        } catch {
            throw YError.invalidUpdate
        }
    }
}
