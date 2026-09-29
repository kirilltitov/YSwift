import Foundation
import Testing

@testable import YSwift

// Yjs 13.6.31 gives a document a new client id when an update applied in a transaction advances the
// document's own client (Transaction.js `cleanupTransactions`), so that its later edits do not reuse
// clocks another peer already wrote under that id. Outcomes recorded in Node for client 7777.
@Suite("client id taken by a remote update")
struct ClientIDChangeTests {
    private static func bytes(_ hex: String) -> Data {
        Data(
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
    }

    /// A map in root `t` created by client 7777 (its own) or 12, at clock 0 or 5 (waiting for 0–4).
    private static let own = Self.bytes("0101e13c00070101740100")
    private static let other = Self.bytes("01010c00070101740100")
    private static let ownWaiting = Self.bytes("0101e13c05070101740100")

    @Test("an update advancing the document's own client gives it a new id")
    func changesTheIDTakenByAnUpdate() throws {
        // Yjs: changed.
        let doc = YDoc(clientID: 7777)
        try doc.transact { try doc.applyUpdateChecked($0, Self.own) }
        let id = doc.clientID
        #expect(id != 7777)
        #expect(id < 1 << 32)
        let text = doc.text("x")
        doc.transact { text.insert($0, at: 0, "a") }
        // Client 7777 stays at clock 1; the new id wrote the "a".
        let state = doc.transact { doc.encodeStateVector($0) }
        #expect(try NativeDoc.decodeStateVector(Array(state.data)) == [7777: 1, id: 1])
    }

    @Test("a mixed transaction with a remote update gives a new id if the local edits advanced it")
    func changesTheIDInAMixedTransaction() throws {
        // Yjs: changed. The transaction applied an update, so yjs takes it as not local.
        let doc = YDoc(clientID: 7777)
        try doc.transact { txn in
            doc.text("x").insert(txn, at: 0, "a")
            try doc.applyUpdateChecked(txn, Self.other)
        }
        #expect(doc.clientID != 7777)
    }

    @Test("updates that leave the document's own client as it was keep the id")
    func keepsTheID() throws {
        // Yjs: kept for another client's update, a local edit, an update of its own client that waits for
        // earlier clocks, and its own state applied again.
        let doc = YDoc(clientID: 7777)
        try doc.transact { try doc.applyUpdateChecked($0, Self.other) }
        doc.transact { doc.text("x").insert($0, at: 0, "a") }
        try doc.transact { try doc.applyUpdateChecked($0, Self.ownWaiting) }
        let state = doc.transact { doc.encodeStateAsUpdate($0) }
        try doc.transact { try doc.applyUpdateChecked($0, state) }
        #expect(doc.clientID == 7777)
    }
}
