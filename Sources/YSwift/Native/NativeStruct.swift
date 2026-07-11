// The integrated document model: structs (Item / GC / Skip) living in the arena
// `NativeStore`, plus the container type `YTypeImpl`. This is a faithful port of
// yjs v13.6.31 `structs/Item.js` + `AbstractType`, adapted to Swift's memory model:
// the store's per-client arrays are the sole strong owners of every struct, and all
// sibling/parent links are `weak`, so the doubly-linked graph never forms an ARC
// retain cycle and the whole document frees when the store drops.

/// lib0 `binary` bit flags used by `Item.info` (bitN == 1 << (n - 1)).
private enum Bit {
    static let keep: UInt8 = 0b0000_0001  // BIT1
    static let countable: UInt8 = 0b0000_0010  // BIT2
    static let deleted: UInt8 = 0b0000_0100  // BIT3
}

/// Compares two optional ids with yjs `compareIDs` semantics: both nil is equal.
@inline(__always)
func sameID(_ lhs: YID?, _ rhs: YID?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case (let l?, let r?): l == r
    default: false
    }
}

/// The integrated payload of an `Item`. Mirrors yjs `Content*` classes; only the
/// fields needed to converge and to render text are modelled. Text is `[UInt16]`
/// so offsets match JS string (UTF-16) semantics exactly.
enum Content {
    case string([UInt16])  // ContentString
    case format(key: String, valueJSON: String)  // ContentFormat (raw JSON value)
    case embed(json: String)  // ContentEmbed (raw JSON)
    case deleted(UInt64)  // ContentDeleted
    case any([Lib0Any])  // ContentAny
    case json([String])  // ContentJSON (raw element strings)
    case binary([UInt8])  // ContentBinary
    case type(YTypeImpl, typeRef: UInt64, name: String?)  // ContentType
    case doc(guid: String, options: Lib0Any)  // ContentDoc

    /// Number of clocks this content occupies — matches `AbstractContent.getLength`.
    var length: UInt64 {
        switch self {
        case .string(let units): UInt64(units.count)
        case .deleted(let count): count
        case .any(let items): UInt64(items.count)
        case .json(let items): UInt64(items.count)
        case .format, .embed, .binary, .type, .doc: 1
        }
    }

    /// `AbstractContent.isCountable` — deleted and format content is not countable.
    var isCountable: Bool {
        switch self {
        case .format, .deleted: false
        default: true
        }
    }

    /// Splits off and returns everything from `offset` onward, leaving `self` as the
    /// prefix `[0, offset)`. Mirrors `Content*.splice`, including the surrogate-pair
    /// guard in `ContentString.splice`.
    mutating func splice(_ offset: Int) -> Content {
        switch self {
        case .string(var units):
            var right = Array(units[offset...])
            units.removeSubrange(offset...)
            // yjs replaces a split surrogate pair with U+FFFD on both halves.
            if offset > 0, offset <= units.count {
                let last = units[offset - 1]
                if last >= 0xD800, last <= 0xDBFF {
                    units[offset - 1] = 0xFFFD
                    if !right.isEmpty { right[0] = 0xFFFD }
                }
            }
            self = .string(units)
            return .string(right)
        case .deleted(let count):
            self = .deleted(UInt64(offset))
            return .deleted(count - UInt64(offset))
        case .any(let items):
            let right = Array(items[offset...])
            self = .any(Array(items[..<offset]))
            return .any(right)
        case .json(let items):
            let right = Array(items[offset...])
            self = .json(Array(items[..<offset]))
            return .json(right)
        case .format, .embed, .binary, .type, .doc:
            preconditionFailure("splice() called on non-splittable content")
        }
    }

    /// Content type tag written into the low 5 bits of an item's info byte
    /// (`AbstractContent.getRef`).
    var ref: UInt8 {
        switch self {
        case .deleted: 1
        case .json: 2
        case .binary: 3
        case .string: 4
        case .embed: 5
        case .format: 6
        case .type: 7
        case .any: 8
        case .doc: 9
        }
    }

    /// Whether `other` is the same content kind (for merge eligibility).
    func sameKind(as other: Content) -> Bool { self.ref == other.ref }

