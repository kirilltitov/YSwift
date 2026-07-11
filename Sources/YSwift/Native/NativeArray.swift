// Local Y.Array operations, ported from yjs v13.6.31 `types/AbstractType.js`
// (typeListInsertGenerics / typeListDelete / typeListToArray). An array is the
// same YATA list as text, but items carry `ContentAny` runs of JSON values
// instead of `ContentString`. Container support is an extension beyond the §4
// text subset; verified against golden fixtures.

final class NativeArray {
    let doc: NativeDoc
    let type: YTypeImpl

    init(doc: NativeDoc, type: YTypeImpl) {
        self.doc = doc
        self.type = type
    }

    /// Element count (countable, non-deleted).
    var length: Int { self.type.length }

    /// Inserts `values` (a run of JSON values) at element `index` as one
    /// `ContentAny` item.
    func insert(_ index: Int, _ values: [Lib0Any]) {
        guard !values.isEmpty else { return }
        self.doc.transact {
            let store = self.doc.store
            var left: Item?
            var right = self.type.start
            var remaining = index
            while let item = right, remaining > 0 {
                if !item.deleted {
                    if remaining < Int(item.length) {
                        // Split so a clean item boundary lands at `index`.
                        _ = store.getItemCleanStart(
                            YID(client: item.id.client, clock: item.id.clock + UInt64(remaining)))
                    }
                    remaining -= Int(item.length)
                }
                left = item
                right = item.right as? Item
            }
            let newItem = Item(
                id: YID(client: self.doc.clientID, clock: store.getState(self.doc.clientID)),
                origin: left?.lastId, rightOrigin: right?.id,
                parent: self.type, parentID: nil, parentSub: nil, content: .any(values))
            newItem.left = left
            newItem.right = right
            newItem.integrate(store, offset: 0)
        }
    }

    /// Deletes `count` elements starting at `index` (`typeListDelete`).
    func delete(_ index: Int, _ count: Int) {
        guard count > 0 else { return }
        self.doc.transact {
            let store = self.doc.store
            var node = self.type.start
            var skip = index
            while let item = node, skip > 0 {
                if !item.deleted {
                    if skip < Int(item.length) {
                        _ = store.getItemCleanStart(YID(client: item.id.client, clock: item.id.clock + UInt64(skip)))
                    }
                    skip -= Int(item.length)
                }
                node = item.right as? Item
            }
            var length = count
            while length > 0, let item = node {
                if !item.deleted {
                    if length < Int(item.length) {
                        _ = store.getItemCleanStart(
                            YID(client: item.id.client, clock: item.id.clock + UInt64(length)))
                    }
                    store.deleteItem(item)
                    length -= Int(item.length)
                }
                node = item.right as? Item
            }
        }
    }

    /// Materialises the array as JSON-ish values (`typeListToArray`).
    func toArray() -> [Lib0Any] {
        var result: [Lib0Any] = []
        var node = self.type.start
        while let item = node {
            if !item.deleted {
                switch item.content {
                case .any(let values): result.append(contentsOf: values)
                case .string(let units): result.append(.string(String(decoding: units, as: UTF16.self)))
                case .binary(let bytes): result.append(.bytes(bytes))
                default: break  // nested types / doc: not yet materialised
                }
            }
            node = item.right as? Item
        }
        return result
    }
}
