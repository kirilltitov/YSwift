import Foundation
import Testing
import YSwift

@Suite("Complete transaction root coverage")
struct ChangedRootNamesTests {
    @Test("Insert, delete-only and format identify only affected top-level text roots")
    func textMutations() throws {
        let doc = YDoc(clientID: 2101)
        doc.transact { txn in
            doc.text("first").insert(txn, at: 0, "base")
            doc.text("second").insert(txn, at: 0, "other")
            #expect(doc.changedRootNames(txn) == ["first", "second"])
        }
        doc.transact { txn in
            #expect(doc.changedRootNames(txn) == [])
            doc.text("first").delete(txn, at: 1, length: 2)
            #expect(doc.changedRootNames(txn) == ["first"])
        }
        doc.transact { txn in
            doc.text("second").format(txn, at: 0, length: 5, attributes: ["bold": true])
            #expect(doc.changedRootNames(txn) == ["second"])
        }
    }

    @Test("Out-of-order updates report roots when buffered structs actually integrate")
    func bufferedAndDuplicateUpdates() throws {
        let source = YDoc(clientID: 2102)
        source.transact { txn in source.text("first").insert(txn, at: 0, "base") }
        let initial = source.transact { source.encodeStateAsUpdate($0) }
        let beforeFirst = source.transact { source.encodeStateVector($0) }
        source.transact { txn in source.text("first").insert(txn, at: 4, " A") }
        let first = source.transact { source.encodeStateAsUpdate($0, since: beforeFirst) }
        let beforeSecond = source.transact { source.encodeStateVector($0) }
        source.transact { txn in source.text("second").insert(txn, at: 0, "B") }
        let second = source.transact { source.encodeStateAsUpdate($0, since: beforeSecond) }
        let receiver = YDoc(clientID: 2103)
        try receiver.transact { txn in try receiver.applyUpdateChecked(txn, initial) }
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, second)
            #expect(receiver.changedRootNames(txn) == [])
            #expect(receiver.hasPendingUpdates(txn) == true)
        }
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, first)
            #expect(receiver.changedRootNames(txn) == ["first", "second"])
            #expect(receiver.hasPendingUpdates(txn) == false)
            #expect(receiver.text("first").string(txn) == "base A")
            #expect(receiver.text("second").string(txn) == "B")
        }
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, first)
            try receiver.applyUpdateChecked(txn, second)
            #expect(receiver.changedRootNames(txn) == [])
        }
    }

    @Test("Remote delete-only and formatting updates preserve dirty-root completeness")
    func remoteDeleteAndFormat() throws {
        let source = YDoc(clientID: 2104)
        source.transact { txn in
            source.text("first").insert(txn, at: 0, "base")
            source.text("second").insert(txn, at: 0, "other")
        }
        let initial = source.transact { source.encodeStateAsUpdate($0) }
        let receiver = YDoc(clientID: 2105)
        try receiver.transact { txn in try receiver.applyUpdateChecked(txn, initial) }
        let vector = source.transact { source.encodeStateVector($0) }
        source.transact { txn in source.text("first").delete(txn, at: 0, length: 4) }
        let deleted = source.transact { source.encodeStateAsUpdate($0, since: vector) }
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, deleted)
            #expect(receiver.changedRootNames(txn) == ["first"])
            #expect(receiver.text("first").string(txn) == "")
        }
        let beforeFormat = source.transact { source.encodeStateVector($0) }
        source.transact { txn in
            source.text("second").format(txn, at: 0, length: 5, attributes: ["italic": true])
        }
        let formatted = source.transact { source.encodeStateAsUpdate($0, since: beforeFormat) }
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, formatted)
            #expect(receiver.changedRootNames(txn) == ["second"])
        }
    }

    @Test("Nested types require conservative full-validation fallback")
    func nestedFallback() throws {
        let source = YDoc(clientID: 2106)
        source.transact { txn in
            source.xmlFragment("document").insert(
                txn,
                at: 0,
                [.element(tag: "section", attributes: [:], children: [.text("nested")])],
            )
            #expect(source.changedRootNames(txn) == nil)
        }
        let state = source.transact { source.encodeStateAsUpdate($0) }
        let receiver = YDoc(clientID: 2107)
        try receiver.transact { txn in
            try receiver.applyUpdateChecked(txn, state)
            #expect(receiver.changedRootNames(txn) == nil)
        }
    }

    @Test("A transaction belonging to another document cannot authorize a root set")
    func foreignTransaction() {
        let source = YDoc(clientID: 2108)
        let other = YDoc(clientID: 2109)
        source.transact { txn in
            source.text("first").insert(txn, at: 0, "base")
            #expect(other.changedRootNames(txn) == nil)
            #expect(other.hasPendingUpdates(txn) == nil)
        }
    }
}
