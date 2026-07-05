import CYrs
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Document-less operations over encoded updates — compaction and diffing
/// without a resident document (requirements §4.3).
public enum YUpdate {
    /// Merges several updates into one, de-duplicating shared structure.
    public static func merge(_ updates: [Data]) -> Data {
        if updates.isEmpty { return Data() }
        var concat: [UInt8] = []
        var lens: [Int] = []
        for u in updates {
            concat.append(contentsOf: u)
            lens.append(u.count)
        }
        var outLen = 0
        let ptr = concat.withUnsafeBufferPointer { c in
            lens.withUnsafeBufferPointer { l in
                ymerge_updates_v1(c.baseAddress, c.count, l.baseAddress, l.count, &outLen)
            }
        }
        return cyrsConsume(ptr, outLen)
    }

    /// The portion of `update` a peer at state vector `sv` is missing.
    public static func diff(_ update: Data, since sv: StateVector) -> Data {
        let u = Array(update)
        let s = Array(sv.data)
        var outLen = 0
        let ptr = u.withUnsafeBufferPointer { ub in
            s.withUnsafeBufferPointer { sb in
                ydiff_update_v1(ub.baseAddress, ub.count, sb.baseAddress, sb.count, &outLen)
            }
        }
        return cyrsConsume(ptr, outLen)
    }
}

/// Copies a `cyrs`-owned byte buffer into `Data` and frees it.
func cyrsConsume(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Data {
    guard let ptr else { return Data() }
    defer { ybytes_free(ptr, len) }
    return len > 0 ? Data(bytes: ptr, count: len) : Data()
}
