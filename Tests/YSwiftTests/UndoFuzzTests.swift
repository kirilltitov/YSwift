import Foundation
import Synchronization
import Testing

@testable import YSwift

// Differential undo/redo fuzz against recorded JS-Yjs 13.6.31 behaviour (fixtures/undo-fuzz.mjs).
// Every scenario replays local transactions, UndoManager undo/redo/stopCapturing and state
// exchange between documents; after every step the emitted update bytes, the state vector, the
// text and delta of every root and canUndo/canRedo must equal what Yjs recorded, and every
// document's final encoded state must be byte-identical.
//
// UNDO_FUZZ_FIXTURE overrides the bundled fixture; UNDO_FUZZ_REPORT appends one JSON line per
// scenario (a "start" line first, so a crash can be attributed); UNDO_FUZZ_RESUME_AFTER skips
// scenarios up to and including the named one.

struct UndoFuzzSuite: Decodable {
    struct DocSpec: Decodable {
        let client: UInt64
        let gc: Bool
        /// A JS-Yjs peer: its edits are not replayed; the server receives its recorded bytes.
        let js: Bool?
    }

    struct ManagerSpec: Decodable {
        let doc: Int
        let root: String
        let origins: [String]
        let timeout: Int
        let late: Bool?
    }

    struct Op: Decodable {
        let op: String
        let root: String
        /// Absent on nested-type ops, which only JS peers run.
        let index: Int?
        let text: String?
        let length: Int?
        let attributes: [String: GoldenScalar]?
        let embed: [String: GoldenScalar]?
    }

    struct Step: Decodable {
        let k: String
        let doc: Int?
        let origin: String?
        let ops: [Op]?
        let um: Int?
        let from: Int?
        let to: Int?
    }

    struct ManagerState: Decodable, Equatable {
        let index: Int
        let canUndo: Bool
        let canRedo: Bool

        init(index: Int, canUndo: Bool, canRedo: Bool) {
            self.index = index
            self.canUndo = canUndo
            self.canRedo = canRedo
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.index = try container.decode(Int.self)
            self.canUndo = try container.decode(Bool.self)
            self.canRedo = try container.decode(Bool.self)
        }
    }

    struct DocRecord: Decodable {
        let d: Int
        let updates: [String]
        let sv: String
        let texts: [String: String]
        let deltas: [String: String]
        let ums: [ManagerState]
    }

    struct StepRecord: Decodable {
        let docs: [DocRecord]
        let sent: String?
    }

    struct Final: Decodable {
        let state: String
        let sv: String
    }

    struct Scenario: Decodable {
        let name: String
        let docs: [DocSpec]
        let roots: [String]
        let ums: [ManagerSpec]
        let steps: [Step]
        let expect: [StepRecord]
        let final: [Final]
    }

    let scenarios: [Scenario]
}

private final class UpdateLog: Sendable {
    let updates = Mutex<[String]>([])
}

/// Replays one recorded scenario and returns a description of the first divergence, if any.
struct UndoFuzzReplayer {
    let scenario: UndoFuzzSuite.Scenario
    private var docs: [YDoc] = []
    private var logs: [UpdateLog] = []
    private var marks: [Int] = []
    private var managers: [YSwift.UndoManager?] = []
    private var subscriptions: [YSubscription] = []
    private var stepIndex = 0

    /// The JS peer's state vector as Yjs last recorded it before the current step.
    private func jsVector(_ doc: Int) -> String {
        for index in stride(from: self.stepIndex - 1, through: 0, by: -1) {
            if let record = self.scenario.expect[index].docs.first(where: { $0.d == doc }) {
                return record.sv
            }
        }
        return Data([0]).base64EncodedString()
    }

    init(_ scenario: UndoFuzzSuite.Scenario) {
        self.scenario = scenario
        for spec in scenario.docs {
            let doc = YDoc(clientID: spec.client, gc: spec.gc)
            let log = UpdateLog()
            self.subscriptions.append(
                doc.onUpdate { update, _ in log.updates.withLock { $0.append(update.base64EncodedString()) } })
            self.docs.append(doc)
            self.logs.append(log)
            self.marks.append(0)
        }
        self.managers = scenario.ums.map { _ in nil }
        for (index, spec) in scenario.ums.enumerated() where spec.late != true {
            self.managers[index] = self.makeManager(spec)
        }
    }

