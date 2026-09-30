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

    @Test("UndoManager over several texts undoes a change to all of them in one update")
    func undoAcrossTexts() {
        let doc = YDoc(clientID: 1)
        let first = doc.text("first")
        let second = doc.text("second")
        doc.transact { txn in first.insert(txn, at: 0, "hello world") }
        let undo = YSwift.UndoManager([first, second], trackedOrigins: ["user"])
        let updates = Mutex(0)
        let subscription = doc.onUpdate { _, _ in updates.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        // A split moves the tail of one text into the other.
        doc.transact(origin: "user") { txn in
            first.delete(txn, at: 5, length: 6)
            second.insert(txn, at: 0, " world")
        }
        undo.undo()
        #expect(doc.transact { txn in [first.string(txn), second.string(txn)] } == ["hello world", ""])
        undo.redo()
        #expect(doc.transact { txn in [first.string(txn), second.string(txn)] } == ["hello", " world"])
        #expect(updates.withLock { $0 } == 3)
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

    @Test("Awareness ignores an update whose clock no JS number holds exactly")
    func awarenessRejectsUnsafeClocks() {
        func update(client: UInt64, clock: UInt64, state: String) -> Data {
            var bytes: [UInt8] = [1]
            for var value in [client, clock] {
                while value > 0x7F {
                    bytes.append(UInt8(value & 0x7F) | 0x80)
                    value >>= 7
                }
                bytes.append(UInt8(value))
            }
            bytes.append(UInt8(state.utf8.count))
            return Data(bytes + Array(state.utf8))
        }
        let doc = YDoc(clientID: 2)
        let awareness = Awareness(doc)
        awareness.setLocalStateField("x", 1)
        // lib0 fails to read these; they used to stop the process on the conversion to Int, or on the
        // clock bump a remote null state gets for the local client.
        awareness.applyUpdate(update(client: 5, clock: .max, state: "{}"))
        awareness.applyUpdate(update(client: 2, clock: 1 << 53, state: "null"))
        #expect(awareness.states()[5] == nil)
        #expect(awareness.states()[2]?["x"] == .int(1))
        // The largest safe clock is still adopted, and a later null bumps it without overflow.
        awareness.applyUpdate(update(client: 6, clock: (1 << 53) - 1, state: "{}"))
        awareness.applyUpdate(update(client: 2, clock: (1 << 53) - 1, state: "null"))
        #expect(awareness.states()[6] != nil)
        #expect(awareness.states()[2]?["x"] == .int(1))
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
