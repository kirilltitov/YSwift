import Foundation
import Testing

@testable import YSwift

@Suite("Sticky index binds its resolved text root")
struct StickyIndexRootBindingTests {
    @Test("an item position and an empty-root position reject another root")
    func rejectsForeignRoots() {
        let doc = YDoc(clientID: 81, gc: false)
        let source = doc.text("source")
        let other = doc.text("other")
        let empty = doc.text("empty")
        doc.transact { txn in
            source.insert(txn, at: 0, "AB")
            other.insert(txn, at: 0, "XY")
            let item = StickyIndex.fromIndex(txn, source, 1, assoc: .before)
            #expect(item.toIndex(txn, in: source) == 1)
            #expect(item.toIndex(txn, in: other) == nil)
            let start = StickyIndex.fromIndex(txn, empty, 0, assoc: .before)
            #expect(start.toIndex(txn, in: empty) == 0)
            #expect(start.toIndex(txn, in: source) == nil)
            let end = StickyIndex.fromIndex(txn, source, 2, assoc: .after)
            #expect(end.toIndex(txn, in: source) == 2)
            #expect(end.toIndex(txn, in: other) == nil)
        }
    }

    @Test("left association keeps boundary inserts in the continuation and tracks deletion")
    func tracksMergedBoundary() {
        let doc = YDoc(clientID: 82, gc: false)
        let text = doc.text("merged")
        let boundary = doc.transact { txn in
            text.insert(txn, at: 0, "AB")
            return StickyIndex.fromIndex(txn, text, 1, assoc: .before)
        }
        doc.transact { txn in
            text.insert(txn, at: 2, "Z")
            #expect(text.string(txn) == "ABZ")
            #expect(boundary.toIndex(txn, in: text) == 1)
            text.insert(txn, at: 1, "X")
            #expect(text.string(txn) == "AXBZ")
            #expect(boundary.toIndex(txn, in: text) == 1)
            text.insert(txn, at: 0, "Q")
            #expect(boundary.toIndex(txn, in: text) == 2)
            text.delete(txn, at: 1, length: 1)
            #expect(text.string(txn) == "QXBZ")
            #expect(boundary.toIndex(txn, in: text) == 1)
            #expect(boundary.toIndex(txn, in: text, assoc: .before) == 1)
            #expect(boundary.toIndex(txn, in: text, assoc: .after) == nil)
            let replacement = StickyIndex.fromIndex(txn, text, 1, assoc: .before)
            #expect(replacement.encode() != boundary.encode(), "deleted anchors retain their original identity")
        }
    }

    @Test("UTF-16 boundary survives encoded replica transfer and Unicode prefix edits")
    func replicaAndUnicode() throws {
        let doc = YDoc(clientID: 83, gc: false)
        let text = doc.text("merged")
        let position = doc.transact { txn in
            text.insert(txn, at: 0, "😀e\u{301}Б")
            return StickyIndex.fromIndex(txn, text, 4, assoc: .before)
        }
        let replica = YDoc(clientID: 84, gc: false)
        let replicaText = replica.text("merged")
        let snapshot = doc.transact { doc.encodeStateAsUpdate($0) }
        let decoded = StickyIndex.decode(position.encode())
        try replica.transact { txn in
            #expect(decoded.toIndex(txn, in: replicaText) == nil)
            try replica.applyUpdateChecked(txn, snapshot)
            #expect(decoded.toIndex(txn, in: replicaText) == 4)
            replicaText.insert(txn, at: 0, "🧩")
            #expect(decoded.toIndex(txn, in: replicaText) == 6)
            replicaText.delete(txn, at: 0, length: 2)
            #expect(decoded.toIndex(txn, in: replicaText) == 4)
            #expect(decoded.toIndex(txn, in: text) == nil, "matching names cannot cross transaction owners")
        }
    }

    @Test("root-bound resolution rejects trailing bytes and malformed encoding")
    func rejectsNoncanonicalBytes() {
        let doc = YDoc(clientID: 85, gc: false)
        let text = doc.text("text")
        doc.transact { txn in
            text.insert(txn, at: 0, "AB")
            let encoded = StickyIndex.fromIndex(txn, text, 1, assoc: .before).encode()
            #expect(StickyIndex.decode(encoded).toIndex(txn, in: text) == 1)
            #expect(StickyIndex.decode(encoded + Data([0])).toIndex(txn, in: text) == nil)
            #expect(StickyIndex.decode(Data()).toIndex(txn, in: text) == nil)
            #expect(StickyIndex.decode(Data([255])).toIndex(txn, in: text) == nil)
        }
    }
}
