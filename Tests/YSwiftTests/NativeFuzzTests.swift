import Foundation
import Testing

@testable import YSwift

// Recorded differential convergence fuzz (§10.3): seeded-random concurrent
// scenarios generated from yjs v13.6.31. The native engine must converge to yjs's
// recorded state regardless of the order the updates are applied in (each in its
// own transaction, which also exercises the out-of-order pending buffer).
private struct FuzzFixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let kind: String
        let updates: [String]
        let state: String
    }
    let fuzz: [Case]
}

@Suite("native differential fuzz (convergence)")
struct NativeFuzzTests {
    private func fixtures() throws -> [FuzzFixtures.Case] {
        let url = try #require(
            Bundle.module.url(forResource: "golden_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(FuzzFixtures.self, from: Data(contentsOf: url)).fuzz
    }

    /// Distinct application orders that must all converge.
    private func orders(_ updates: [[UInt8]]) -> [[[UInt8]]] {
        var result = [updates, updates.reversed()]
        if updates.count > 2 { result.append(Array(updates[1...]) + [updates[0]]) }  // rotate
        return result
    }

    @Test("random concurrent scenarios converge to yjs's state in any order")
    func convergence() throws {
        for fixture in try self.fixtures() {
            let updates = try fixture.updates.map { Array(try #require(Data(base64Encoded: $0))) }
            for order in self.orders(updates) {
                let doc = YDoc(engine: NativeEngine(clientID: 777, gc: true))
                for update in order {
                    doc.transact { txn in doc.applyUpdate(txn, Data(update)) }
                }
                switch fixture.kind {
                case "text":
                    let got = doc.transact { txn in doc.text("content").string(txn) }
                    #expect(got == fixture.state, "\(fixture.name): text")
                case "array":
                    let got = doc.transact { txn in doc.array("content").toArray(txn) }
                    let expected = try JSONDecoder().decode([YValue].self, from: Data(fixture.state.utf8))
                    #expect(got == expected, "\(fixture.name): array")
                case "map":
                    let got = doc.transact { txn in doc.map("content").toDictionary(txn) }
                    let expected = try JSONDecoder().decode([String: YValue].self, from: Data(fixture.state.utf8))
                    #expect(got == expected, "\(fixture.name): map")
                default:
                    Issue.record("unknown fuzz kind \(fixture.kind)")
                }
            }
        }
    }
}
