/// A collaborative ordered list (analogue of `Y.Array`), obtained via
/// `YDoc.array(_:)`. Holds JSON-like `YValue` elements. Mutating operations take
/// the active `YTransaction`.
///
/// A container type — an extension beyond the frozen §4 text subset. Backed only
/// by the native engine.
public final class YArray: Sendable {
    let doc: YDoc
    let name: String

    init(doc: YDoc, name: String) {
        self.doc = doc
        self.name = name
    }

    /// Inserts `values` starting at `index`.
    public func insert(_ txn: YTransaction, at index: Int, _ values: [YValue]) {
        self.doc.engine.arrayInsert(in: txn, self.name, at: index, values)
    }

    /// Appends `values` to the end.
    public func append(_ txn: YTransaction, _ values: [YValue]) {
        self.doc.engine.arrayInsert(in: txn, self.name, at: self.length(txn), values)
    }

    /// Deletes `count` elements starting at `index`.
    public func delete(_ txn: YTransaction, at index: Int, count: Int) {
        self.doc.engine.arrayDelete(in: txn, self.name, at: index, count: count)
    }

    /// The number of elements.
    public func length(_ txn: YTransaction) -> Int {
        self.doc.engine.arrayLength(in: txn, self.name)
    }

    /// The elements as a Swift array.
    public func toArray(_ txn: YTransaction) -> [YValue] {
        self.doc.engine.arrayValues(in: txn, self.name)
    }
}
