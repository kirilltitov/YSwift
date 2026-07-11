// Local Y.Map operations, ported from yjs v13.6.31 `types/AbstractType.js`
// (typeMapSet / typeMapGet / typeMapDelete). A map entry is an item whose
// `parentSub` is the key; the type's `map[key]` always points at the current
// (last-writer) value item, and integration deletes the previous one. The
// integrate/parentSub machinery is already in place (M3); this adds the local
// ops + materialisation. Container support is an extension beyond the §4 subset.

final class NativeMap {
    let doc: NativeDoc
    let type: YTypeImpl

    init(doc: NativeDoc, type: YTypeImpl) {
        self.doc = doc
        self.type = type
    }

    /// Sets `key` to `value` (`typeMapSet`). The new item's left is the current
    /// value item for the key; integration makes it the current value and deletes
    /// the previous one.
    func set(_ key: String, _ value: Lib0Any) {
        self.doc.transact {
            let store = self.doc.store
            let left = self.type.map[key]
            let content: Content
            if case .bytes(let bytes) = value {
                content = .binary(bytes)
            } else {
                content = .any([value])
            }
            let item = Item(
                id: YID(client: self.doc.clientID, clock: store.getState(self.doc.clientID)),
                origin: left?.lastId, rightOrigin: nil,
                parent: self.type, parentID: nil, parentSub: key, content: content)
            item.left = left
            item.right = nil
            item.integrate(store, offset: 0)
        }
    }

    /// Removes `key` (`typeMapDelete`).
    func delete(_ key: String) {
        self.doc.transact {
            if let item = self.type.map[key], !item.deleted { self.doc.store.deleteItem(item) }
        }
    }

    /// The current value for `key`, or nil (`typeMapGet`).
    func get(_ key: String) -> Lib0Any? {
        guard let item = self.type.map[key], !item.deleted else { return nil }
        return Self.value(of: item)
    }

    /// Keys with a live value.
    func keys() -> [String] {
        self.type.map.compactMap { key, item in item.deleted ? nil : key }
    }

    /// All live entries as a dictionary (`toJSON`).
    func toDictionary() -> [String: Lib0Any] {
        var result: [String: Lib0Any] = [:]
        for (key, item) in self.type.map where !item.deleted {
            if let value = Self.value(of: item) { result[key] = value }
        }
        return result
    }

    private static func value(of item: Item) -> Lib0Any? {
        switch item.content {
        case .any(let values): values.last
        case .binary(let bytes): .bytes(bytes)
        default: nil  // nested types / doc: not yet materialised
        }
    }
}
