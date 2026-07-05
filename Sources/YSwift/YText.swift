/// A collaborative text type (analogue of `Y.Text`), obtained via
/// `YDoc.text(_:)`. Mutating operations take the active `YTransaction`.
///
/// All indices and lengths are measured in **UTF-16 code units**, matching
/// Yjs — the unit the wire format is denominated in.
public final class YText: Sendable {
    let doc: YDoc
    let handle: TextHandle

    init(doc: YDoc, handle: TextHandle) {
        self.doc = doc
        self.handle = handle
    }

    /// Inserts `string` at `index`, optionally with formatting `attributes`.
    public func insert(_ txn: YTransaction, at index: Int, _ string: String, attributes: Attributes? = nil) {
        doc.engine.textInsert(in: txn, handle, at: index, string, attributes: attributes)
    }

    /// Deletes `length` code units starting at `index`.
    public func delete(_ txn: YTransaction, at index: Int, length: Int) {
        doc.engine.textDelete(in: txn, handle, at: index, length: length)
    }

    /// Applies formatting `attributes` to the `length` code units at `index`.
    public func format(_ txn: YTransaction, at index: Int, length: Int, attributes: Attributes) {
        doc.engine.textFormat(in: txn, handle, at: index, length: length, attributes: attributes)
    }

    /// The plain-text contents (no formatting).
    public func string(_ txn: YTransaction) -> String {
        doc.engine.textString(in: txn, handle)
    }

    /// The length in UTF-16 code units.
    public func length(_ txn: YTransaction) -> Int {
        doc.engine.textLength(in: txn, handle)
    }

    /// The contents as a Quill-style delta (for materializing to
    /// `content` / `format_data`).
    public func toDelta(_ txn: YTransaction) -> [Delta] {
        doc.engine.textDelta(in: txn, handle)
    }

    /// Observes changes to this text. Callbacks fire outside the txn lock.
    @discardableResult
    public func observe(_ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription {
        doc.performExclusively { doc.engine.observeText(handle, callback) }
    }
}
