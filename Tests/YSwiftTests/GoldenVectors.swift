import Testing
import Foundation
import Synchronization
@testable import YSwift

// MARK: - Fixture model (mirrors fixtures/generate.mjs output)

struct GoldenSuite: Codable {
    struct Meta: Codable {
        let yjsVersion: String
        let format: String
        let key: String
        let generatedBy: String
    }

    struct EncodeFixture: Codable {
        let name: String
        let description: String
        let clientID: UInt64
        let ops: [GoldenOp]
        let text: String
        let deltaJSON: String
        let stateVector: String
        let update: String
    }

    struct MergeFixture: Codable {
        let name: String
        let description: String
        let inputs: [String]
        let merged: String
        let text: String
    }

    struct ConvergeFixture: Codable {
        let name: String
        let description: String
        let updates: [String]
        let text: String
    }

    struct DiffFixture: Codable {
        let name: String
        let description: String
        let clientID: UInt64
        let sinceStateVector: String
        let full: String
        let diff: String
        let text: String
    }

    struct IncrementalFixture: Codable {
        let name: String
        let description: String
        let clientID: UInt64
        let transactions: [[GoldenOp]]
        let updates: [String]
        let text: String
    }

    let meta: Meta
    let encode: [EncodeFixture]
    let merge: [MergeFixture]
    let converge: [ConvergeFixture]
    let diff: [DiffFixture]
    let incremental: [IncrementalFixture]
}

struct GoldenOp: Codable {
    let op: String
    let index: Int?
    let text: String?
    let length: Int?
    let attributes: [String: GoldenScalar]?
}

/// The scalar JSON values Yjs formatting attributes use.
enum GoldenScalar: Codable, Equatable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    var asYValue: YValue {
        switch self {
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .null: .null
        }
    }
}

// MARK: - Loading

enum Golden {
    static func loadSuite() throws -> GoldenSuite {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures"),
            "golden fixture bundle resource is missing"
        )
        return try JSONDecoder().decode(GoldenSuite.self, from: Data(contentsOf: url))
    }

    static func attributes(_ raw: [String: GoldenScalar]?) -> Attributes? {
        raw.map { $0.mapValues(\.asYValue) }
    }

    /// Replays a fixture's structured ops against a text type, mirroring the JS generator.
    static func replay(_ ops: [GoldenOp], into text: YText, _ txn: YTransaction) {
        for o in ops {
            switch o.op {
            case "insert": text.insert(txn, at: o.index!, o.text!, attributes: attributes(o.attributes))
            case "delete": text.delete(txn, at: o.index!, length: o.length!)
            case "format": text.format(txn, at: o.index!, length: o.length!, attributes: attributes(o.attributes) ?? [:])
            default: Issue.record("unknown op: \(o.op)")
            }
        }
    }

    /// Parses a Yjs `toDelta` JSON string into `[Delta]` (insert ops only).
    static func parseDelta(_ json: String) throws -> [Delta] {
        struct Op: Decodable { let insert: YValue?; let attributes: [String: YValue]? }
        let ops = try JSONDecoder().decode([Op].self, from: Data(json.utf8))
        return ops.compactMap { op in op.insert.map { .insert($0, attributes: op.attributes) } }
    }
}

// MARK: - Tests

@Suite("Golden vectors (yjs v13.6.31)")
struct GoldenVectorTests {

