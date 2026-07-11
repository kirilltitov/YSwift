// Sticky index (yjs `RelativePosition`): a position in a text/list that survives
// concurrent edits. Ported from yjs v13.6.31 `utils/RelativePosition.js`, v1 wire
// format. `assoc >= 0` binds to the character on the right, `assoc < 0` to the left.

/// An unresolved position: the id of the item to its right (`item`), or — when at
/// the end of a type — the parent type addressed by root key (`tname`) or by the
/// id of the item holding it (`type`). Plus the left/right association.
struct NativeRelativePosition: Equatable, Sendable {
    var type: YID?
    var tname: String?
    var item: YID?
    var assoc: Int64

    /// v1 bytes (`writeRelativePosition`): a tag (0 item / 1 tname / 2 type), the
    /// referent, then the signed association.
    func encode() -> [UInt8] {
        var encoder = Lib0Encoder()
        if let item = self.item {
            encoder.writeVarUint(0)
            encoder.writeVarUint(item.client)
            encoder.writeVarUint(item.clock)
        } else if let tname = self.tname {
            encoder.writeUInt8(1)
            encoder.writeVarString(tname)
        } else if let type = self.type {
            encoder.writeUInt8(2)
            encoder.writeVarUint(type.client)
            encoder.writeVarUint(type.clock)
        }
        encoder.writeVarInt(self.assoc)
        return encoder.bytes
    }

    /// Parses v1 bytes (`readRelativePosition`). A missing trailing assoc reads 0.
    static func decode(_ bytes: [UInt8]) throws -> NativeRelativePosition {
        var decoder = Lib0Decoder(bytes)
        var type: YID?
        var tname: String?
        var item: YID?
        switch try decoder.readVarUint() {
        case 0: item = YID(client: try decoder.readVarUint(), clock: try decoder.readVarUint())
        case 1: tname = try decoder.readVarString()
        case 2: type = YID(client: try decoder.readVarUint(), clock: try decoder.readVarUint())
        default: break
        }
        let assoc = decoder.hasRemaining ? try decoder.readVarInt() : 0
        return NativeRelativePosition(type: type, tname: tname, item: item, assoc: assoc)
    }
}

extension NativeText {
    /// Builds a sticky index for absolute `index` with association `assoc`
    /// (`createRelativePositionFromTypeIndex`).
    func stickyIndex(at index: Int, assoc: Int64 = 0) -> NativeRelativePosition {
        var index = index
        var node = self.type.start
        if assoc < 0 {
            if index == 0 { return Self.relativePosition(self.type, item: nil, assoc: assoc) }
            index -= 1
        }
        while let item = node {
            if !item.deleted, item.countable {
                if Int(item.length) > index {
                    return Self.relativePosition(
                        self.type,
                        item: YID(client: item.id.client, clock: item.id.clock + UInt64(index)),
                        assoc: assoc
                    )
                }
                index -= Int(item.length)
            }
            if item.right == nil, assoc < 0 {
                return Self.relativePosition(self.type, item: item.lastId, assoc: assoc)
            }
            node = item.right as? Item
        }
        return Self.relativePosition(self.type, item: nil, assoc: assoc)
    }

    /// `createRelativePosition`: address the parent type by root key or by its item id.
    fileprivate static func relativePosition(_ type: YTypeImpl, item: YID?, assoc: Int64)
        -> NativeRelativePosition
    {
        if let owner = type.item {
            return NativeRelativePosition(type: owner.id, tname: nil, item: item, assoc: assoc)
        }
        return NativeRelativePosition(type: nil, tname: type.name, item: item, assoc: assoc)
    }
}

extension NativeDoc {
    /// Resolves a sticky index to its current `(type, index)`
    /// (`createAbsolutePositionFromRelativePosition`), or nil if the referent is not
    /// present yet / was garbage collected.
    func resolve(_ rpos: NativeRelativePosition) -> (type: YTypeImpl, index: Int)? {
        if let rightID = rpos.item {
            guard self.store.getState(rightID.client) > rightID.clock else { return nil }
            let right = self.store.getItem(rightID)
            guard let rightItem = right as? Item, let type = rightItem.parent else { return nil }
            let diff = Int(rightID.clock - rightItem.id.clock)
            var index = 0
            if type.item == nil || !(type.item?.deleted ?? false) {
                index = (rightItem.deleted || !rightItem.countable) ? 0 : (diff + (rpos.assoc >= 0 ? 0 : 1))
                var node = rightItem.left as? Item
                while let current = node {
                    if !current.deleted, current.countable { index += Int(current.length) }
                    node = current.left as? Item
                }
            }
            return (type, index)
        }
        if let tname = rpos.tname {
            let type = self.get(tname)
            return (type, rpos.assoc >= 0 ? type.length : 0)
        }
        if let typeID = rpos.type {
            guard self.store.getState(typeID.client) > typeID.clock else { return nil }
            guard case .type(let type, _, _)? = (self.store.getItem(typeID) as? Item)?.content else { return nil }
            return (type, rpos.assoc >= 0 ? type.length : 0)
        }
        return nil
    }
}