    /// Appends `other`'s payload to `self` if the kind supports it
    /// (`AbstractContent.mergeWith`). Only string/deleted/any/json merge.
    mutating func mergeWith(_ other: Content) -> Bool {
        switch (self, other) {
        case (.string(let lhs), .string(let rhs)):
            self = .string(lhs + rhs)
        case (.deleted(let lhs), .deleted(let rhs)):
            self = .deleted(lhs + rhs)
        case (.any(let lhs), .any(let rhs)):
            self = .any(lhs + rhs)
        case (.json(let lhs), .json(let rhs)):
            self = .json(lhs + rhs)
        default:
            return false
        }
        return true
    }

    /// Writes the content payload, dropping the first `offset` clocks
    /// (`AbstractContent.write`).
    func write(into encoder: inout Lib0Encoder, offset: Int) {
        switch self {
        case .string(let units):
            let slice = offset == 0 ? units : Array(units[offset...])
            encoder.writeVarString(String(decoding: slice, as: UTF16.self))
        case .deleted(let count):
            encoder.writeVarUint(count - UInt64(offset))
        case .any(let items):
            encoder.writeVarUint(UInt64(items.count - offset))
            for index in offset..<items.count { encoder.writeAny(items[index]) }
        case .json(let items):
            encoder.writeVarUint(UInt64(items.count - offset))
            for index in offset..<items.count { encoder.writeVarString(items[index]) }
        case .binary(let bytes):
            encoder.writeVarUint8Array(bytes)
        case .embed(let json):
            encoder.writeVarString(json)
        case .format(let key, let valueJSON):
            encoder.writeVarString(key)
            encoder.writeVarString(valueJSON)
        case .type(_, let typeRef, let name):
            encoder.writeVarUint(typeRef)
            if typeRef == 3 || typeRef == 5, let name { encoder.writeVarString(name) }
        case .doc(let guid, let options):
            encoder.writeVarString(guid)
            encoder.writeAny(options)
        }
    }
}

/// Base class for everything stored in `NativeStore.clients`. `id`/`length` are
/// mutable because integration with a positive offset advances the clock and the
/// delete-set / clean-split paths shrink structs in place.
class Struct {
    var id: YID
    var length: UInt64

    init(id: YID, length: UInt64) {
        self.id = id
        self.length = length
    }

    /// Returns the client whose data must arrive before this struct can integrate,
    /// or nil once all dependencies are present (resolving links as a side effect).
    func getMissing(_ store: NativeStore) -> UInt64? { nil }

    /// Integrates this struct into `store`. Base behaviour (used by GC) just trims
    /// by `offset` and appends.
    func integrate(_ store: NativeStore, offset: Int) {
        if offset > 0 {
            self.id = YID(client: self.id.client, clock: self.id.clock + UInt64(offset))
            self.length -= UInt64(offset)
        }
        store.addStruct(self)
    }

    /// Serialises this struct. Base behaviour writes a GC struct (info byte 0 + len).
    func write(into encoder: inout Lib0Encoder, offset: Int) {
        encoder.writeUInt8(0)
        encoder.writeVarUint(self.length - UInt64(offset))
    }

    /// Whether this struct counts as deleted for merge/delete-set purposes.
    var isDeleted: Bool { false }

    /// Absorbs the adjacent right-hand struct if compatible (`AbstractStruct.mergeWith`).
    func mergeWith(_ right: Struct) -> Bool { false }
}

/// A garbage-collected range — occupies clocks but carries no content.
final class GCStruct: Struct {
    override var isDeleted: Bool { true }

    override func mergeWith(_ right: Struct) -> Bool {
        guard right is GCStruct, self.id.clock + self.length == right.id.clock else { return false }
        self.length += right.length
        return true
    }
}

/// A gap in a client's clock range (`readClientsStructRefs` emits these; they are
/// never integrated).
final class SkipStruct: Struct {}

/// An integrated YATA item.
final class Item: Struct {
    weak var left: Struct?
    weak var right: Struct?
    var origin: YID?
    var rightOrigin: YID?
    /// Resolved parent container (nil until resolved, or when the item is orphaned).
    weak var parent: YTypeImpl?
    /// Parent given by id on the wire, pending resolution in `getMissing`.
    var parentID: YID?
    var parentSub: String?
    var content: Content
    /// lib0 `binary` bit flags (keep / countable / deleted).
    var info: UInt8

