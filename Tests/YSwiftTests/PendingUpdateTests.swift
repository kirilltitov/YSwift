import Foundation
import Testing

@testable import YSwift

@Suite("updates waiting for missing clocks")
struct PendingUpdateTests {
    private static func bytes(_ hex: String) -> Data {
        Data(
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
    }

    /// Four updates of the byte fuzzer (fuzzA/repros/text-length-desync.json) that resend runs from
    /// their middle across the roots `b` and `c`.
    private static let resentRuns = [
        "0101c1a6c78e0f27c4c1a6c78e0f02083805626769626100",
        "0115c1a6c78e0f000002c40807081b0162c4080e080f056a636161660001000100010001000100010001000100010004000100"
            + "0400050001000100010001c4081d082705696365646900",
        "01010836c4c1a6c78e0f02c1a6c78e0f0305626769626100",
        "01230800010101610181080001410800010002c1080408000204010162016284080701690002000104010163046768626a00010002"
            + "0001c10800080101810801010002c108170814010002c408070808016246080c0163052272656422c4081c080c016ac6081d08"
            + "0c0163046e756c6c00010001000100010001000100010001c4081d081e056963656469000100040001000400",
    ]

    @Test(
        "waiting structs merged as yjs merges them take the parent yjs gives them",
        arguments: [([0, 1, 2, 3], nil, 9, 24), ([3, 1, 0, 2], 2, 9, 20), ([3, 1, 2, 0], 0, 9, 20)]
            as [([Int], Int?, Int, Int)]
    )
    func mergesWaitingStructsAsYjs(order: [Int], rejected: Int?, lengthB: Int, lengthC: Int) throws {
        // Yjs 13.6.31 accepts every order and ends it with the same state. In order 0123 the waiting run is
        // sliced when it merges, and its rest takes the parent of its new origin, as here. In the other
        // orders a run resent from its middle follows a run of the other root, which yjs links in anyway,
        // ending with lengths 13 and 20 that no longer count the characters; YSwift rejects that update.
        let doc = YDoc(clientID: 999)
        var rejectedIndex: Int?
        for index in order {
            do {
                try doc.transact { try doc.applyUpdateChecked($0, Self.bytes(Self.resentRuns[index])) }
            } catch {
                rejectedIndex = index
            }
        }
        #expect(rejectedIndex == rejected)
        doc.transact { txn in
            #expect(doc.text("b").length(txn) == lengthB)
            #expect(doc.text("c").length(txn) == lengthC)
            #expect(doc.text("b").string(txn).utf16.count == lengthB)
            #expect(doc.text("c").string(txn).utf16.count == lengthC)
            #expect(doc.hasPendingUpdates(txn) == false)
        }
    }
}
