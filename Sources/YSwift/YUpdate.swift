#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Document-less operations over encoded updates — compaction and diffing
/// without a resident document (requirements §4.3).
///
/// Implemented over the pure-Swift engine: a throwaway `NativeDoc` integrates the
/// input(s) and re-encodes. It accepts causally complete inputs only; unlike the
/// general Yjs wire utilities, it cannot merge or diff unresolved partial updates.
public enum YUpdate {
    /// Structurally validates one complete Yjs v1 update without integrating it.
    ///
    /// Rejects trailing data, non-canonical or overflowing integers, invalid
    /// UTF-8/JSON, unsafe declared sizes and invalid control values. Dynamic
    /// objects are checked recursively for duplicate keys and `__proto__`.
    /// Success does not validate causal references against a document or prove
    /// that the update can be integrated into a particular document state.
    public static func validateV1(_ update: Data) throws {
        do {
            _ = try UpdateCodec.readUpdate(Array(update))
        } catch {
            throw YError.invalidUpdate
        }
    }

    /// Compacts a causally complete set of updates. Partial updates require their baseline:
    /// this implementation deliberately throws instead of silently discarding unresolved items
    /// or deletions. Callers that own a document should encode its delta at the previous frontier.
    public static func merge(_ updates: [Data]) throws -> Data {
        let document = NativeDoc()
        do {
            for update in updates {
                try document.applyUpdate(Array(update))
            }
        } catch {
            throw YError.invalidUpdate
        }
        guard !document.hasPendingUpdates else {
            throw YError.causalDependenciesMissing
        }
        return Data(document.encodeStateAsUpdate())
    }

    /// The portion of a causally complete update missing from the supplied state vector.
    /// Partial updates are rejected because encoding an unresolved document loses their content.
    public static func diff(_ update: Data, since sv: StateVector) throws -> Data {
        let document = NativeDoc()
        let target: [UInt64: UInt64]
        do {
            try document.applyUpdate(Array(update))
            target = try NativeDoc.decodeStateVector(Array(sv.data))
        } catch {
            throw YError.invalidUpdate
        }
        guard !document.hasPendingUpdates else {
            throw YError.causalDependenciesMissing
        }
        return Data(document.encodeStateAsUpdate(target: target))
    }
}