    init(
        id: YID,
        origin: YID?,
        rightOrigin: YID?,
        parent: YTypeImpl?,
        parentID: YID?,
        parentSub: String?,
        content: Content
    ) {
        self.origin = origin
        self.rightOrigin = rightOrigin
        self.parent = parent
        self.parentID = parentID
        self.parentSub = parentSub
        self.content = content
        self.info = content.isCountable ? Bit.countable : 0
        super.init(id: id, length: content.length)
    }

    var deleted: Bool { (self.info & Bit.deleted) != 0 }
    var countable: Bool { (self.info & Bit.countable) != 0 }
    func markDeleted() { self.info |= Bit.deleted }

    /// Last clock address covered by this item.
    var lastId: YID {
        self.length == 1 ? self.id : YID(client: self.id.client, clock: self.id.clock + self.length - 1)
    }

    override func getMissing(_ store: NativeStore) -> UInt64? {
        if let origin, origin.client != self.id.client, origin.clock >= store.getState(origin.client) {
            return origin.client
        }
        if let rightOrigin, rightOrigin.client != self.id.client,
            rightOrigin.clock >= store.getState(rightOrigin.client)
        {
            return rightOrigin.client
        }
        if let parentID, self.id.client != parentID.client, parentID.clock >= store.getState(parentID.client) {
            return parentID.client
        }

        // All dependencies present — resolve the links.
        if let origin {
            let leftStruct = store.getItemCleanEnd(origin)
            self.left = leftStruct
            self.origin = (leftStruct as? Item)?.lastId ?? leftStruct.id
        }
        if let rightOrigin {
            let rightStruct = store.getItemCleanStart(rightOrigin)
            self.right = rightStruct
            self.rightOrigin = rightStruct.id
        }
        if self.left is GCStruct || self.right is GCStruct {
            self.parent = nil
            self.parentID = nil
        } else if self.parent == nil, self.parentID == nil {
            // Parent was omitted on the wire — inherit it from a neighbour.
            if let leftItem = self.left as? Item {
                self.parent = leftItem.parent
                self.parentSub = leftItem.parentSub
            } else if let rightItem = self.right as? Item {
                self.parent = rightItem.parent
                self.parentSub = rightItem.parentSub
            }
        } else if let parentID {
            let parentStruct = store.getItem(parentID)
            if case .type(let type, _, _)? = (parentStruct as? Item)?.content {
                self.parent = type
            } else {
                self.parent = nil
            }
            self.parentID = nil
        }
        return nil
    }

    override func integrate(_ store: NativeStore, offset: Int) {
        if offset > 0 {
            self.id = YID(client: self.id.client, clock: self.id.clock + UInt64(offset))
            let leftStruct = store.getItemCleanEnd(YID(client: self.id.client, clock: self.id.clock - 1))
            self.left = leftStruct
            self.origin = (leftStruct as? Item)?.lastId ?? leftStruct.id
            self.content = self.content.splice(offset)
            self.length -= UInt64(offset)
        }

        guard let parent = self.parent else {
            // Orphaned — integrate a GC struct in its place.
            GCStruct(id: self.id, length: self.length).integrate(store, offset: 0)
            return
        }

        let leftItem = self.left as? Item
        let rightItem = self.right as? Item
        let needsConflictResolution =
            (leftItem == nil && (rightItem == nil || rightItem?.left != nil))
            || (leftItem != nil && !(leftItem?.right === self.right))
        if needsConflictResolution {
            var left: Item? = leftItem
            var conflicting = Set<ObjectIdentifier>()
            var beforeOrigin = Set<ObjectIdentifier>()

            var o: Item?
            if let leftItem {
                o = leftItem.right as? Item
            } else if let parentSub {
                o = parent.map[parentSub]
                while let cur = o, cur.left != nil { o = cur.left as? Item }
            } else {
                o = parent.start
            }

            while let cur = o, cur !== (self.right as? Item) {
                beforeOrigin.insert(ObjectIdentifier(cur))
                conflicting.insert(ObjectIdentifier(cur))
                if sameID(self.origin, cur.origin) {
                    // case 1: same left origin — lower client id wins the left slot.
                    if cur.id.client < self.id.client {
                        left = cur
                        conflicting.removeAll(keepingCapacity: true)
                    } else if sameID(self.rightOrigin, cur.rightOrigin) {
                        break
                    }
                } else if let curOrigin = cur.origin,
                    beforeOrigin.contains(ObjectIdentifier(store.getItem(curOrigin)))
                {
                    // case 2
                    if !conflicting.contains(ObjectIdentifier(store.getItem(curOrigin))) {
                        left = cur
                        conflicting.removeAll(keepingCapacity: true)
                    }
                } else {
                    break
                }
                o = cur.right as? Item
            }
            self.left = left
        }

        // Reconnect the linked list and update parent start/map.
        if let leftItem = self.left as? Item {
            let rightAfterLeft = leftItem.right
            self.right = rightAfterLeft
            leftItem.right = self
        } else {
            var r: Item?
            if let parentSub {
                r = parent.map[parentSub]
                while let cur = r, cur.left != nil { r = cur.left as? Item }
            } else {
                r = parent.start
                parent.start = self
            }
            self.right = r
        }
        if let rightItem = self.right as? Item {
            rightItem.left = self
        } else if let parentSub {
            parent.map[parentSub] = self
            (self.left as? Item)?.delete()
        }

        if self.parentSub == nil, self.countable, !self.deleted {
            parent.length += Int(self.length)
        }
        store.addStruct(self)

        if case .type(let type, _, _) = self.content {
            type.item = self  // ContentType.integrate
        }

        if (parent.item?.deleted ?? false) || (self.parentSub != nil && self.right != nil) {
            self.delete()
        }
    }

