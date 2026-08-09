/// A scoped handle to an in-flight transaction.
///
/// - Important: A `YTransaction` is only valid inside the `body` of
///   `YDoc.transact(_:)`. It is deliberately **not** `Sendable` and must not
///   escape that closure.
public final class YTransaction {
    let engine: any YEngine
    let origin: Origin?
    let isWritable: Bool

    init(engine: any YEngine, origin: Origin?, writable: Bool) {
        self.engine = engine
        self.origin = origin
        self.isWritable = writable
    }
}
