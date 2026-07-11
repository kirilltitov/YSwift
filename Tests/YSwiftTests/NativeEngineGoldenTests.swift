import Foundation
import Synchronization
import Testing

@testable import YSwift

// The golden vectors, driven through the FROZEN PUBLIC API but on a
// NativeEngine-backed YDoc (instead of the default YrsEngine). This is the
// drop-in acceptance proof for the pure-Swift engine's encode/decode/onUpdate/
// sticky/toDelta surface. Undo/awareness/observeText are not yet native and are
// left to the YrsEngine suites.
@Suite("Golden vectors on NativeEngine")
struct NativeEngineGoldenTests {
    private func doc(clientID: UInt64) -> YDoc {
        YDoc(engine: NativeEngine(clientID: clientID, gc: true))
    }

    @Test("golden-encode: replaying ops yields byte-identical update + state vector")
    func goldenEncode() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode {
            let doc = self.doc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            doc.transact { txn in Golden.replay(f.ops, into: text, txn) }
            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == f.update, "\(f.name): update")
                #expect(
                    doc.encodeStateVector(txn).data.base64EncodedString() == f.stateVector, "\(f.name): state vector")
                #expect(text.string(txn) == f.text, "\(f.name): text")
            }
        }
    }

    @Test("golden-decode: applying reference updates reconstructs the text")
    func goldenDecode() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode {
            let update = try #require(Data(base64Encoded: f.update))
            let doc = self.doc(clientID: f.clientID)
            doc.transact { txn in doc.applyUpdate(txn, update) }
            #expect(doc.transact { txn in doc.text(suite.meta.key).string(txn) } == f.text, "\(f.name)")
        }
    }

    @Test("convergence: applying updates in any order yields the same text")
    func convergence() throws {
        let suite = try Golden.loadSuite()
        for f in suite.converge {
            let updates = try f.updates.map { try #require(Data(base64Encoded: $0)) }
            for order in [updates, updates.reversed()] {
                let doc = self.doc(clientID: 42)
                doc.transact { txn in for u in order { doc.applyUpdate(txn, u) } }
                #expect(doc.transact { txn in doc.text(suite.meta.key).string(txn) } == f.text, "\(f.name)")
            }
        }
    }

    @Test("onUpdate emits byte-identical incremental updates in order")
    func onUpdateIncremental() throws {
        let suite = try Golden.loadSuite()
        for f in suite.incremental {
            let doc = self.doc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            let collected = Mutex<[String]>([])
            let sub = doc.onUpdate { update, _ in collected.withLock { $0.append(update.base64EncodedString()) } }
            for txnOps in f.transactions {
                doc.transact { txn in Golden.replay(txnOps, into: text, txn) }
            }
            sub.cancel()
            #expect(collected.withLock { $0 } == f.updates, "\(f.name): incremental updates")
            #expect(doc.transact { txn in text.string(txn) } == f.text, "\(f.name): final text")
        }
    }

    @Test("transaction origin round-trips to the update observer")
    func originRoundTrip() throws {
        let doc = self.doc(clientID: 7)
        let text = doc.text("content")
        let seen = Mutex<[String?]>([])
        let sub = doc.onUpdate { _, origin in seen.withLock { $0.append(origin?.rawValue) } }
        doc.transact(origin: "local") { txn in text.insert(txn, at: 0, "a") }
        doc.transact { txn in text.insert(txn, at: 1, "b") }
        sub.cancel()
        #expect(seen.withLock { $0 } == ["local", nil])
    }

    @Test("toDelta matches yjs toDelta structurally")
    func toDeltaConformance() throws {
        let suite = try Golden.loadSuite()
        for f in suite.encode {
            let doc = self.doc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            doc.transact { txn in Golden.replay(f.ops, into: text, txn) }
            let mine = doc.transact { txn in text.toDelta(txn) }
            let expected = try Golden.parseDelta(f.deltaJSON)
            #expect(mine == expected, "\(f.name): toDelta")
        }
    }

    @Test("diff: an incremental update since a state vector reproduces the golden diff")
    func diffConformance() throws {
        let suite = try Golden.loadSuite()
        for f in suite.diff {
            let full = try #require(Data(base64Encoded: f.full))
            let sinceSV = StateVector(data: try #require(Data(base64Encoded: f.sinceStateVector)))
            let doc = self.doc(clientID: f.clientID)
            doc.transact { txn in doc.applyUpdate(txn, full) }
            doc.transact { txn in
                #expect(doc.encodeStateAsUpdate(txn, since: sinceSV).base64EncodedString() == f.diff, "\(f.name): diff")
                #expect(doc.encodeStateAsUpdate(txn).base64EncodedString() == f.full, "\(f.name): full")
            }
        }
    }

    @Test("text.observe reports the per-transaction change delta")
    func textObserve() throws {
        let doc = self.doc(clientID: 1)
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

    @Test("StickyIndex encodes byte-compatibly and resolves through edits")
    func stickyConformance() throws {
        let suite = try Golden.loadSuite()
        for f in suite.sticky {
            let doc = self.doc(clientID: f.clientID)
            let text = doc.text(suite.meta.key)
            doc.transact { txn in Golden.replay(f.baseOps, into: text, txn) }
            let assoc: StickyIndex.Assoc = f.assoc < 0 ? .before : .after
            let sticky = doc.transact { txn in StickyIndex.fromIndex(txn, text, f.index, assoc: assoc) }
            #expect(sticky.encode().base64EncodedString() == f.encoded, "\(f.name): encoded")
            #expect(doc.transact { txn in sticky.toIndex(txn, doc) } == f.resolvedBefore, "\(f.name): before")
            doc.transact { txn in Golden.replay(f.shiftOps, into: text, txn) }
            #expect(doc.transact { txn in sticky.toIndex(txn, doc) } == f.resolvedAfter, "\(f.name): after")
        }
    }
}
