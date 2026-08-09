import Synchronization
import Testing

@testable import YSwift

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Behavioral (non-golden) checks for stateful helpers.
@Suite("Engine behavior")
struct EngineBehaviorTests {

    @Test("UndoManager undoes and redoes tracked-origin edits")
    func undoRedo() {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        let undo = YSwift.UndoManager(text, trackedOrigins: ["user"])

        doc.transact(origin: "user") { txn in text.insert(txn, at: 0, "hello") }
        #expect(doc.transact { txn in text.string(txn) } == "hello")
        #expect(undo.canUndo)

        undo.undo()
        #expect(doc.transact { txn in text.string(txn) } == "")
        #expect(undo.canRedo)

        undo.redo()
        #expect(doc.transact { txn in text.string(txn) } == "hello")
    }

    @Test("UndoManager ignores edits from untracked origins")
    func undoUntracked() {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        let undo = YSwift.UndoManager(text, trackedOrigins: ["user"])

        doc.transact(origin: "other") { txn in text.insert(txn, at: 0, "x") }
        #expect(!undo.canUndo)
        undo.undo()  // no-op
        #expect(doc.transact { txn in text.string(txn) } == "x")
    }

    @Test("Awareness syncs local state between peers")
    func awarenessSync() {
        let docA = YDoc(clientID: 1)
        let awA = Awareness(docA)
        awA.setLocalStateField("name", "Alice")
        awA.setLocalStateField("color", "#f00")

        let update = awA.encodeUpdate()
        #expect(!update.isEmpty)

        let docB = YDoc(clientID: 2)
        let awB = Awareness(docB)
        awB.applyUpdate(update)

        let states = awB.states()
        #expect(states[docA.clientID]?["name"] == .string("Alice"))
        #expect(states[docA.clientID]?["color"] == .string("#f00"))
    }

    @Test("Awareness onChange reports newly-added clients")
    func awarenessOnChange() {
        let docB = YDoc(clientID: 2)
        let awB = Awareness(docB)
        let added = Mutex<[UInt64]>([])
        let sub = awB.onChange { change in added.withLock { $0.append(contentsOf: change.added) } }

        let docA = YDoc(clientID: 1)
        let awA = Awareness(docA)
        awA.setLocalStateField("x", 1)
        awB.applyUpdate(awA.encodeUpdate())
        sub.cancel()

        #expect(added.withLock { $0 }.contains(1))
    }

    @Test("text.observe reports the change delta per transaction")
    func textObserve() {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        doc.transact { txn in text.insert(txn, at: 0, "hello") }

        let captured = Mutex<[[Delta]]>([])
        let sub = text.observe { event in captured.withLock { $0.append(event.delta) } }

        doc.transact(origin: "user") { txn in text.insert(txn, at: 5, " world") }
        doc.transact { txn in text.delete(txn, at: 0, length: 1) }
        sub.cancel()

        let deltas = captured.withLock { $0 }
        #expect(deltas.count == 2)
        #expect(deltas.first == [.retain(5, attributes: nil), .insert(.string(" world"), attributes: nil)])
        #expect(deltas.last == [.delete(1)])
    }

    @Test("text insert distinguishes omitted from explicitly empty attributes")
    func textInsertAttributeInheritance() {
        let doc = YDoc(clientID: 1)
        let inherited = doc.text("inherited")
        let cleared = doc.text("cleared")

        doc.transact { txn in
            inherited.insert(txn, at: 0, "A", attributes: ["bold": true])
            inherited.insert(txn, at: 1, "B")

            cleared.insert(txn, at: 0, "A", attributes: ["bold": true])
            cleared.insert(txn, at: 1, "B", attributes: [:])
        }

        #expect(
            doc.transact { inherited.toDelta($0) }
                == [.insert(.string("AB"), attributes: ["bold": true])]
        )
        #expect(
            doc.transact { cleared.toDelta($0) }
                == [
                    .insert(.string("A"), attributes: ["bold": true]),
                    .insert(.string("B"), attributes: nil),
                ]
        )
    }

    @Test("Awareness.encodeUpdate(clients:) restricts the update to the given clients")
    func awarenessEncodeSubset() {
        let docA = YDoc(clientID: 1)
        let awA = Awareness(docA)
        awA.setLocalStateField("n", "A")

        let docB = YDoc(clientID: 2)
        let awB = Awareness(docB)
        awB.setLocalStateField("n", "B")
        awB.applyUpdate(awA.encodeUpdate())  // awB now knows clients 1 and 2

        let subset = awB.encodeUpdate(clients: [1])  // only client 1
        let docC = YDoc(clientID: 3)
        let awC = Awareness(docC)
        awC.applyUpdate(subset)

        let states = awC.states()
        #expect(states[1]?["n"] == .string("A"))
        #expect(states[2] == nil)
    }
}
