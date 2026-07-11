/// A collaborative key-value map (analogue of `Y.Map`), obtained via
/// `YDoc.map(_:)`. Values are JSON-like `YValue`s; a repeated `set` keeps the
/// last writer. Mutating operations take the active `YTransaction`.
///
/// A container type — an extension beyond the frozen §4 text subset. Backed only
/// by the native engine.
public final class YMap: Sendable {
    let doc: YDoc
    let name: String

    init(doc: YDoc, name: String) {
        self.doc = doc
        self.name = name
    }

    /// Sets `key` to `value`.
    public func set(_ txn: YTransaction, _ key: String, _ value: YValue) {
        self.doc.engine.mapSet(in: txn, self.name, key, value)
    }

    /// Removes `key`.
    public func remove(_ txn: YTransaction, _ key: String) {
        self.doc.engine.mapDelete(in: txn, self.name, key)
    }

    /// The current value for `key`, or nil.
    public func get(_ txn: YTransaction, _ key: String) -> YValue? {
        self.doc.engine.mapGet(in: txn, self.name, key)
    }

    /// The keys with a live value.
    public func keys(_ txn: YTransaction) -> [String] {
        self.doc.engine.mapKeys(in: txn, self.name)
    }

    /// All live entries as a dictionary.
    public func toDictionary(_ txn: YTransaction) -> [String: YValue] {
        self.doc.engine.mapToDictionary(in: txn, self.name)
    }
}
