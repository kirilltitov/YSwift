#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Document-less operations over encoded updates — compaction and diffing
/// without a resident document (requirements §4.3).
public enum YUpdate {
    /// Merges several updates into one, de-duplicating shared structure. The
    /// result is never larger than the concatenation.
    public static func merge(_ updates: [Data]) -> Data {
        fatalError("YSwift: YUpdate.merge is not implemented yet (Phase 1: yrs merge_updates_v1). See DECISIONS.md.")
    }

    /// The portion of `update` a peer at state vector `sv` is missing.
    public static func diff(_ update: Data, since sv: StateVector) -> Data {
        fatalError("YSwift: YUpdate.diff is not implemented yet (Phase 1: yrs diff_update_v1). See DECISIONS.md.")
    }
}