    /// Serialises the item, reconstructing the info byte and parent reference from
    /// its integrated state (`Item.write`). The origin for a mid-struct offset is
    /// the clock just before the written slice.
    override func write(into encoder: inout Lib0Encoder, offset: Int) {
        let origin: YID? =
            offset > 0
            ? YID(client: self.id.client, clock: self.id.clock + UInt64(offset) - 1)
            : self.origin
        let info =
            (self.content.ref & 0x1F)
            | (origin == nil ? 0 : 0x80)
            | (self.rightOrigin == nil ? 0 : 0x40)
            | (self.parentSub == nil ? 0 : 0x20)
        encoder.writeUInt8(info)
        if let origin {
            encoder.writeVarUint(origin.client)
            encoder.writeVarUint(origin.clock)
        }
        if let rightOrigin = self.rightOrigin {
            encoder.writeVarUint(rightOrigin.client)
            encoder.writeVarUint(rightOrigin.clock)
        }
        if origin == nil, self.rightOrigin == nil {
            if let parent = self.parent {
                if let parentItem = parent.item {
                    encoder.writeVarUint(0)  // parent id
                    encoder.writeVarUint(parentItem.id.client)
                    encoder.writeVarUint(parentItem.id.clock)
                } else {
                    encoder.writeVarUint(1)  // root key
                    encoder.writeVarString(parent.name ?? "")
                }
            }
            if let parentSub = self.parentSub {
                encoder.writeVarString(parentSub)
            }
        }
        self.content.write(into: &encoder, offset: offset)
    }

    override var isDeleted: Bool { self.deleted }

    /// Merges the adjacent right item into this one when they form a contiguous,
    /// same-origin, same-content, same-deleted run (`Item.mergeWith`).
    override func mergeWith(_ right: Struct) -> Bool {
        guard let right = right as? Item,
            sameID(right.origin, self.lastId),
            self.right === right,
            sameID(self.rightOrigin, right.rightOrigin),
            self.id.client == right.id.client,
            self.id.clock + self.length == right.id.clock,
            self.deleted == right.deleted,
            self.content.sameKind(as: right.content),
            self.content.mergeWith(right.content)
        else { return false }
        self.right = right.right
        (right.right as? Item)?.left = self
        self.length += right.length
        return true
    }

    /// Marks the item deleted and keeps parent length in sync (`Item.delete`).
    func delete() {
        guard !self.deleted else { return }
        if self.countable, self.parentSub == nil {
            self.parent?.length -= Int(self.length)
        }
        self.markDeleted()
    }
}

/// A container type (yjs `AbstractType`): the head of a child list plus a key→item
/// map for map/attribute entries. Held strongly by its `ContentType` item (or by
/// `NativeDoc.share` for roots); all links back into the struct graph are `weak`
/// (or store-owned via `map`) so no cycle forms.
final class YTypeImpl {
    weak var start: Item?
    var map: [String: Item] = [:]
    var length: Int = 0
    weak var item: Item?
    let name: String?

    init(name: String? = nil) {
        self.name = name
    }
}