    @Test("fixtures load, decode, and carry valid base64 payloads")
    func fixturesLoadAndDecode() throws {
        let suite = try Golden.loadSuite()
        #expect(suite.meta.yjsVersion == "13.6.31")
        #expect(suite.meta.format == "v1")
        #expect(!suite.encode.isEmpty)

        for f in suite.encode {
            #expect(Data(base64Encoded: f.update) != nil, "\(f.name): update is not valid base64")
            #expect(Data(base64Encoded: f.stateVector) != nil, "\(f.name): state vector is not valid base64")
        }
        for f in suite.merge { #expect(Data(base64Encoded: f.merged) != nil, "\(f.name)") }
        for f in suite.converge { #expect(f.updates.allSatisfy { Data(base64Encoded: $0) != nil }) }
        for f in suite.diff { #expect(Data(base64Encoded: f.diff) != nil, "\(f.name)") }
    }

    // The conformance tests below are the project's core acceptance criterion:
    // for the same operations the port must emit byte-identical bytes, and it
    // must reconstruct the same text from the reference updates. They are enabled
    // once a real engine (Phase 1: YrsEngine) is wired; the stub engine traps.

    @Test("golden-encode: replaying ops yields byte-identical update + state vector")
    func goldenEncode() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode {
            let doc = YDoc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            doc.transact { txn in Golden.replay(f.ops, into: text, txn) }

            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == f.update, "\(f.name): update bytes differ")
                #expect(doc.encodeStateVector(txn).data.base64EncodedString() == f.stateVector, "\(f.name): state vector bytes differ")
                #expect(text.string(txn) == f.text, "\(f.name): text differs")
            }
        }
    }

    @Test("golden-decode: applying reference updates reconstructs the text")
    func goldenDecode() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode {
            let update = try #require(Data(base64Encoded: f.update))
            let doc = YDoc(clientID: 9)
            doc.transact { txn in doc.applyUpdate(txn, update) }
            let string = doc.transact { txn in doc.text(suite.meta.key).string(txn) }
            #expect(string == f.text, "\(f.name): reconstructed text differs")
        }
    }

    @Test("convergence: applying updates in any order yields the same text")
    func convergence() throws {
        let suite = try Golden.loadSuite()
        for f in suite.converge {
            let updates = try f.updates.map { try #require(Data(base64Encoded: $0)) }
            func apply(_ order: [Data]) -> String {
                let doc = YDoc(clientID: 9)
                doc.transact { txn in for u in order { doc.applyUpdate(txn, u) } }
                return doc.transact { txn in doc.text(suite.meta.key).string(txn) }
            }
            #expect(apply(updates) == f.text, "\(f.name): forward order differs")
            #expect(apply(updates.reversed()) == f.text, "\(f.name): reverse order differs")
        }
    }

    @Test("onUpdate emits byte-identical incremental updates in order")
    func onUpdateIncremental() throws {
        let suite = try Golden.loadSuite()
        for f in suite.incremental {
            let doc = YDoc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            let captured = Mutex<[String]>([])
            let sub = doc.onUpdate { update, _ in
                captured.withLock { $0.append(update.base64EncodedString()) }
            }
            for txnOps in f.transactions {
                doc.transact { txn in Golden.replay(txnOps, into: text, txn) }
            }
            sub.cancel()
            #expect(captured.withLock { $0 } == f.updates, "\(f.name): incremental updates differ")
            #expect(doc.transact { txn in text.string(txn) } == f.text, "\(f.name): final text differs")
        }
    }

    @Test("transaction origin round-trips to the update observer")
    func originRoundTrip() {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        let seen = Mutex<[String?]>([])
        let sub = doc.onUpdate { _, origin in seen.withLock { $0.append(origin?.rawValue) } }
        doc.transact(origin: "local") { txn in text.insert(txn, at: 0, "a") }
        doc.transact { txn in text.insert(txn, at: 1, "b") }
        sub.cancel()
        #expect(seen.withLock { $0 } == ["local", nil])
    }

    @Test("toDelta matches yjs toDelta structurally")
    func toDeltaConformance() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode where !f.ops.isEmpty {
            let doc = YDoc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            doc.transact { txn in Golden.replay(f.ops, into: text, txn) }
            let mine = doc.transact { txn in text.toDelta(txn) }
            let expected = try Golden.parseDelta(f.deltaJSON)
            #expect(mine == expected, "\(f.name): toDelta differs\n  mine=\(mine)\n  exp=\(expected)")
        }
    }
}
