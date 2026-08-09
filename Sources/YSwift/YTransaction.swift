/// A scoped handle to an in-flight transaction.
///
/// - Important: A `YTransaction` is only valid inside the `body` of
///   `YDoc.transact(_:)`. It is deliberately **not** `Sendable` and must not
///   escape that closure.
public final class YTransaction {
    let engine: any YEngine
    let origin: Origin?
    let isWritable: Bool
    /// Opaque backend state when required (for example, a yrs `TransactionMut`).
    /// The native engine keeps its transaction state in `NativeDoc` and uses `nil`.
    let raw: AnyObject?

    init(engine: any YEngine, origin: Origin?, writable: Bool, raw: AnyObject?) {
        self.engine = engine
        self.origin = origin
        self.isWritable = writable
        self.raw = raw
    }
}
