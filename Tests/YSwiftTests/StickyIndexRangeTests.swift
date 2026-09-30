import Foundation
import Testing

@testable import YSwift

@Suite("sticky index outside the text")
struct StickyIndexRangeTests {
    private static func hex(_ index: StickyIndex) -> String {
        index.encode().map { String(format: "%02x", $0) }.joined()
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
}
