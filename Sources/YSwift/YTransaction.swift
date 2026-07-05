/// A scoped handle to an in-flight transaction.
///
/// - Important: A `YTransaction` is only valid inside the `body` of
///   `YDoc.transact(_:)`. It is deliberately **not** `Sendable` and must not
///   escape that closure.
public final class YTransaction {
    let engine: any YEngine
    let origin: Origin?
    let isWritable: Bool
    /// Opaque backend state (e.g. the Yrs `TransactionMut`). `nil` for the stub engine.
    let raw: AnyObject?

    init(engine: any YEngine, origin: Origin?, writable: Bool, raw: AnyObject?) {
        self.engine = engine
        self.origin = origin
        self.isWritable = writable
        self.raw = raw
    }
}