    private func makeManager(_ spec: UndoFuzzSuite.ManagerSpec) -> YSwift.UndoManager {
        YSwift.UndoManager(
            self.docs[spec.doc].text(spec.root),
            trackedOrigins: Set(spec.origins.map { Origin($0) }),
            captureTimeout: .milliseconds(spec.timeout),
        )
    }

    private static func value(_ scalars: [String: GoldenScalar]) -> YValue {
        .object(scalars.mapValues(\.asYValue))
    }

    private func apply(_ op: UndoFuzzSuite.Op, in doc: YDoc, _ txn: YTransaction) {
        let text = doc.text(op.root)
        let attributes = Golden.attributes(op.attributes)
        switch op.op {
        case "insert": text.insert(txn, at: op.index!, op.text!, attributes: attributes)
        case "embed": text.insertEmbed(txn, at: op.index!, Self.value(op.embed!), attributes: attributes)
        case "delete": text.delete(txn, at: op.index!, length: op.length!)
        case "format": text.format(txn, at: op.index!, length: op.length!, attributes: attributes ?? [:])
        default: Issue.record("unknown op \(op.op)")
        }
    }

    /// Runs the scenario; nil means it matched Yjs everywhere.
    mutating func run() -> String? {
        for (index, step) in self.scenario.steps.enumerated() {
            self.stepIndex = index
            let sent = self.execute(step)
            if let divergence = self.compare(self.scenario.expect[index], sent: sent) {
                return "step \(index) \(Self.describe(step)): \(divergence)"
            }
        }
        for (index, doc) in self.docs.enumerated() where self.scenario.docs[index].js != true {
            let expected = self.scenario.final[index]
            let state = doc.transact { doc.encodeStateAsUpdate($0).base64EncodedString() }
            if state != expected.state {
                return "final doc \(index): state \(state) != \(expected.state)"
            }
        }
        return nil
    }

    private mutating func execute(_ step: UndoFuzzSuite.Step) -> String? {
        switch step.k {
        case "tx" where self.scenario.docs[step.doc!].js == true:
            break
        case "tx":
            let doc = self.docs[step.doc!]
            let origin: Origin? = step.origin.map { Origin($0) }
            doc.transact(origin: origin) { (txn: YTransaction) -> Void in
                for op in step.ops! { self.apply(op, in: doc, txn) }
            }
        case "undo": self.managers[step.um!]?.undo()
        case "redo": self.managers[step.um!]?.redo()
        case "stop": self.managers[step.um!]?.stopCapturing()
        case "newum": self.managers[step.um!] = self.makeManager(self.scenario.ums[step.um!])
        case "destroy": self.managers[step.um!] = nil
        case "sync" where self.scenario.docs[step.to!].js == true:
            // Only what the server sends is compared; the JS peer itself is not modelled.
            let from = self.docs[step.from!]
            let vector = StateVector(data: Data(base64Encoded: self.jsVector(step.to!))!)
            return from.transact { from.encodeStateAsUpdate($0, since: vector) }.base64EncodedString()
        case "sync":
            let from = self.docs[step.from!]
            let to = self.docs[step.to!]
            let update: Data
            if self.scenario.docs[step.from!].js == true {
                update = Data(base64Encoded: self.scenario.expect[self.stepIndex].sent!)!
            } else {
                let vector = to.transact { to.encodeStateVector($0) }
                update = from.transact { from.encodeStateAsUpdate($0, since: vector) }
            }
            let origin: Origin? = step.origin.map { Origin($0) }
            to.transact(origin: origin) { (txn: YTransaction) -> Void in to.applyUpdate(txn, update) }
            return update.base64EncodedString()
        default: Issue.record("unknown step \(step.k)")
        }
        return nil
    }

