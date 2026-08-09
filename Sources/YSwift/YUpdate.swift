#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Document-less operations over encoded updates — compaction and diffing
/// without a resident document (requirements §4.3).
///
/// Implemented over the pure-Swift engine: a throwaway `NativeDoc` integrates the
/// input(s) and re-encodes. For complete updates this is byte-identical to yjs
/// `mergeUpdates` / `diffUpdate` (see the native encode round-trip tests).
public enum YUpdate {
    /// Validates one complete Yjs v1 update without integrating it into a document.
    /// Rejects malformed/trailing data, non-canonical integers and unsafe declared
    /// sizes before a backend decoder or document is touched.
    public static func validateV1(_ update: Data) throws {
        do {
            _ = try UpdateCodec.readUpdate(Array(update))
        } catch {
            throw YError.invalidUpdate
        }
    }

    /// Merges several updates into one, de-duplicating shared structure.
    public static func merge(_ updates: [Data]) -> Data {
        guard !updates.isEmpty else { return Data() }
        let doc = NativeDoc()
        for update in updates { try? doc.applyUpdate(Array(update)) }
        return Data(doc.encodeStateAsUpdate())
    }

    /// The portion of `update` a peer at state vector `sv` is missing.
    public static func diff(_ update: Data, since sv: StateVector) -> Data {
        let doc = NativeDoc()
        try? doc.applyUpdate(Array(update))
        let target = (try? NativeDoc.decodeStateVector(Array(sv.data))) ?? [:]
        return Data(doc.encodeStateAsUpdate(target: target))
    }
}
