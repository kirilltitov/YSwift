import Testing
import Synchronization
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
@testable import YSwift

/// Verifies the frozen public API compiles and its value-type layer behaves.
/// Engine-backed operations trap in the scaffold and are covered once `YrsEngine`
/// lands in Phase 1.
@Suite("Public API contract")
struct PublicAPIContractTests {

    @Test("YDoc constructs and exposes a 53-bit client id")
    func docConstruction() {
        let doc = YDoc()
        #expect(doc.clientID < (UInt64(1) << 53))

        let noGC = YDoc(gc: false)
        #expect(noGC.clientID < (UInt64(1) << 53))
    }

    @Test("Text handles are obtainable and stable by name")
    func textHandles() {
        let doc = YDoc()
        #expect(doc.text("content").handle == doc.text("content").handle)
        #expect(doc.text("content").handle != doc.text("title").handle)
    }

    @Test("An empty transaction opens and closes")
    func emptyTransaction() {
        let doc = YDoc()
        let ran = doc.transact { _ in true }
        #expect(ran)
    }

    @Test("Throwing transaction propagates errors")
    func throwingTransaction() {
        struct Boom: Error {}
        let doc = YDoc()
        #expect(throws: Boom.self) {
            try doc.transact { _ in throw Boom() }
        }
    }

    @Test("YValue literals build the expected structure")
    func yValueLiterals() {
        let v: YValue = ["bold": true, "size": 12, "name": "x", "n": .null]
        #expect(v == .object([
            "bold": .bool(true),
            "size": .int(12),
            "name": .string("x"),
            "n": .null,
        ]))
    }

    @Test("Origin is a Sendable value type usable in a Set")
    func origins() {
        let tracked: Set<Origin> = ["local", "editor"]
        #expect(tracked.contains("local"))
        #expect(!tracked.contains("remote"))
    }

    @Test("StateVector wraps its bytes")
    func stateVectorWrapper() {
        let sv = StateVector(data: Data([1, 2, 3]))
        #expect(sv.data == Data([1, 2, 3]))
    }

    @Test("Deltas are equatable and hold attributes")
    func deltas() {
        let ops: [Delta] = [
            .retain(5, attributes: nil),
            .insert(.string("hi"), attributes: ["bold": true]),
            .delete(2),
        ]
        #expect(ops.count == 3)
        #expect(ops[1] == .insert(.string("hi"), attributes: ["bold": true]))
    }

    @Test("StickyIndex round-trips through its encoded form")
    func stickyIndexCodec() {
        let encoded = Data([9, 9])
        #expect(StickyIndex.decode(encoded).encode() == encoded)
    }

    @Test("A subscription cancels exactly once")
    func subscriptionCancellation() {
        let counter = Mutex(0)
        let sub = YSubscription { counter.withLock { $0 += 1 } }
        sub.cancel()
        sub.cancel()
        #expect(counter.withLock { $0 } == 1)
    }
}
