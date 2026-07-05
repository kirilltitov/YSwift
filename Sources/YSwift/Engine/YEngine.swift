#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Opaque, engine-specific handle to a top-level text type, obtained once per
/// name. Phase 1 will additionally carry the underlying Yrs `Branch` pointer.
public struct TextHandle: Sendable, Hashable {
    let name: String

    init(name: String) { self.name = name }
}

/// The internal seam between the frozen public API and a concrete backend.
///
/// - Phase 1: `YrsEngine` — a facade over the Rust `yrs` library via the `yffi`
///   C ABI.
/// - Phase 2: `NativeEngine` — a pure-Swift YATA + `lib0` implementation.
///
/// Both **must** produce byte-identical wire output; the public API never
/// changes between them. This protocol is internal and may evolve as long as
/// the public surface stays frozen.
protocol YEngine: AnyObject, Sendable {
    var clientID: UInt64 { get }

    func textHandle(_ name: String) -> TextHandle

    func beginTransaction(origin: Origin?, writable: Bool) -> YTransaction
    func endTransaction(_ txn: YTransaction)

    func textInsert(in txn: YTransaction, _ handle: TextHandle, at index: Int, _ string: String, attributes: Attributes?)
    func textDelete(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int)
    func textFormat(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int, attributes: Attributes)
    func textString(in txn: YTransaction, _ handle: TextHandle) -> String
    func textLength(in txn: YTransaction, _ handle: TextHandle) -> Int
    func textDelta(in txn: YTransaction, _ handle: TextHandle) -> [Delta]

    func encodeStateAsUpdate(in txn: YTransaction, since sv: StateVector?) -> Data
    func encodeStateVector(in txn: YTransaction) -> StateVector
    func applyUpdate(in txn: YTransaction, _ update: Data, origin: Origin?)

    func stickyFromIndex(in txn: YTransaction, _ handle: TextHandle, index: Int, assoc: StickyIndex.Assoc) -> Data?
    func stickyToIndex(in txn: YTransaction, _ raw: Data) -> Int?

    func makeUndoManager(_ handle: TextHandle, trackedOrigins: Set<Origin>, captureTimeoutMillis: UInt64) -> AnyObject?
    func undoManagerUndo(_ mgr: AnyObject) -> Bool
    func undoManagerRedo(_ mgr: AnyObject) -> Bool
    func undoManagerCanUndo(_ mgr: AnyObject) -> Bool
    func undoManagerCanRedo(_ mgr: AnyObject) -> Bool
    func undoManagerStopCapturing(_ mgr: AnyObject)

    func makeAwareness() -> AnyObject?
    func awarenessSetLocalState(_ aw: AnyObject, json: Data)
    func awarenessCleanLocalState(_ aw: AnyObject)
    func awarenessRemoveState(_ aw: AnyObject, client: UInt64)
    func awarenessStates(_ aw: AnyObject) -> Data
    func awarenessEncodeUpdate(_ aw: AnyObject) -> Data
    func awarenessApplyUpdate(_ aw: AnyObject, _ update: Data) -> Bool
    func awarenessOnChange(_ aw: AnyObject, _ callback: @escaping @Sendable (Awareness.Change) -> Void) -> YSubscription

    func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription
    func observeText(_ handle: TextHandle, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription

    func destroy()
}
