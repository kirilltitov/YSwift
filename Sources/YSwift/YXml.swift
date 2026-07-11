/// A node in an XML tree, used to build a subtree declaratively.
///
/// A container type — an extension beyond the frozen §4 text subset.
public enum YXmlNode: Sendable {
    /// An element with a tag name, attributes, and children.
    case element(tag: String, attributes: [String: YValue] = [:], children: [YXmlNode] = [])
    /// A text node.
    case text(String)
}

/// A collaborative XML fragment (analogue of `Y.XmlFragment`), obtained via
/// `YDoc.xmlFragment(_:)`. Holds a list of XML element / text children. Backed only
/// by the native engine.
public final class YXmlFragment: Sendable {
    let doc: YDoc
    let name: String

    init(doc: YDoc, name: String) {
        self.doc = doc
        self.name = name
    }

    /// Inserts XML `nodes` (elements/text, with their attributes and children) at
    /// `index`.
    public func insert(_ txn: YTransaction, at index: Int, _ nodes: [YXmlNode]) {
        self.doc.engine.xmlInsert(in: txn, self.name, at: index, nodes)
    }

    /// Serialises the fragment to an XML string (`Y.XmlFragment.toString`).
    public func toString(_ txn: YTransaction) -> String {
        self.doc.engine.xmlString(in: txn, self.name)
    }
}
