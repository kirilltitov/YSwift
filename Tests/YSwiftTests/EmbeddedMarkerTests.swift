import Foundation
import Testing

@testable import YSwift

/// An embedded value written into a text root and read back out of it.
///
/// This is the seam a block boundary needs: a marker that is part of the text, carried by the same
/// update as the characters around it, surviving encode and decode byte for byte, and visible to
/// whoever materializes the root — without ever becoming characters an author can type over.
@Suite struct EmbeddedMarkerTests {
    private func marker(_ blockID: String) -> YValue { .object(["block": .string(blockID)]) }

    @Test func anEmbedIsOneUnitBetweenTheCharactersAroundIt() {
        let doc = YDoc()
        let text = doc.text("line")
        doc.transact { txn in
            text.insert(txn, at: 0, "AB")
            text.insertEmbed(txn, at: 1, self.marker("T_second"))
        }
        doc.transact { txn in
            #expect(text.length(txn) == 3)
            // The embed is not a character: the plain string keeps only what was typed.
            #expect(text.string(txn) == "AB")
            #expect(text.toDelta(txn) == [
                .insert(.string("A"), attributes: nil),
                .insert(.object(["block": .string("T_second")]), attributes: nil),
                .insert(.string("B"), attributes: nil),
            ])
        }
    }

    @Test func anEmbedCrossesTheUpdateCodecUnchanged() {
        let source = YDoc()
        let text = source.text("line")
        source.transact { txn in
            text.insert(txn, at: 0, "Alpha")
            text.insertEmbed(txn, at: 5, self.marker("T_beta"))
            text.insert(txn, at: 6, "Beta")
        }
        let update = source.transact { txn in source.encodeStateAsUpdate(txn, since: nil) }

        let replica = YDoc()
        replica.transact { txn in replica.applyUpdate(txn, update, origin: nil) }
        let replicated = replica.text("line")
        replica.transact { txn in
            #expect(replicated.string(txn) == "AlphaBeta")
            #expect(replicated.toDelta(txn) == [
                .insert(.string("Alpha"), attributes: nil),
                .insert(.object(["block": .string("T_beta")]), attributes: nil),
                .insert(.string("Beta"), attributes: nil),
            ])
        }
    }

    @Test func removingTheMarkerJoinsTheTextAroundIt() {
        let doc = YDoc()
        let text = doc.text("line")
        doc.transact { txn in
            text.insert(txn, at: 0, "AB")
            text.insertEmbed(txn, at: 1, self.marker("T_second"))
        }
        // Taking the boundary away is a delete of one unit; the characters never moved.
        doc.transact { txn in text.delete(txn, at: 1, length: 1) }
        doc.transact { txn in
            #expect(text.length(txn) == 2)
            #expect(text.string(txn) == "AB")
            #expect(text.toDelta(txn) == [.insert(.string("AB"), attributes: nil)])
        }
    }

    @Test func anEmbedCarriesTheFormattingInForceAtItsPosition() {
        let doc = YDoc()
        let text = doc.text("line")
        doc.transact { txn in
            text.insert(txn, at: 0, "AB", attributes: ["bold": .bool(true)])
            text.insertEmbed(txn, at: 1, self.marker("T_second"))
        }
        doc.transact { txn in
            #expect(text.toDelta(txn) == [
                .insert(.string("A"), attributes: ["bold": .bool(true)]),
                .insert(.object(["block": .string("T_second")]), attributes: ["bold": .bool(true)]),
                .insert(.string("B"), attributes: ["bold": .bool(true)]),
            ])
        }
    }
}
