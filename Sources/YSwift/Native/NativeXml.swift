// Native Y.Xml* (fragment / element / text), an extension beyond the §4 subset.
//
// XML nodes are nested `ContentType` items: typeRef 3 = XmlElement (carries the
// tag name), 6 = XmlText, 4 = XmlFragment. An element's attributes are parentSub
// items under its type; its children are a YATA list under the same type; a text
// node holds a ContentString child.
//
// Byte-exactness note: yjs integrates a prelim element's CHILDREN before its
// ATTRIBUTES, so this builder does the same (children fully, then attributes),
// reproducing yjs's clock order. Multiple attributes on one element are applied
// in sorted-key order (deterministic; a single-attribute element is byte-exact —
// multi-attribute order is a semantic match, as with text formatting).

/// Declarative XML node used to build a subtree in one shot.
enum XmlNode {
    case element(tag: String, attributes: [(key: String, value: Lib0Any)], children: [XmlNode])
    case text(String)
}

struct NativeXml {
    let doc: NativeDoc

    private var store: NativeStore { self.doc.store }

    // MARK: Build

    /// Inserts `nodes` at element `index` in `type`'s child list.
    func insert(into type: YTypeImpl, at index: Int, _ nodes: [XmlNode]) {
        var left: Item?
        var right = type.start
        var remaining = index
        while let item = right, remaining > 0 {
            if !item.deleted {
                if remaining < Int(item.length) {
                    _ = self.store.getItemCleanStart(
                        YID(client: item.id.client, clock: item.id.clock + UInt64(remaining)))
                }
                remaining -= Int(item.length)
            }
            left = item
            right = item.right as? Item
        }
        for node in nodes {
            let item = self.build(node, parent: type, left: left, right: right)
            left = item
            right = item.right as? Item
        }
    }

    private func build(_ node: XmlNode, parent: YTypeImpl, left: Item?, right: Item?) -> Item {
        let nested = YTypeImpl()
        let content: Content
        switch node {
        case .element(let tag, _, _): content = .type(nested, typeRef: 3, name: tag)
        case .text: content = .type(nested, typeRef: 6, name: nil)
        }
        let item = self.makeItem(parent: parent, parentSub: nil, left: left, right: right, content: content)
        switch node {
        case .element(_, let attributes, let children):
            self.insert(into: nested, at: 0, children)  // children first (yjs order)
            for attribute in attributes.sorted(by: { $0.key < $1.key }) {
                self.mapSet(nested, attribute.key, attribute.value)
            }
        case .text(let string):
            _ = self.makeItem(
                parent: nested, parentSub: nil, left: nil, right: nil, content: .string(Array(string.utf16)))
        }
        return item
    }

    private func mapSet(_ type: YTypeImpl, _ key: String, _ value: Lib0Any) {
        let left = type.map[key]
        _ = self.makeItem(parent: type, parentSub: key, left: left, right: nil, content: .any([value]))
    }

    private func makeItem(parent: YTypeImpl, parentSub: String?, left: Item?, right: Item?, content: Content) -> Item {
        let item = Item(
            id: YID(client: self.doc.clientID, clock: self.store.getState(self.doc.clientID)),
            origin: left?.lastId, rightOrigin: right?.id,
            parent: parent, parentID: nil, parentSub: parentSub, content: content)
        item.left = left
        item.right = right
        item.integrate(self.store, offset: 0)
        return item
    }

    // MARK: Serialise (YXmlElement/Fragment.toString)

    func string(of type: YTypeImpl) -> String {
        var out = ""
        var node = type.start
        while let item = node {
            if !item.deleted, case .type(let nested, let typeRef, let name) = item.content {
                switch typeRef {
                case 6:
                    out += Self.textContent(nested)
                case 3:
                    let tag = (name ?? "").lowercased()
                    out += "<\(tag)\(self.attributeString(nested))>\(self.string(of: nested))</\(tag)>"
                default:
                    break
                }
            }
            node = item.right as? Item
        }
        return out
    }

    private static func textContent(_ type: YTypeImpl) -> String {
        var units: [UInt16] = []
        var node = type.start
        while let item = node {
            if !item.deleted, case .string(let value) = item.content { units.append(contentsOf: value) }
            node = item.right as? Item
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func attributeString(_ type: YTypeImpl) -> String {
        let entries =
            type.map
            .compactMap { key, item -> (String, String)? in
                guard !item.deleted, case .any(let values) = item.content, let value = values.last else { return nil }
                return (key, Self.attributeText(value))
            }
            .sorted { $0.0 < $1.0 }
        guard !entries.isEmpty else { return "" }
        return " " + entries.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
    }

    private static func attributeText(_ value: Lib0Any) -> String {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number):
            number == number.rounded(.towardZero) ? String(Int64(number)) : String(number)
        default: ""
        }
    }
}
