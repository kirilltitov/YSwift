import Foundation
import Testing

@testable import YSwift

// Golden fixtures for the container types (Y.Array / Y.Map), an extension beyond
// the §4 text subset. Verified through the public API on the native engine.
private struct ContainerFixtures: Decodable {
    struct ArrayOp: Decodable {
        let op: String
        let index: Int
        let values: [YValue]?
        let length: Int?
    }
    struct ArrayCase: Decodable {
        let name: String
        let clientID: UInt64
        let ops: [ArrayOp]
        let json: String
        let stateVector: String
        let update: String
    }
    struct MapOp: Decodable {
        let op: String
        let key: String
        let value: YValue?
    }
    struct MapCase: Decodable {
        let name: String
        let clientID: UInt64
        let ops: [MapOp]
        let json: String
        let stateVector: String
        let update: String
    }
    struct XmlSpec: Decodable {
        let text: String?
        let tag: String?
        let attrs: [[YValue]]?
        let children: [XmlSpec]?

        var node: YXmlNode {
            if let text { return .text(text) }
            var attributes: [String: YValue] = [:]
            for pair in self.attrs ?? [] where pair.count == 2 {
                if case .string(let key) = pair[0] { attributes[key] = pair[1] }
            }
            return .element(tag: self.tag ?? "", attributes: attributes, children: (self.children ?? []).map(\.node))
        }
    }
    struct XmlCase: Decodable {
        let name: String
        let clientID: UInt64
        let nodes: [XmlSpec]
        let xml: String
        let stateVector: String
        let update: String
    }
    struct ConvergeCase: Decodable {
        let name: String
        let kind: String
        let updates: [String]
        let json: String
    }
    let array: [ArrayCase]
    let map: [MapCase]
    let xml: [XmlCase]
    let containerConverge: [ConvergeCase]
}

@Suite("native containers (Y.Array / Y.Map / Y.Xml)")
struct NativeContainerTests {
    private func fixtures() throws -> ContainerFixtures {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(ContainerFixtures.self, from: Data(contentsOf: url))
    }

    /// Containers are a native-engine-only feature, so build the doc on the native
    /// engine explicitly (independent of the YSWIFT_ENGINE default) — YrsEngine
    /// traps on container calls.
    private func doc(clientID: UInt64) -> YDoc {
        YDoc(engine: NativeEngine(clientID: clientID, gc: true))
    }

    private func values(fromJSON json: String) throws -> [YValue] {
        try JSONDecoder().decode([YValue].self, from: Data(json.utf8))
    }

    @Test("array ops reproduce byte-exact update + state vector and materialise")
    func arrayConformance() throws {
        for fixture in try self.fixtures().array {
            let doc = self.doc(clientID: fixture.clientID)
            let array = doc.array("content")
            doc.transact { txn in
                for op in fixture.ops {
                    switch op.op {
                    case "insert": array.insert(txn, at: op.index, op.values ?? [])
                    case "delete": array.delete(txn, at: op.index, count: op.length ?? 0)
                    default: Issue.record("unknown array op \(op.op)")
                    }
                }
            }
            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == fixture.update, "\(fixture.name): update")
                #expect(
                    doc.encodeStateVector(txn).data.base64EncodedString() == fixture.stateVector,
                    "\(fixture.name): state vector")
            }
            let got = doc.transact { txn in array.toArray(txn) }
            #expect(got == (try self.values(fromJSON: fixture.json)), "\(fixture.name): toArray")
        }
    }

    @Test("map ops reproduce byte-exact update + state vector and materialise")
    func mapConformance() throws {
        for fixture in try self.fixtures().map {
            let doc = self.doc(clientID: fixture.clientID)
            let map = doc.map("content")
            doc.transact { txn in
                for op in fixture.ops {
                    switch op.op {
                    case "set": map.set(txn, op.key, op.value ?? .null)
                    case "delete": map.remove(txn, op.key)
                    default: Issue.record("unknown map op \(op.op)")
                    }
                }
            }
            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == fixture.update, "\(fixture.name): update")
                #expect(
                    doc.encodeStateVector(txn).data.base64EncodedString() == fixture.stateVector,
                    "\(fixture.name): state vector")
            }
            let got = doc.transact { txn in map.toDictionary(txn) }
            let expected = try JSONDecoder().decode([String: YValue].self, from: Data(fixture.json.utf8))
            #expect(got == expected, "\(fixture.name): toDictionary")
        }
    }

    @Test("xml ops reproduce byte-exact update + state vector and serialise")
    func xmlConformance() throws {
        for fixture in try self.fixtures().xml {
            let doc = self.doc(clientID: fixture.clientID)
            let fragment = doc.xmlFragment("content")
            doc.transact { txn in fragment.insert(txn, at: 0, fixture.nodes.map(\.node)) }
            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == fixture.update, "\(fixture.name): update")
                #expect(
                    doc.encodeStateVector(txn).data.base64EncodedString() == fixture.stateVector,
                    "\(fixture.name): state vector")
                #expect(fragment.toString(txn) == fixture.xml, "\(fixture.name): toString")
            }
        }
    }

    @Test("concurrent container edits converge in any order and match yjs")
    func containerConvergence() throws {
        for fixture in try self.fixtures().containerConverge {
            let updates = try fixture.updates.map { Array(try #require(Data(base64Encoded: $0))) }
            for order in [updates, updates.reversed()] {
                let doc = self.doc(clientID: 999)
                doc.transact { txn in for update in order { doc.applyUpdate(txn, Data(update)) } }
                switch fixture.kind {
                case "array":
                    let got = doc.transact { txn in doc.array("content").toArray(txn) }
                    #expect(got == (try self.values(fromJSON: fixture.json)), "\(fixture.name): array converge")
                case "map":
                    let got = doc.transact { txn in doc.map("content").toDictionary(txn) }
                    let expected = try JSONDecoder().decode([String: YValue].self, from: Data(fixture.json.utf8))
                    #expect(got == expected, "\(fixture.name): map converge")
                default:
                    Issue.record("unknown converge kind \(fixture.kind)")
                }
            }
        }
    }
}
