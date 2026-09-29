import Foundation
import Testing

@testable import YSwift

// Yjs deletes and collects nested types recursively, and browsers run out of stack from 734 levels on.
// A remote update may build and delete `NativeStore.remoteNestingLimit` levels; the malformed golden
// vectors pin the building side, these tests the deletion of a document built deeper than that.
extension CheckedUpdateTests {
    /// `depth` maps of client 5, each the entry `a` of the one before, the first in root `content`.
    private static func nestedMaps(_ depth: Int) -> Data {
        var bytes: [UInt8] = [1] + Self.varUint(UInt64(depth)) + [5, 0]
        for level in 0..<depth {
            bytes += [0x27] + (level == 0 ? [1] + Self.varString("content") : [0, 5] + Self.varUint(UInt64(level - 1)))
            bytes += Self.varString("a") + [1]
        }
        return Data(bytes + [0])
    }

    /// Deletes the outermost map, or replaces it with a number set by client 6.
    private static func removal(replacing: Bool) -> Data {
        replacing
            ? Data([1, 1, 6, 0, 0x28, 1] + Self.varString("content") + Self.varString("a") + [1, 125, 1, 0])
            : Data([0, 1, 5, 1, 0, 1])
    }

    @Test(
        "a remote deletion of nesting deeper than browsers can delete is rejected",
        arguments: [false, true]
    )
    func rejectsDeletionsPastTheNestingLimit(replacing: Bool) throws {
        let limit = NativeStore.remoteNestingLimit
        for depth in [limit, limit + 1] {
            // Built with the limit lifted, as local edits may build it.
            let doc = YDoc(clientID: 999)
            let store = try #require((doc.engine as? NativeEngine)?.doc.store)
            store.nestingLimit = .max
            try doc.transact { try doc.applyUpdateChecked($0, Self.nestedMaps(depth)) }
            store.nestingLimit = limit
            let removal = Self.removal(replacing: replacing)
            if depth > limit {
                #expect(throws: YError.invalidUpdate) { try doc.transact { try doc.applyUpdateChecked($0, removal) } }
            } else {
                try doc.transact { try doc.applyUpdateChecked($0, removal) }
            }
        }
    }
}
