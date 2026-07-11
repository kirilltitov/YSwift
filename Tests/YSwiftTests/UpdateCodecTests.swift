import Testing

@testable import YSwift

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Pulls every update-bearing byte string out of the golden fixture.
private struct UpdateBearingFixtures: Decodable {
    struct Encode: Decodable {
        let name: String
        let update: String
    }
    struct Incremental: Decodable {
        let name: String
        let updates: [String]
    }
    struct Diff: Decodable {
        let name: String
        let base: String
        let full: String
        let diff: String
    }
    struct Merge: Decodable {
        let name: String
        let inputs: [String]
        let merged: String
    }
    struct Converge: Decodable {
        let name: String
        let updates: [String]
    }
    struct Semantic: Decodable {
        let name: String
        let update: String
    }

    let encode: [Encode]
    let incremental: [Incremental]
    let diff: [Diff]
    let merge: [Merge]
    let converge: [Converge]
    let semantic: [Semantic]

    /// (label, base64 update) for every update in the fixture.
    var allUpdates: [(String, String)] {
        var out: [(String, String)] = []
        for f in self.encode { out.append(("encode/\(f.name)", f.update)) }
        for f in self.incremental {
            for (i, u) in f.updates.enumerated() { out.append(("incremental/\(f.name)[\(i)]", u)) }
        }
        for f in self.diff {
            out.append(("diff/\(f.name).base", f.base))
            out.append(("diff/\(f.name).full", f.full))
            out.append(("diff/\(f.name).diff", f.diff))
        }
        for f in self.merge {
            for (i, u) in f.inputs.enumerated() { out.append(("merge/\(f.name).input[\(i)]", u)) }
            out.append(("merge/\(f.name).merged", f.merged))
        }
        for f in self.converge { for (i, u) in f.updates.enumerated() { out.append(("converge/\(f.name)[\(i)]", u)) } }
        for f in self.semantic { out.append(("semantic/\(f.name)", f.update)) }
        return out
    }
}

@Suite("native update codec (structural round-trip)")
struct NativeUpdateCodecTests {
    private static func fixtures() throws -> UpdateBearingFixtures {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(UpdateBearingFixtures.self, from: Data(contentsOf: url))
    }

    @Test("every yjs v13.6.31 update parses and re-encodes byte-identically")
    func roundTrip() throws {
        let updates = try Self.fixtures().allUpdates
        #expect(!updates.isEmpty)
        for (label, base64) in updates {
            let bytes = Array(try #require(Data(base64Encoded: base64), "\(label): bad base64"))
            let parsed = try UpdateCodec.readUpdate(bytes)
            let reencoded = UpdateCodec.writeUpdate(parsed)
            #expect(reencoded == bytes, "\(label): re-encode differs (\(bytes.count) bytes)")
        }
    }
}
