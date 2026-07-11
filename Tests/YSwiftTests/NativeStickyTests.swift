import Foundation
import Testing

@testable import YSwift

// The `sticky` golden fixtures: build text, create a sticky index at (index, assoc),
// check its encoded bytes and resolved position, then shift the text and re-resolve.
private struct StickyFixtures: Decodable {
    struct Op: Decodable {
        let op: String
        let index: Int
        let text: String?
        let length: Int?
    }
    struct Case: Decodable {
        let name: String
        let clientID: UInt64
        let baseOps: [Op]
        let index: Int
        let assoc: Int
        let shiftOps: [Op]
        let encoded: String
        let resolvedBefore: Int
        let resolvedAfter: Int
        let finalText: String
    }
    let sticky: [Case]
}

@Suite("native sticky index (RelativePosition)")
struct NativeStickyTests {
    private func fixtures() throws -> [StickyFixtures.Case] {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(StickyFixtures.self, from: Data(contentsOf: url)).sticky
    }

    private func apply(_ ops: [StickyFixtures.Op], to text: NativeText) {
        for op in ops {
            switch op.op {
            case "insert": text.insert(op.index, op.text ?? "")
            case "delete": text.delete(op.index, op.length ?? 0)
            default: Issue.record("unexpected op \(op.op)")
            }
        }
    }

    @Test("sticky index encodes byte-exactly and tracks edits")
    func stickyIndex() throws {
        for fixture in try self.fixtures() {
            let doc = NativeDoc(clientID: fixture.clientID)
            let text = doc.text("text")
            self.apply(fixture.baseOps, to: text)

            let sticky = text.stickyIndex(at: fixture.index, assoc: Int64(fixture.assoc))
            let expectedBytes = Array(try #require(Data(base64Encoded: fixture.encoded), "\(fixture.name): base64"))
            #expect(sticky.encode() == expectedBytes, "\(fixture.name): encoded")

            // decode re-encodes to the same bytes (a created position also carries the
            // parent tname/type, which the wire omits when an item id is present, so
            // decode != created by fields — only by encoded form).
            #expect(
                try NativeRelativePosition.decode(expectedBytes).encode() == expectedBytes, "\(fixture.name): decode")

            let before = try #require(doc.resolve(sticky), "\(fixture.name): resolve before")
            #expect(before.index == fixture.resolvedBefore, "\(fixture.name): resolvedBefore")

            self.apply(fixture.shiftOps, to: text)
            let after = try #require(doc.resolve(sticky), "\(fixture.name): resolve after")
            #expect(after.index == fixture.resolvedAfter, "\(fixture.name): resolvedAfter")
            #expect(text.string == fixture.finalText, "\(fixture.name): finalText")
        }
    }
}
