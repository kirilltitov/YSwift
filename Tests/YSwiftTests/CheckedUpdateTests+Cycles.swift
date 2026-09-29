import Foundation
import Testing

@testable import YSwift

// Updates that thread one list or key chain into another: a run sent again is linked in after the
// struct just before its first new clock, whatever that struct's parent (yjs `Item.integrate`). The
// document then holds chains that lead back into themselves. YSwift rejects such runs; these tests let
// them in, as yjs does, to check that every walk over such chains still ends.
extension CheckedUpdateTests {
    /// Hex strings as bytes.
    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    @Test("collecting a type ends on a key chain that leads back into it")
    func collectEndsOnStoredCycle() throws {
        // Kept without gc, where yjs accepts the updates too, then collected: the map's entry leads back
        // to the map's own item.
        let updates = try ["AQEFAAcBB2NvbnRlbnQBAA==", "AQEFACEABQABbAIA"].map {
            Array(try #require(Data(base64Encoded: $0)))
        }
        Self.onWorkerSizedStack("collect", seconds: 10, megabytes: 256) {
            let doc = NativeDoc(clientID: 1, gc: false)
            doc.store.rejectsRunsUnderAnotherParent = false
            for update in updates { try? doc.applyUpdate(update) }
            doc.store.cleanup(gc: true, deletes: [(client: 5, clock: 0, length: 2)])
        }
    }

    @Test("deleting a type ends on a list that leads back into itself")
    func deleteEndsOnCyclicList() {
        Self.onWorkerSizedStack("delete", seconds: 10, megabytes: 256) {
            let store = NativeStore()
            let root = YTypeImpl(name: "r")
            let type = YTypeImpl()
            let owner = Item(
                id: YID(client: 1, clock: 0), origin: nil, rightOrigin: nil, parent: root, parentID: nil,
                parentSub: nil, content: .type(type, typeRef: 0, name: nil))
            let first = Item(
                id: YID(client: 1, clock: 1), origin: nil, rightOrigin: nil, parent: type, parentID: nil,
                parentSub: nil, content: .string(Array("a".utf16)[...]))
            let second = Item(
                id: YID(client: 1, clock: 2), origin: nil, rightOrigin: nil, parent: type, parentID: nil,
                parentSub: nil, content: .string(Array("b".utf16)[...]))
            type.item = owner
            type.start = first
            first.right = second
            second.right = first
            store.deleteItem(owner)
            #expect(first.deleted && second.deleted)
        }
    }

    /// Applies `updates` under an UndoManager tracking them, undoing and redoing along the way as the
    /// structured fuzz harness does, then undoes and redoes everything.
    private static func replayUnderUndo(_ updates: [String], root: String) -> Int {
        let doc = YDoc(clientID: 7777)
        (doc.engine as? NativeEngine)?.doc.store.rejectsRunsUnderAnotherParent = false
        let undoManager = UndoManager(doc.text(root), trackedOrigins: [Origin("u")], captureTimeout: .zero)
        for update in updates.map({ Data(Self.bytes($0)) }) {
            try? doc.transact(origin: Origin("u")) { try doc.applyUpdateChecked($0, update) }
            if undoManager.canUndo, update.count % 3 == 0 {
                undoManager.undo()
                if undoManager.canRedo { undoManager.redo() }
            }
        }
        var steps = 0
        while undoManager.canUndo, steps < 500 {
            undoManager.undo()
            steps += 1
        }
        while undoManager.canRedo, steps < 1000 {
            undoManager.redo()
            steps += 1
        }
        return steps
    }

    @Test(
        "redoing ends on redone and neighbour chains that lead back into themselves",
        arguments: [
            // A map entry whose right neighbour is a list item redone right before itself: yjs `redoItem`
            // follows right and redone links from one to the other and never returns.
            (
                "x",
                [
                    "030100000701017802020300000524000000016b03e2808b01020084000002206300",
                    "0102030344020106622063592062020003030303302e3109756e646566696e6564127b2261223a7b2262223a5b6e756c"
                        + "6c5d7d7d00",
                    "0202e13c00850308115b5b5b5b5b5b5b5b315d5d5d5d5d5d5d5d00010200018800000376007b7e37e43c880075"
                        + "9c7600000100",
                ]
            ),
            (
                "m",
                [
                    "010201002701016d016c0303646976000100",
                    "020205000001000203e13c000401016d0661f09f9880622401017809756e646566696e6564167171717171717171"
                        + "71717171717171717171717171710400000e0271710102010a05",
                ]
            ),
        ]
    )
    func redoEndsOnCyclicChains(root: String, updates: [String]) {
        let steps = Self.onWorkerSizedStack("redo", seconds: 10, megabytes: 256) {
            Self.replayUnderUndo(updates, root: root)
        }
        #expect(steps < 1000)
    }
}
