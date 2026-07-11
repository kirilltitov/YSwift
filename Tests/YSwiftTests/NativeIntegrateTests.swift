import Foundation
import Testing

@testable import YSwift

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
        let sinceStateVector: String
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

    @Test("multi-client state vector is byte-identical (clients descending)")
    func multiClientStateVector() throws {
        let fixtures = try Self.fixtures()
        // merged: two clients -> SV lists client 2 then client 1 (descending).
        let merged = NativeDoc()
        try merged.applyUpdate(self.bytes(fixtures.merge[0].merged))
        #expect(merged.encodeStateVector() == (try self.bytes("AgIFAQY=")), "merged SV")
        // converge: two clients applied in sequence.
        let converged = NativeDoc()
        for update in fixtures.converge[0].updates { try converged.applyUpdate(self.bytes(update)) }
        #expect(converged.encodeStateVector() == (try self.bytes("AgIDAQM=")), "converge SV")
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

    @Test("out-of-order updates buffer and converge (diff applied before its base)")
    func pendingBuffer() throws {
        for fixture in try Self.fixtures().diff {
            let base = try self.bytes(fixture.base)
            let diff = try self.bytes(fixture.diff)
            let name = try self.rootName(base) ?? "content"

            let doc = NativeDoc()
            // The diff depends on the base (its structs start after the base state);
            // applied first it must buffer, leaving the doc empty…
            try doc.applyUpdate(diff)
            #expect(doc.getText(name) == "", "\(fixture.name): diff must buffer before base")
            // …then the base arrives and the buffered diff auto-integrates.
            try doc.applyUpdate(base)
            #expect(doc.getText(name) == fixture.text, "\(fixture.name): converged after base")
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

@Suite("native encode (encodeStateAsUpdate)")
struct NativeEncodeTests {
    private func fixtures() throws -> EncodeFixtures {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(EncodeFixtures.self, from: Data(contentsOf: url))
    }

    private func bytes(_ base64: String) throws -> [UInt8] {
        Array(try #require(Data(base64Encoded: base64), "bad base64"))
    }

    @Test("re-encoding an applied golden update reproduces the exact bytes")
    func encodeRoundTrip() throws {
        for fixture in try self.fixtures().encode {
            let update = try self.bytes(fixture.update)
            let doc = NativeDoc()
            try doc.applyUpdate(update)
            #expect(doc.encodeStateAsUpdate() == update, "\(fixture.name): re-encode differs")
        }
    }

    @Test("a merged multi-client document re-encodes to the merged bytes")
    func mergeRoundTrip() throws {
        for fixture in try self.fixtures().merge {
            let merged = try self.bytes(fixture.merged)
            let doc = NativeDoc()
            try doc.applyUpdate(merged)
            #expect(doc.encodeStateAsUpdate() == merged, "\(fixture.name): merged re-encode differs")

            // Applying the inputs separately must yield the same encodable state.
            let fromInputs = NativeDoc()
            for input in fixture.inputs { try fromInputs.applyUpdate(self.bytes(input)) }
            #expect(fromInputs.encodeStateAsUpdate() == merged, "\(fixture.name): inputs re-encode differs")
        }
    }

    @Test("encoding since a state vector reproduces the golden diff")
    func diffEncode() throws {
        for fixture in try self.fixtures().diff {
            let doc = NativeDoc()
            try doc.applyUpdate(self.bytes(fixture.full))
            let target = try NativeDoc.decodeStateVector(self.bytes(fixture.sinceStateVector))
            #expect(doc.encodeStateAsUpdate(target: target) == (try self.bytes(fixture.diff)), "\(fixture.name): diff")
            #expect(doc.encodeStateAsUpdate() == (try self.bytes(fixture.full)), "\(fixture.name): full")
        }
    }
}
