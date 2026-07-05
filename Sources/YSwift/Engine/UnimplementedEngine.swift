#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds the engine backing a new `YDoc`. Phase 1 will return `YrsEngine(gc:)`.
func makeDefaultEngine(gc: Bool) -> any YEngine {
    UnimplementedEngine(gc: gc)
}

/// Placeholder backend used while the public API is frozen but no real engine is
/// wired yet.
///
/// Lifecycle/structural calls succeed so the API shape can be exercised; any
/// operation that would touch real CRDT state traps with a clear message.
/// Replaced by `YrsEngine` in Phase 1.
final class UnimplementedEngine: YEngine {
    let clientID: UInt64

    init(gc: Bool) {
        // Yjs client ids are 53-bit integers (JS safe-integer range).
        self.clientID = UInt64.random(in: 0 ..< (UInt64(1) << 53))
    }

    func textHandle(_ name: String) -> TextHandle { TextHandle(name: name) }

    func beginTransaction(origin: Origin?, writable: Bool) -> YTransaction {
        YTransaction(engine: self, origin: origin, writable: writable, raw: nil)
    }

    func endTransaction(_ txn: YTransaction) { /* no-op */ }

    func textInsert(in txn: YTransaction, _ handle: TextHandle, at index: Int, _ string: String, attributes: Attributes?) { unimplemented() }
    func textDelete(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int) { unimplemented() }
    func textFormat(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int, attributes: Attributes) { unimplemented() }
    func textString(in txn: YTransaction, _ handle: TextHandle) -> String { unimplemented() }
    func textLength(in txn: YTransaction, _ handle: TextHandle) -> Int { unimplemented() }
    func textDelta(in txn: YTransaction, _ handle: TextHandle) -> [Delta] { unimplemented() }

    func encodeStateAsUpdate(in txn: YTransaction, since sv: StateVector?) -> Data { unimplemented() }
    func encodeStateVector(in txn: YTransaction) -> StateVector { unimplemented() }
    func applyUpdate(in txn: YTransaction, _ update: Data, origin: Origin?) { unimplemented() }

    func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription { YSubscription {} }
    func observeText(_ handle: TextHandle, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription { YSubscription {} }

    func destroy() { /* no-op */ }

    private func unimplemented(_ function: StaticString = #function) -> Never {
        fatalError("YSwift: \(function) is not implemented yet. Phase 1 wires this to the Yrs (yffi) backend; see DECISIONS.md.")
    }
}
