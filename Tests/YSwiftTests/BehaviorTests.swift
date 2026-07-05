import Testing
import Synchronization
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
@testable import YSwift

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
        undo.undo() // no-op
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
}
