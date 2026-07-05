#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A position that survives concurrent edits (Yjs relative position / cursor,
/// requirements §4.4).
///
/// Its encoding is byte-compatible with Yjs `encodeRelativePosition`.
public struct StickyIndex: Sendable, Hashable {
    /// Which side of the index the position associates with.
    public enum Assoc: Sendable, Hashable {
        /// Associates with the character after the index (Yjs `assoc >= 0`).
        case after
        /// Associates with the character before the index (Yjs `assoc < 0`).
        case before
    }

    /// Opaque, wire-compatible encoded form.
    let raw: Data

    init(raw: Data) { self.raw = raw }

    /// Creates a sticky position for `index` within `text`.
    public static func fromIndex(_ txn: YTransaction, _ text: YText, _ index: Int, assoc: Assoc = .after) -> StickyIndex {
        fatalError("YSwift: StickyIndex.fromIndex is not implemented yet (Phase 1: yrs StickyIndex). See DECISIONS.md.")
    }

    /// Resolves this sticky position to an absolute index in `doc`.
    public func toIndex(_ txn: YTransaction, _ doc: YDoc) -> Int {
        fatalError("YSwift: StickyIndex.toIndex is not implemented yet. See DECISIONS.md.")
    }

    /// The wire-compatible encoded form.
    public func encode() -> Data { raw }

    /// Reconstructs a sticky position from its encoded form.
    public static func decode(_ data: Data) -> StickyIndex { StickyIndex(raw: data) }
}
