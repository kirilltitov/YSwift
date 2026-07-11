import Testing

@testable import YSwift

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Golden fixtures produced by yjs v13.6.31.
private struct EncodeFixtures: Decodable {
    struct Encode: Decodable {
        let name: String
        let text: String
        let stateVector: String
        let update: String
    }
    // Two clients insert concurrently; every application order must converge.
    struct Converge: Decodable {
        let name: String
        let updates: [String]
        let text: String
    }
    // Independent client updates that merge into one document.
    struct Merge: Decodable {
        let name: String
        let inputs: [String]
        let merged: String
        let text: String
    }
    // Incremental update (`diff`) layered atop a `base` state.
    struct Diff: Decodable {
        let name: String
        let base: String
        let full: String
        let diff: String
        let text: String
    }
    let encode: [Encode]
    let converge: [Converge]
    let merge: [Merge]
    let diff: [Diff]
}

@Suite("native integrate (YATA apply)")
struct NativeIntegrateTests {
    private static func fixtures() throws -> EncodeFixtures {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(EncodeFixtures.self, from: Data(contentsOf: url))
    }

    private func bytes(_ base64: String) throws -> [UInt8] {
        Array(try #require(Data(base64Encoded: base64), "bad base64"))
    }

    /// Finds the root type name referenced by an update (nil for an empty doc).
    private func rootName(_ bytes: [UInt8]) throws -> String? {
        let parsed = try UpdateCodec.readUpdate(bytes)
        for block in parsed.clientBlocks {
            for structRef in block.structs {
                if case .item(let item) = structRef, case .rootKey(let name)? = item.parent {
                    return name
                }
            }
        }
        return nil
    }

    /// Applies updates in order and returns the reconstructed root text.
    private func apply(_ updates: [[UInt8]]) throws -> String {
        let doc = NativeDoc()
        var name = "text"
        for update in updates {
            try doc.applyUpdate(update)
            if let discovered = try self.rootName(update) { name = discovered }
        }
        return doc.getText(name)
    }

    @Test("applying a golden update reconstructs the exact text")
    func text() throws {
        for fixture in try Self.fixtures().encode {
            let bytes = try self.bytes(fixture.update)
            #expect(try self.apply([bytes]) == fixture.text, "\(fixture.name): text mismatch")
        }
    }

    @Test("state vector after applying a golden update is byte-identical")
    func stateVector() throws {
        for fixture in try Self.fixtures().encode {
            let bytes = try self.bytes(fixture.update)
            let expected = try self.bytes(fixture.stateVector)
            let doc = NativeDoc()
            try doc.applyUpdate(bytes)
            #expect(doc.encodeStateVector() == expected, "\(fixture.name): state vector mismatch")
        }
    }

    @Test("concurrent inserts converge to the same text in any application order")
    func converge() throws {
        for fixture in try Self.fixtures().converge {
            let updates = try fixture.updates.map(self.bytes)
            #expect(try self.apply(updates) == fixture.text, "\(fixture.name): forward order")
            #expect(try self.apply(updates.reversed()) == fixture.text, "\(fixture.name): reverse order")
        }
    }

    @Test("independent client updates merge to the expected text")
    func merge() throws {
        for fixture in try Self.fixtures().merge {
            let inputs = try fixture.inputs.map(self.bytes)
            #expect(try self.apply(inputs) == fixture.text, "\(fixture.name): sequential inputs")
            #expect(try self.apply(inputs.reversed()) == fixture.text, "\(fixture.name): reversed inputs")
            #expect(try self.apply([self.bytes(fixture.merged)]) == fixture.text, "\(fixture.name): merged update")
        }
    }

    @Test("an incremental diff applied atop a base equals the full state")
    func diff() throws {
        for fixture in try Self.fixtures().diff {
            let base = try self.bytes(fixture.base)
            let diff = try self.bytes(fixture.diff)
            let full = try self.bytes(fixture.full)
            #expect(try self.apply([base, diff]) == fixture.text, "\(fixture.name): base + diff")
            #expect(try self.apply([full]) == fixture.text, "\(fixture.name): full")
            // Applying the diff twice must be idempotent (offset skips the overlap).
            #expect(try self.apply([base, diff, diff]) == fixture.text, "\(fixture.name): diff idempotent")
        }
    }
}
