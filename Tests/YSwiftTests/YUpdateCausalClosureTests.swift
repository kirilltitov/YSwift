import Foundation
import Testing
import YSwift

@Suite("Document-less updates require causal closure")
struct YUpdateCausalClosureTests {
    @Test("Partial insertion and deletion throw instead of being silently erased", arguments: [false, true])
    func partialUpdateIsRejected(deletion: Bool) throws {
        let document = YDoc(clientID: 8801)
        let text = document.text("root")
        document.transact { text.insert($0, at: 0, "AB") }
        let base = document.transact { document.encodeStateAsUpdate($0) }
        let vector = document.transact { document.encodeStateVector($0) }
        document.transact {
            if deletion {
                text.delete($0, at: 0, length: 1)
            } else {
                text.insert($0, at: 1, " ")
            }
        }
        let partial = document.transact { document.encodeStateAsUpdate($0, since: vector) }
        #expect(throws: YError.causalDependenciesMissing) { try YUpdate.merge([partial]) }
        #expect(throws: YError.causalDependenciesMissing) { try YUpdate.diff(partial, since: vector) }
        let merged = try YUpdate.merge([partial, base])
        let recovered = YDoc()
        try recovered.transact { try recovered.applyUpdateChecked($0, merged) }
        #expect(recovered.transact { recovered.text("root").string($0) } == (deletion ? "B" : "A B"))
        #expect(
            recovered.transact { recovered.encodeStateVector($0) }
                == document.transact { document.encodeStateVector($0) }
        )
    }

    @Test("A stateful compensation retains inserted IDs needed by later input")
    func compensationPreservesLateInput() throws {
        let server = YDoc(clientID: 8802)
        server.transact { server.text("root").insert($0, at: 0, "AB") }
        let base = server.transact { server.encodeStateAsUpdate($0) }
        let frontier = server.transact { server.encodeStateVector($0) }
        let client = YDoc(clientID: 8803)
        try client.transact { try client.applyUpdateChecked($0, base) }
        client.transact { client.text("root").insert($0, at: 1, " ") }
        let candidate = client.transact { client.encodeStateAsUpdate($0, since: frontier) }
        let afterCandidate = client.transact { client.encodeStateVector($0) }
        client.transact { client.text("root").insert($0, at: 2, "Z") }
        let later = client.transact { client.encodeStateAsUpdate($0, since: afterCandidate) }
        let origin = Origin("candidate")
        let undo = UndoManager(server.text("root"), trackedOrigins: [origin], captureTimeout: .milliseconds(0))
        try server.transact(origin: origin) { try server.applyUpdateChecked($0, candidate) }
        undo.undo()
        let compensation = server.transact { server.encodeStateAsUpdate($0, since: frontier) }
        #expect(throws: YError.causalDependenciesMissing) { try YUpdate.merge([candidate, compensation]) }
        try client.transact { try client.applyUpdateChecked($0, compensation) }
        try server.transact { try server.applyUpdateChecked($0, later) }
        #expect(server.transact { server.text("root").string($0) } == "AZB")
        #expect(client.transact { client.text("root").string($0) } == "AZB")
        #expect(
            server.transact { server.encodeStateVector($0) }
                == client.transact { client.encodeStateVector($0) }
        )
    }
}
