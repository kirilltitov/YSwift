// Structural model of a decoded Yjs v1 update. It preserves every parsed field
// (including the raw Item `info` byte) so the update can be re-encoded byte-for-
// byte without integrating it into a document — the M2 gate.

/// An Item's parent, as it appears on the wire (unresolved).
enum ParentRef: Sendable {
    /// Parent is a root type, referenced by its share key (parentInfo == 1).
    case rootKey(String)
    /// Parent is another item, referenced by id (parentInfo == 0).
    case id(YID)
}

/// Parsed content of an Item. Raw JSON strings and `Lib0Any` are preserved so
/// re-encoding reproduces the exact bytes.
enum ContentRef: Sendable {
    case deleted(UInt64)  // ref 1
    case json([String])  // ref 2 — raw element strings, incl. the literal "undefined"
    case binary([UInt8])  // ref 3
    case string(String)  // ref 4
    case embed(String)  // ref 5 — raw JSON string
    case format(key: String, value: String)  // ref 6 — value is a raw JSON string
    case type(ref: UInt64, name: String?)  // ref 7 — name for YXmlElement / YXmlHook
    case any([Lib0Any])  // ref 8
    case doc(guid: String, options: Lib0Any)  // ref 9

    /// Clocks this content occupies.
    var length: UInt64 {
        switch self {
        case .deleted(let n): n
        case .json(let elements): UInt64(elements.count)
        case .any(let elements): UInt64(elements.count)
        case .string(let string): UInt64(string.utf16.count)
        case .binary, .embed, .format, .type, .doc: 1
        }
    }
}

struct ItemRef: Sendable {
    let id: YID
    /// The raw first byte — preserved verbatim (its `parentSub`-present bit may be
    /// set even when no `parentSub` string is written, for chained entries).
    let info: UInt8
    let origin: YID?
    let rightOrigin: YID?
    let parent: ParentRef?
    let parentSub: String?
    let content: ContentRef

    var length: UInt64 { self.content.length }
}

enum StructRef: Sendable {
    case gc(id: YID, length: UInt64)
    case skip(id: YID, length: UInt64)
    case item(ItemRef)

    var length: UInt64 {
        switch self {
        case .gc(_, let length): length
        case .skip(_, let length): length
        case .item(let item): item.length
        }
    }
}

/// The structs contributed by one client, in clock-ascending order.
struct ClientBlock: Sendable {
    let client: UInt64
    let firstClock: UInt64
    let structs: [StructRef]
}

struct DeleteRange: Sendable {
    let clock: UInt64
    let length: UInt64
}

struct DeleteClient: Sendable {
    let client: UInt64
    let ranges: [DeleteRange]
}

struct DeleteSetData: Sendable {
    let clients: [DeleteClient]
}

/// A decoded v1 update: the structs section followed by the delete-set section.
struct ParsedUpdate: Sendable {
    let clientBlocks: [ClientBlock]
    let deleteSet: DeleteSetData
}
