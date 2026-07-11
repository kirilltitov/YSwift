import Foundation
import Testing

@testable import YSwift

// Replays the golden `encode` fixtures' op lists through native YText and checks
// the result against yjs v13.6.31: final text, Quill delta, and the byte-exact
// update + state vector.
private struct TextFixtures: Decodable {
    struct Op: Decodable {
        let op: String
        let index: Int
        let text: String?
        let length: Int?
        let attributes: [String: AttrValue]?
    }
    struct Encode: Decodable {
        let name: String
        let clientID: UInt64
        let ops: [Op]
        let text: String
        let deltaJSON: String
        let stateVector: String
        let update: String
    }
    let encode: [Encode]
}

// A JSON attribute value limited to what the fixtures use.
private enum AttrValue: Decodable {
    case bool(Bool)
    case string(String)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var lib0: Lib0Any {
        switch self {
        case .bool(let value): .bool(value)
        case .string(let value): .string(value)
        case .number(let value): .number(value)
        case .null: .null
        }
    }
}

@Suite("native text (local ops)")
struct NativeTextTests {
    private func fixtures() throws -> [TextFixtures.Encode] {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(TextFixtures.self, from: Data(contentsOf: url)).encode
    }

    private func bytes(_ base64: String) throws -> [UInt8] {
        Array(try #require(Data(base64Encoded: base64), "bad base64"))
    }

    /// Root type name yjs used, recovered from the golden update ("text" if empty).
    private func rootName(_ update: [UInt8]) throws -> String {
        let parsed = try UpdateCodec.readUpdate(update)
        for block in parsed.clientBlocks {
            for structRef in block.structs {
                if case .item(let item) = structRef, case .rootKey(let name)? = item.parent { return name }
            }
        }
        return "text"
    }

    private func replay(_ fixture: TextFixtures.Encode, into text: NativeText) {
        for op in fixture.ops {
            let attributes = op.attributes?.mapValues(\.lib0)
            switch op.op {
            case "insert": text.insert(op.index, op.text ?? "", attributes: attributes)
            case "delete": text.delete(op.index, op.length ?? 0)
            case "format": text.format(op.index, op.length ?? 0, attributes: attributes ?? [:])
            default: Issue.record("unknown op \(op.op)")
            }
        }
    }

    @Test("replaying the ops reproduces the text and the Quill delta")
    func textAndDelta() throws {
        for fixture in try self.fixtures() {
            let doc = NativeDoc(clientID: fixture.clientID)
            let text = doc.text(try self.rootName(self.bytes(fixture.update)))
            self.replay(fixture, into: text)
            #expect(text.string == fixture.text, "\(fixture.name): text")
            #expect(text.toDeltaJSON() == fixture.deltaJSON, "\(fixture.name): delta")
        }
    }

    @Test("replaying the ops produces the byte-exact update and state vector")
    func updateAndStateVector() throws {
        for fixture in try self.fixtures() {
            let doc = NativeDoc(clientID: fixture.clientID)
            let text = doc.text(try self.rootName(self.bytes(fixture.update)))
            self.replay(fixture, into: text)
            #expect(doc.encodeStateAsUpdate() == (try self.bytes(fixture.update)), "\(fixture.name): update")
            #expect(doc.encodeStateVector() == (try self.bytes(fixture.stateVector)), "\(fixture.name): state vector")
        }
    }
}
