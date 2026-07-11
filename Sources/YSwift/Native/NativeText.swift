// Local YText operations (insert / delete / format), `toDelta`, and the
// per-transaction change delta, ported from yjs v13.6.31 `types/YText.js`. Each
// public op runs inside `NativeDoc.transact`, which merges and garbage-collects
// structs afterwards so the store matches yjs byte-for-byte.
//
// Attribute values are carried as their JSON-serialised form (a `String`), which
// keeps `ContentFormat` byte-exact on encode and makes `toDelta` a direct JSON
// assembly. NOTE: attributes are compared/iterated as an unordered map, so a
// single op applying two or more attributes at once is not guaranteed to match
// yjs's object-key order yet (no fixture exercises that; tracked for later).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// JSON-encodes a `Lib0Any` the way `JSON.stringify` would, for attribute values.
enum JSONValue {
    static func string(from any: Lib0Any) -> String {
        switch any {
        case .undefined, .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value == value.rounded(.towardZero) && abs(value) < 1e16
                ? String(Int64(value)) : String(value)
        case .bigInt(let value): String(value)
        case .string(let value): escaped(value)
        case .bytes: "null"
        case .array(let items): "[" + items.map { string(from: $0) }.joined(separator: ",") + "]"
        case .object(let pairs):
            "{" + pairs.map { "\(escaped($0.key)):\(string(from: $0.value))" }.joined(separator: ",") + "}"
        }
    }

