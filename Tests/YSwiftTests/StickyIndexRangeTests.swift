import Foundation
import Testing

@testable import YSwift

@Suite("sticky index outside the text")
struct StickyIndexRangeTests {
    private static func hex(_ index: StickyIndex) -> String {
        index.encode().map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ hex: String) -> Data {
        Data(
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
    }

    @Test("an index before the start is the start and one past the end is the end")
    func clampsTheIndex() {
        let doc = YDoc(clientID: 7777)
        let text = doc.text("t")
        doc.transact { text.insert($0, at: 0, "abc") }
        doc.transact { txn in
            // Yjs 13.6.31: 00e13c0000 at 0 (after), 01017441 at 0 (before), 01017400 past the end. For a
            // negative index it encodes an id before the item, which no document resolves.
            for index in [-1, -5, Int.min, 0] {
                #expect(Self.hex(StickyIndex.fromIndex(txn, text, index, assoc: .after)) == "00e13c0000")
                #expect(Self.hex(StickyIndex.fromIndex(txn, text, index, assoc: .before)) == "01017441")
            }
            for index in [3, 9, Int.max] {
                #expect(Self.hex(StickyIndex.fromIndex(txn, text, index, assoc: .after)) == "01017400")
                #expect(Self.hex(StickyIndex.fromIndex(txn, text, index, assoc: .before)) == "00e13c0241")
            }
        }
    }

    @Test("a text whose length an update drove below zero takes any index")
    func takesTheNegativeLength() throws {
        // An item resent from its middle joins its left neighbour's run in another root, as in yjs: the
        // state below is the one yjs 13.6.31 ends with, and so is the length.
        let doc = YDoc(clientID: 7777)
        let updates = [
            "0101010004010162017800", "01010200040101630361616100", "01010202840100047a7a7a7a00", "000102010006",
        ]
        for update in updates {
            try doc.transact { try doc.applyUpdateChecked($0, Self.bytes(update)) }
        }
        let text = doc.text("c")
        doc.transact { text.insert($0, at: 0, "k") }
        doc.transact { txn in
            #expect(text.length(txn) == -2)
            let yjsState = "0301e13c00840205016b01020001010163060101000401016201780102010006"
            #expect(doc.encodeStateAsUpdate(txn) == Self.bytes(yjsState))
            let start = StickyIndex.fromIndex(txn, text, 0)
            #expect(Self.hex(start) == "00e13c0000")
            #expect(StickyIndex.fromIndex(txn, text, text.length(txn)) == start)
        }
    }
}
