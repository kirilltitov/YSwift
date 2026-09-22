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

    /// Creates a sticky position for `index` within `text`.
    public static func fromIndex(_ txn: YTransaction, _ text: YText, _ index: Int, assoc: Assoc = .after) -> StickyIndex
    {
        StickyIndex(raw: txn.engine.stickyFromIndex(in: txn, text.handle, index: index, assoc: assoc) ?? Data())
    }

    /// Resolves this sticky position to an absolute index in `doc` (-1 if it
    /// can no longer be referenced).
    public func toIndex(_ txn: YTransaction, _ doc: YDoc) -> Int {
        txn.engine.stickyToIndex(in: txn, self.raw) ?? -1
    }

    /// Resolves only inside the expected text root, using UTF-16 coordinates.
    /// Returns nil for another root or transaction owner, unavailable item identities, or
    /// noncanonical encoded positions. An expected association checks the encoded anchor directly,
    /// including when its referenced item was deleted. Positions remain portable between replicas.
    public func toIndex(_ txn: YTransaction, in expectedText: YText, assoc: Assoc? = nil) -> Int? {
        guard txn.engine === expectedText.doc.engine else {
            return nil
        }
        return txn.engine.stickyToIndex(in: txn, self.raw, expectedRoot: expectedText.handle, expectedAssoc: assoc)
    }

    /// The wire-compatible encoded form.
    public func encode() -> Data { self.raw }

    /// Reconstructs a sticky position from its encoded form.
    public static func decode(_ data: Data) -> StickyIndex { StickyIndex(raw: data) }
}
