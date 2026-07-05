import Testing
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
}
