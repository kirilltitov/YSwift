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
/// fields needed to converge and to render text are modelled. Text is UTF-16 code units
/// so offsets match JS string semantics exactly. Runs are held as slices so that splitting
/// a long one does not copy all of it (see `splice`).
enum Content {
    case string(ArraySlice<UInt16>)  // ContentString
    case format(key: String, valueJSON: String)  // ContentFormat (raw JSON value)
    case embed(json: String)  // ContentEmbed (raw JSON)
    case deleted(UInt64)  // ContentDeleted
    case any(ArraySlice<Lib0Any>)  // ContentAny
    case json(ArraySlice<String>)  // ContentJSON (raw element strings)
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
            self = .deleted(0)
            var (left, right) = Self.split(&units, at: offset)
            // yjs replaces a split surrogate pair with U+FFFD on both halves.
            if let last = left.last, last >= 0xD800, last <= 0xDBFF {
                left[left.index(before: left.endIndex)] = 0xFFFD
                if !right.isEmpty { right[right.startIndex] = 0xFFFD }
            }
            self = .string(left)
            return .string(right)
        case .deleted(let count):
            self = .deleted(UInt64(offset))
            return .deleted(count - UInt64(offset))
        case .any(var items):
            self = .deleted(0)
            let (left, right) = Self.split(&items, at: offset)
            self = .any(left)
            return .any(right)
        case .json(var items):
            self = .deleted(0)
            let (left, right) = Self.split(&items, at: offset)
            self = .json(left)
            return .json(right)
        case .format, .embed, .binary, .type, .doc:
            preconditionFailure("splice() called on non-splittable content")
        }
    }

    /// Splits `elements` after `offset` of them, leaving it empty. The smaller half is copied out
    /// and the larger one keeps the storage, alone: a split costs at most the smaller half however
    /// long the run, and neither half holds on to much more storage than it uses.
    private static func split<Element>(
        _ elements: inout ArraySlice<Element>,
        at offset: Int,
    ) -> (left: ArraySlice<Element>, right: ArraySlice<Element>) {
        let split = elements.startIndex + offset
        let halves =
            offset <= elements.count - offset
            ? (Array(elements[..<split])[...], elements[split...])
            : (elements[..<split], Array(elements[split...])[...])
        elements = []
        return halves
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

    /// Whether `mergeWith(other)` appends `other` (`AbstractContent.mergeWith`): only string, deleted,
    /// any and json content merge, each with its own kind.
    func canMerge(with other: Content) -> Bool {
        switch (self, other) {
        case (.string, .string), (.deleted, .deleted), (.any, .any), (.json, .json): true
        default: false
        }
    }

    /// Appends `other`'s payload to `self` if the kind supports it (`AbstractContent.mergeWith`). The
    /// payload grows in place, so merging a run of n structs into its first one copies each once.
    mutating func mergeWith(_ other: Content) -> Bool {
        // `self` is emptied before appending so that the payload is not shared while it grows.
        switch other {
        case .string(let rhs):
            guard case .string(var lhs) = self else { return false }
            self = .deleted(0)
            lhs.append(contentsOf: rhs)
            self = .string(lhs)
        case .deleted(let rhs):
            guard case .deleted(let lhs) = self else { return false }
            self = .deleted(lhs + rhs)
        case .any(let rhs):
            guard case .any(var lhs) = self else { return false }
            self = .deleted(0)
            lhs.append(contentsOf: rhs)
            self = .any(lhs)
        case .json(let rhs):
            guard case .json(var lhs) = self else { return false }
            self = .deleted(0)
            lhs.append(contentsOf: rhs)
            self = .json(lhs)
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
            encoder.writeVarString(String(decoding: units.dropFirst(offset), as: UTF16.self))
        case .deleted(let count):
            encoder.writeVarUint(count - UInt64(offset))
        case .any(let items):
            encoder.writeVarUint(UInt64(items.count - offset))
            for item in items.dropFirst(offset) { encoder.writeAny(item) }
        case .json(let items):
            encoder.writeVarUint(UInt64(items.count - offset))
            for item in items.dropFirst(offset) { encoder.writeVarString(item) }
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
    /// or nil once all dependencies are present (resolving links as a side effect). Throws
    /// `YError.invalidUpdate` for a reference to its own client that is not present.
    func getMissing(_ store: NativeStore) throws -> UInt64? { nil }

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

    /// Whether `mergeWith(right)` absorbs `right`, without changing either.
    func canMerge(with right: Struct) -> Bool { false }

    /// Absorbs the adjacent right-hand struct if compatible (`AbstractStruct.mergeWith`).
    func mergeWith(_ right: Struct) -> Bool { false }
}

/// A garbage-collected range — occupies clocks but carries no content.
final class GCStruct: Struct {
    override var isDeleted: Bool { true }

    override func canMerge(with right: Struct) -> Bool {
        right is GCStruct && self.id.clock + self.length == right.id.clock
    }

    override func mergeWith(_ right: Struct) -> Bool {
        guard self.canMerge(with: right) else { return false }
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
    /// Set once this item has been re-created by an undo/redo (`Item.redone`).
    var redone: YID?

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

    /// `keep` protects a deleted item from garbage collection so an UndoManager can
    /// still re-create its content (`Item.keep` / `keepItem`).
    var keep: Bool { (self.info & Bit.keep) != 0 }
    func setKeep(_ value: Bool) { if self.keep != value { self.info ^= Bit.keep } }

    /// Last clock address covered by this item.
    var lastId: YID {
        self.length == 1 ? self.id : YID(client: self.id.client, clock: self.id.clock + self.length - 1)
    }

    override func getMissing(_ store: NativeStore) throws -> UInt64? {
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

        // References to the item's own client are not waited for: they must already be present. Yjs
        // resolves them unchecked, and its `findIndexSS` throws when a malformed update points at a
        // clock the client has not reached.
        for id in [self.origin, self.rightOrigin, self.parentID] {
            if let id, id.clock >= store.getState(id.client) { throw YError.invalidUpdate }
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
            if parent.map[parentSub] == nil { parent.mapKeys.append(parentSub) }
            parent.map[parentSub] = self
            if let leftItem = self.left as? Item { store.deleteItem(leftItem) }
        }

        if self.parentSub == nil, self.countable, !self.deleted {
            parent.length += Int(self.length)
        }
        store.addStruct(self)

        if case .type(let type, _, _) = self.content {
            type.item = self  // ContentType.integrate
            type.depth = parent.depth + 1
        }
        if case .format = self.content {
            parent.hasFormatting = true  // disables search markers (attribute-safe)
        }
        if case .deleted = self.content {
            // ContentDeleted.integrate: the item arrives deleted and joins the transaction's delete
            // set in integration order, which an UndoManager's redo order follows.
            store.deleteLog?.append((self.id.client, self.id.clock, self.length))
            self.markDeleted()
        }

        if (parent.item?.deleted ?? false) || (self.parentSub != nil && self.right != nil) {
            store.deleteItem(self)
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

    /// Whether this item and the adjacent right item form a contiguous, same-origin, same-content,
    /// same-deleted run (the conditions of `Item.mergeWith`).
    override func canMerge(with right: Struct) -> Bool {
        guard let right = right as? Item else { return false }
        return sameID(right.origin, self.lastId)
            && self.right === right
            && sameID(self.rightOrigin, right.rightOrigin)
            && self.id.client == right.id.client
            && self.id.clock + self.length == right.id.clock
            && self.deleted == right.deleted
            && self.redone == nil && right.redone == nil  // never merge across an undo/redo re-creation
            && self.content.canMerge(with: right.content)
    }

    /// Merges the adjacent right item into this one when `canMerge(with:)` (`Item.mergeWith`).
    override func mergeWith(_ right: Struct) -> Bool {
        guard self.canMerge(with: right), let right = right as? Item, self.content.mergeWith(right.content) else {
            return false
        }
        if right.keep { self.setKeep(true) }
        self.right = right.right
        (right.right as? Item)?.left = self
        self.length += right.length
        return true
    }
}

/// A container type (yjs `AbstractType`): the head of a child list plus a key→item
/// map for map/attribute entries. Held strongly by its `ContentType` item (or by
/// `NativeDoc.share` for roots); all links back into the struct graph are `weak`
/// (or store-owned via `map`) so no cycle forms.
final class YTypeImpl {
    weak var start: Item?
    var map: [String: Item] = [:]
    /// The keys of `map` in the order they were first set: the iteration order of the yjs `_map`.
    var mapKeys: [String] = []
    var length: Int = 0
    weak var item: Item?
    let name: String?
    /// How many types this one is nested in: 0 for a root.
    var depth = 0

    /// Cached search marker (`findPosition` hint): `markerItem` starts at absolute
    /// index `markerIndex`, valid while `markerVersion == store.version`.
    weak var markerItem: Item?
    var markerIndex: Int = 0
    var markerVersion: Int = -1
    /// Once any formatting item lives under this type, search markers are disabled
    /// (a mid-list start would miss the running attributes).
    var hasFormatting = false

    init(name: String? = nil) {
        self.name = name
    }
}