    /// JSON string literal with the escapes `JSON.stringify` emits.
    static func escaped(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format2Hex(s.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private static func format2Hex(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
    }
}

/// A cursor between two items in a text type, tracking the running formatting
/// attributes (`ItemTextListPosition`). Attribute values are JSON strings; a key
/// is absent when its attribute is null.
private final class TextPosition {
    var left: Item?
    var right: Item?
    var index: Int
    var attributes: [String: String]

    init(left: Item?, right: Item?, index: Int, attributes: [String: String]) {
        self.left = left
        self.right = right
        self.index = index
        self.attributes = attributes
    }

    func apply(format key: String, _ valueJSON: String) {
        if valueJSON == "null" {
            self.attributes.removeValue(forKey: key)
        } else {
            self.attributes[key] = valueJSON
        }
    }

    func forward() {
        guard let right = self.right else { return }
        if case .format(let key, let value) = right.content {
            if !right.deleted { self.apply(format: key, value) }
        } else if !right.deleted {
            self.index += Int(right.length)
        }
        self.left = right
        self.right = right.right as? Item
    }
}

/// Absent attribute is treated as `null` (`equalAttrs`, scalar form).
private func equalAttrs(_ lhs: String?, _ rhs: String?) -> Bool {
    (lhs ?? "null") == (rhs ?? "null")
}

private func formatContent(_ item: Item) -> (key: String, value: String)? {
    if case .format(let key, let value) = item.content { return (key, value) }
    return nil
}

/// A locally-editable text container over a `NativeDoc` root type.
final class NativeText {
    let doc: NativeDoc
    let type: YTypeImpl

    init(doc: NativeDoc, type: YTypeImpl) {
        self.doc = doc
        self.type = type
    }

    var string: String { self.doc.getText(self.type.name ?? "") }

    /// Visible length in UTF-16 code units (countable, non-deleted content).
    var length: Int { self.type.length }

    // MARK: Public ops

    func insert(_ index: Int, _ text: String, attributes: [String: Lib0Any]? = nil) {
        guard !text.isEmpty else { return }
        self.doc.transact {
            let pos = self.findPosition(index)
            var attrs = attributes.map(Self.jsonAttributes) ?? [:]
            if attributes == nil {
                for (key, value) in pos.attributes where attrs[key] == nil { attrs[key] = value }
            }
            self.insertText(pos, text: Array(text.utf16), attributes: attrs)
        }
    }

    func delete(_ index: Int, _ length: Int) {
        guard length > 0 else { return }
        self.doc.transact {
            self.deleteText(self.findPosition(index), length: length)
        }
    }

    func format(_ index: Int, _ length: Int, attributes: [String: Lib0Any]) {
        guard length > 0 else { return }
        self.doc.transact {
            let pos = self.findPosition(index)
            guard pos.right != nil else { return }
            self.formatText(pos, length: length, attributes: Self.jsonAttributes(attributes))
        }
    }

    private static func jsonAttributes(_ attributes: [String: Lib0Any]) -> [String: String] {
        attributes.mapValues(JSONValue.string(from:))
    }

    // MARK: Position

    private func findPosition(_ index: Int) -> TextPosition {
        let pos = TextPosition(left: nil, right: self.type.start, index: 0, attributes: [:])
        var count = index
        while let right = pos.right, count > 0 {
            if case .format(let key, let value) = right.content {
                if !right.deleted { pos.apply(format: key, value) }
            } else if !right.deleted {
                if count < Int(right.length) {
                    _ = self.doc.store.getItemCleanStart(
                        YID(client: right.id.client, clock: right.id.clock + UInt64(count)))
                }
                pos.index += Int(right.length)
                count -= Int(right.length)
            }
            pos.left = right
            pos.right = right.right as? Item
        }
        return pos
    }

    private func makeItem(_ pos: TextPosition, content: Content) -> Item {
        let left = pos.left
        let right = pos.right
        let item = Item(
            id: YID(client: self.doc.clientID, clock: self.doc.store.getState(self.doc.clientID)),
            origin: left?.lastId,
            rightOrigin: right?.id,
            parent: self.type,
            parentID: nil,
            parentSub: nil,
            content: content
        )
        item.left = left
        item.right = right
        item.integrate(self.doc.store, offset: 0)
        return item
    }

    // MARK: Insert

    private func insertText(_ pos: TextPosition, text: [UInt16], attributes: [String: String]) {
        var attributes = attributes
        for key in pos.attributes.keys where attributes[key] == nil { attributes[key] = "null" }
        self.minimizeAttributeChanges(pos, attributes)
        let negated = self.insertAttributes(pos, attributes)
        let item = self.makeItem(pos, content: .string(text))
        pos.right = item
        pos.forward()
        self.insertNegatedAttributes(pos, negated)
    }

    private func minimizeAttributeChanges(_ pos: TextPosition, _ attributes: [String: String]) {
        while let right = pos.right {
            if right.deleted {
                // skip
            } else if let format = formatContent(right), equalAttrs(attributes[format.key], format.value) {
                // redundant format — skip over it
            } else {
                break
            }
            pos.forward()
        }
    }

    private func insertAttributes(_ pos: TextPosition, _ attributes: [String: String]) -> [String: String] {
        var negated: [String: String] = [:]
        // Sorted for deterministic output when several attributes are set at once
        // (the public `Attributes` dictionary loses yjs's object-key insertion order,
        // so multi-key format is a stable semantic — not byte — match to yjs).
        for key in attributes.keys.sorted() {
            let value = attributes[key]!
            let current = pos.attributes[key]
            if !equalAttrs(current, value) {
                negated[key] = current ?? "null"
                let item = self.makeItem(pos, content: .format(key: key, valueJSON: value))
                pos.right = item
                pos.forward()
            }
        }
        return negated
    }

    private func insertNegatedAttributes(_ pos: TextPosition, _ negated: [String: String]) {
        var negated = negated
        while let right = pos.right,
            right.deleted || (formatContent(right).map { equalAttrs(negated[$0.key], $0.value) } ?? false)
        {
            if !right.deleted, let format = formatContent(right) { negated.removeValue(forKey: format.key) }
            pos.forward()
        }
        for key in negated.keys.sorted() {
            let item = self.makeItem(pos, content: .format(key: key, valueJSON: negated[key]!))
            pos.right = item
            pos.forward()
        }
    }

    // MARK: Format

    private func formatText(_ pos: TextPosition, length: Int, attributes: [String: String]) {
        self.minimizeAttributeChanges(pos, attributes)
        var negated = self.insertAttributes(pos, attributes)
        var length = length
        while let right = pos.right,
            length > 0 || (!negated.isEmpty && (right.deleted || formatContent(right) != nil))
        {
            if !right.deleted {
                if let format = formatContent(right) {
                    if let attr = attributes[format.key] {
                        if equalAttrs(attr, format.value) {
                            negated.removeValue(forKey: format.key)
                        } else {
                            if length == 0 { break }
                            negated[format.key] = format.value
                        }
                        self.doc.store.deleteItem(right)
                    } else {
                        pos.attributes[format.key] = format.value
                    }
                } else {
                    if length < Int(right.length) {
                        _ = self.doc.store.getItemCleanStart(
                            YID(client: right.id.client, clock: right.id.clock + UInt64(length)))
                    }
                    length -= Int(right.length)
                }
            }
            pos.forward()
        }
        if length > 0 {
            let newlines = [UInt16](repeating: 0x0A, count: length)
            let item = self.makeItem(pos, content: .string(newlines))
            pos.right = item
            pos.forward()
        }
        self.insertNegatedAttributes(pos, negated)
    }

    // MARK: Delete

    private func deleteText(_ pos: TextPosition, length: Int) {
        let startAttributes = pos.attributes
        let start = pos.right
        var length = length
        while length > 0, let right = pos.right {
            if !right.deleted {
                switch right.content {
                case .string, .embed, .type:
                    if length < Int(right.length) {
                        _ = self.doc.store.getItemCleanStart(
                            YID(client: right.id.client, clock: right.id.clock + UInt64(length)))
                    }
                    length -= Int(right.length)
                    self.doc.store.deleteItem(right)
                default:
                    break
                }
            }
            pos.forward()
        }
        if let start {
            self.cleanupFormattingGap(
                start: start, end: pos.right, startAttributes: startAttributes, currentAttributes: pos.attributes)
        }
    }

    /// Removes formatting items made redundant by a deletion (`cleanupFormattingGap`).
    private func cleanupFormattingGap(
        start: Item, end curr: Item?, startAttributes: [String: String], currentAttributes: [String: String]
    ) {
        var currentAttributes = currentAttributes
        var end: Item? = start
        var endFormats: [String: (item: Item, value: String)] = [:]
        while let node = end, !node.countable || node.deleted {
            if !node.deleted, let format = formatContent(node) {
                endFormats[format.key] = (node, format.value)
            }
            end = node.right as? Item
        }
        var reachedCurr = false
        var node: Item? = start
        while let current = node, current !== end {
            if curr === current { reachedCurr = true }
            if !current.deleted, let format = formatContent(current) {
                let startAttrValue = startAttributes[format.key]
                if endFormats[format.key]?.item !== current || equalAttrs(startAttrValue, format.value) {
                    self.doc.store.deleteItem(current)
                    if !reachedCurr, equalAttrs(currentAttributes[format.key], format.value),
                        !equalAttrs(startAttrValue, format.value)
                    {
                        if let startAttrValue {
                            currentAttributes[format.key] = startAttrValue
                        } else {
                            currentAttributes.removeValue(forKey: format.key)
                        }
                    }
                }
                if !reachedCurr, !current.deleted {
                    if format.value == "null" {
                        currentAttributes.removeValue(forKey: format.key)
                    } else {
                        currentAttributes[format.key] = format.value
                    }
                }
            }
            node = current.right as? Item
        }
    }

    // MARK: toDelta

    /// Quill-delta JSON of the text (`YText.toDelta` with no snapshot), matching
    /// `JSON.stringify(ytext.toDelta())`.
    func toDeltaJSON() -> String {
        var ops: [String] = []
        var current: [(key: String, value: String)] = []
        var runUnits: [UInt16] = []

        func attributesObject() -> String {
            guard !current.isEmpty else { return "" }
            return ",\"attributes\":{"
                + current.map { "\(JSONValue.escaped($0.key)):\($0.value)" }.joined(separator: ",") + "}"
        }
        func packRun() {
            guard !runUnits.isEmpty else { return }
            let text = JSONValue.escaped(String(decoding: runUnits, as: UTF16.self))
            ops.append("{\"insert\":\(text)\(attributesObject())}")
            runUnits.removeAll(keepingCapacity: true)
        }
        func setAttribute(_ key: String, _ value: String) {
            if value == "null" {
                current.removeAll { $0.key == key }
            } else if let index = current.firstIndex(where: { $0.key == key }) {
                current[index].value = value
            } else {
                current.append((key, value))
            }
        }

        var node = self.type.start
        while let item = node {
            if !item.deleted {
                switch item.content {
                case .string(let units):
                    runUnits.append(contentsOf: units)
                case .format(let key, let value):
                    packRun()
                    setAttribute(key, value)
                default:
                    break
                }
            }
            node = item.right as? Item
        }
        packRun()
        return "[" + ops.joined(separator: ",") + "]"
    }

    // MARK: Change delta (observers)

    private enum DeltaAction { case insert, retain, delete }

    /// The change this text underwent in one transaction, as a Quill delta
    /// (`YTextEvent.delta`): items added this transaction become inserts, items
    /// deleted this transaction become deletes, everything else is a retain.
    /// `beforeState` is the store state before the transaction; `isDeleted` reports
    /// whether an id was deleted during it. Trailing attribute-less retains are
    /// trimmed. (Retain-with-attribute-change deltas from re-formatting existing
    /// text are not yet derived — inserts still carry their running attributes.)
    func changeDelta(beforeState: [UInt64: UInt64], isDeleted: (YID) -> Bool) -> [Delta] {
        var delta: [Delta] = []
        var attributes: [String: String] = [:]  // running attributes (valueJSON) for inserts
        var action: DeltaAction?
        var insertUnits: [UInt16] = []
        var insertValue: YValue?
        var retain = 0
        var deleteLen = 0

        func adds(_ item: Item) -> Bool { item.id.clock >= (beforeState[item.id.client] ?? 0) }

        func insertAttributes() -> Attributes? {
            guard !attributes.isEmpty else { return nil }
            var out: Attributes = [:]
            for (key, value) in attributes where value != "null" { out[key] = Self.parseAttribute(value) }
            return out.isEmpty ? nil : out
        }
        func addOp() {
            guard let currentAction = action else { return }
            switch currentAction {
            case .delete: if deleteLen > 0 { delta.append(.delete(deleteLen)) }
            case .insert:
                if let value = insertValue {
                    delta.append(.insert(value, attributes: insertAttributes()))
                } else if !insertUnits.isEmpty {
                    delta.append(
                        .insert(.string(String(decoding: insertUnits, as: UTF16.self)), attributes: insertAttributes()))
                }
            case .retain: if retain > 0 { delta.append(.retain(retain, attributes: nil)) }
            }
            deleteLen = 0
            insertUnits = []
            insertValue = nil
            retain = 0
            action = nil
        }

        var node = self.type.start
        while let item = node {
            switch item.content {
            case .format(let key, let value):
                if !item.deleted {
                    if value == "null" { attributes.removeValue(forKey: key) } else { attributes[key] = value }
                }
            case .string(let units):
                if adds(item) {
                    // Created this transaction; emit as insert unless also deleted here.
                    if !isDeleted(item.id) {
                        if action != .insert {
                            addOp()
                            action = .insert
                        }
                        insertUnits.append(contentsOf: units)
                    }
                } else if isDeleted(item.id) {
                    if action != .delete {
                        addOp()
                        action = .delete
                    }
                    deleteLen += Int(item.length)
                } else if !item.deleted {
                    if action != .retain {
                        addOp()
                        action = .retain
                    }
                    retain += Int(item.length)
                }
            default:
                // embed / type / any / json / binary: one countable unit.
                if adds(item) {
                    if !isDeleted(item.id) {
                        addOp()
                        action = .insert
                        insertValue = Self.insertValue(for: item.content)
                        addOp()
                    }
                } else if isDeleted(item.id) {
                    if action != .delete {
                        addOp()
                        action = .delete
                    }
                    deleteLen += Int(item.length)
                } else if !item.deleted {
                    if action != .retain {
                        addOp()
                        action = .retain
                    }
                    retain += Int(item.length)
                }
            }
            node = item.right as? Item
        }
        addOp()
        while case .retain(_, let attrs)? = delta.last, attrs == nil { delta.removeLast() }
        return delta
    }

    private static func insertValue(for content: Content) -> YValue {
        switch content {
        case .embed(let json): parseAttribute(json)
        case .any(let items): items.first.map(Self.yvalue) ?? .null
        default: .null
        }
    }

    /// Parses a JSON scalar/value string into a `YValue` (wrapped in an array to
    /// avoid top-level-fragment decoding limits).
    private static func parseAttribute(_ json: String) -> YValue {
        (try? JSONDecoder().decode([YValue].self, from: Data("[\(json)]".utf8)))?.first ?? .null
    }

    private static func yvalue(_ any: Lib0Any) -> YValue {
        switch any {
        case .null, .undefined: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): number == number.rounded(.towardZero) ? .int(Int64(number)) : .double(number)
        case .bigInt(let number): .int(number)
        case .string(let text): .string(text)
        case .bytes(let bytes): .data(Data(bytes))
        case .array(let items): .array(items.map(Self.yvalue))
        case .object(let pairs):
            .object(Dictionary(pairs.map { ($0.key, Self.yvalue($0.value)) }) { first, _ in first })
        }
    }
}
