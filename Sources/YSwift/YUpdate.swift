#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Document-less operations over encoded updates — compaction and diffing
/// without a resident document (requirements §4.3).
///
/// Implemented over the pure-Swift engine: a throwaway `NativeDoc` integrates the
/// input(s) and re-encodes. For valid complete updates this is byte-identical to
/// yjs `mergeUpdates` / `diffUpdate` (see the native encode round-trip tests).
public enum YUpdate {
    /// Structurally validates one complete Yjs v1 update without integrating it.
    ///
    /// Rejects trailing data, non-canonical or overflowing integers, invalid
    /// UTF-8/JSON, unsafe declared sizes and invalid control values. Dynamic
    /// objects are checked recursively for duplicate keys and `__proto__`.
    /// Success does not validate causal references against a document and does
    /// not guarantee that every backend can materialise every legal wire value.
    /// For example, escaped unpaired UTF-16 surrogates pass this structural
    /// check and round-trip through `NativeEngine`, while `YrsEngine` rejects
    /// them during application because Rust strings cannot represent them.
    public static func validateV1(_ update: Data) throws {
        do {
            _ = try UpdateCodec.readUpdate(Array(update))
        } catch {
            throw YError.invalidUpdate
        }
    }

    /// Merges several updates into one, de-duplicating shared structure.
    ///
    /// Inputs are assumed to be trusted complete updates. This compatibility API
    /// does not report malformed inputs; validate untrusted bytes with
    /// `validateV1(_:)` first.
    public static func merge(_ updates: [Data]) -> Data {
        guard !updates.isEmpty else { return Data() }
        let doc = NativeDoc()
        for update in updates { try? doc.applyUpdate(Array(update)) }
        return Data(doc.encodeStateAsUpdate())
    }

    /// The portion of `update` a peer at state vector `sv` is missing.
    ///
    /// Both inputs are assumed valid. This compatibility API does not report
    /// malformed input; validate untrusted update bytes before calling it.
    public static func diff(_ update: Data, since sv: StateVector) -> Data {
        let doc = NativeDoc()
        try? doc.applyUpdate(Array(update))
        let target = (try? NativeDoc.decodeStateVector(Array(sv.data))) ?? [:]
        return Data(doc.encodeStateAsUpdate(target: target))
    }
}
