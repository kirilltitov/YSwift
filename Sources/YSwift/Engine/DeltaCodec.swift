#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Wire shape of one Quill-style delta op (insert / retain / delete), as produced
/// by yjs `toDelta` (and by the native `toDeltaJSON`). Shared by both engines to
/// decode a delta JSON payload into `[Delta]`.
struct DeltaOpDTO: Decodable {
    let insert: YValue?
    let retain: Int?
    let delete: Int?
    let attributes: [String: YValue]?

    func toDelta() -> Delta? {
        if let insert { return .insert(insert, attributes: self.attributes) }
        if let retain { return .retain(retain, attributes: self.attributes) }
        if let delete { return .delete(delete) }
        return nil
    }
}

extension Array where Element == Delta {
    /// Decodes a yjs/native Quill-delta JSON payload into `[Delta]` (empty on failure).
    static func decodeDelta(from data: Data) -> [Delta] {
        (try? JSONDecoder().decode([DeltaOpDTO].self, from: data))?.compactMap { $0.toDelta() } ?? []
    }
}