    private mutating func compare(_ record: UndoFuzzSuite.StepRecord, sent: String?) -> String? {
        if let expected = record.sent, sent != expected {
            return "sent update \(sent ?? "nil") != \(expected)"
        }
        for expected in record.docs where self.scenario.docs[expected.d].js != true {
            let doc = self.docs[expected.d]
            let all = self.logs[expected.d].updates.withLock { $0 }
            let updates = Array(all[self.marks[expected.d]...])
            if updates != expected.updates {
                return "doc \(expected.d): updates \(updates) != \(expected.updates)"
            }
            let vector = doc.transact { doc.encodeStateVector($0).data.base64EncodedString() }
            if vector != expected.sv {
                return "doc \(expected.d): state vector \(vector) != \(expected.sv)"
            }
            for root in self.scenario.roots {
                let text = doc.text(root)
                let (string, delta) = doc.transact { (text.string($0), text.toDelta($0)) }
                if string != expected.texts[root] {
                    let want = expected.texts[root]!.debugDescription
                    return "doc \(expected.d): text \(root) \(string.debugDescription) != \(want)"
                }
                if let json = expected.deltas[root], (try? Golden.parseDelta(json)) != delta {
                    return "doc \(expected.d): delta \(root) \(delta) != \(json)"
                }
            }
            let managers = self.scenario.ums.indices.compactMap { index -> UndoFuzzSuite.ManagerState? in
                guard self.scenario.ums[index].doc == expected.d, let manager = self.managers[index] else {
                    return nil
                }
                return .init(index: index, canUndo: manager.canUndo, canRedo: manager.canRedo)
            }
            if managers != expected.ums {
                return "doc \(expected.d): managers \(managers) != \(expected.ums)"
            }
        }
        for (index, log) in self.logs.enumerated() { self.marks[index] = log.updates.withLock { $0.count } }
        return nil
    }

    static func describe(_ step: UndoFuzzSuite.Step) -> String {
        switch step.k {
        case "tx": "tx(doc \(step.doc!), origin \(step.origin ?? "nil"), \(step.ops!.count) ops)"
        case "sync": "sync(\(step.from!)->\(step.to!), origin \(step.origin ?? "nil"))"
        default: "\(step.k)(um \(step.um!))"
        }
    }
}

@Suite("undo/redo differential fuzz (yjs v13.6.31)")
struct UndoFuzzTests {
    private func suite() throws -> UndoFuzzSuite {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let path = environment["UNDO_FUZZ_FIXTURE"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = try #require(
                Bundle.module.url(forResource: "undo_fuzz_v13_6_31", withExtension: "json", subdirectory: "Fixtures")
            )
        }
        return try JSONDecoder().decode(UndoFuzzSuite.self, from: Data(contentsOf: url))
    }

    @Test("recorded undo/redo scenarios replay byte-identically")
    func replay() throws {
        let environment = ProcessInfo.processInfo.environment
        let report =
            environment["UNDO_FUZZ_REPORT"].map { path -> FileHandle? in
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                let handle = FileHandle(forWritingAtPath: path)
                handle?.seekToEndOfFile()
                return handle
            } ?? nil
        func write(_ object: [String: String]) {
            guard let report, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else {
                return
            }
            report.write(data + Data("\n".utf8))
            try? report.synchronize()
        }
        var skipping = environment["UNDO_FUZZ_RESUME_AFTER"] != nil
        var failures = 0
        let scenarios = try self.suite().scenarios
        for scenario in scenarios {
            if skipping {
                if scenario.name == environment["UNDO_FUZZ_RESUME_AFTER"] {
                    skipping = false
                }
                continue
            }
            write(["name": scenario.name, "status": "start"])
            var replayer = UndoFuzzReplayer(scenario)
            if let divergence = replayer.run() {
                failures += 1
                write(["name": scenario.name, "status": "diverge", "detail": divergence])
                if report == nil {
                    Issue.record("\(scenario.name): \(divergence)")
                }
            } else {
                write(["name": scenario.name, "status": "ok"])
            }
        }
        #expect(failures == 0, "\(failures) of \(scenarios.count) scenarios diverge from Yjs")
    }
}
