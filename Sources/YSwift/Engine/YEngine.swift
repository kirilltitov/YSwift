#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Engine-independent handle to a top-level text type, obtained once per name.
public struct TextHandle: Sendable, Hashable {
    let name: String
}

/// The internal seam between the stable public API and a concrete backend.
///
/// `NativeEngine` provides the pure-Swift YATA + `lib0` implementation. Keeping
/// this protocol internal isolates the public wrappers from storage details.
/// This protocol is internal and may evolve without exposing engine details.
protocol YEngine: AnyObject, Sendable {
    var clientID: UInt64 { get }

    func textHandle(_ name: String) -> TextHandle

    func beginTransaction(origin: Origin?, writable: Bool) -> YTransaction
    func endTransaction(_ txn: YTransaction)
    func changedRootNames(in txn: YTransaction) -> Set<String>?
    func hasPendingUpdates(in txn: YTransaction) -> Bool?

    func textInsert(
        in txn: YTransaction, _ handle: TextHandle, at index: Int, _ string: String, attributes: Attributes?)
    func textDelete(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int)
    func textFormat(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int, attributes: Attributes)
    func textString(in txn: YTransaction, _ handle: TextHandle) -> String
    func textLength(in txn: YTransaction, _ handle: TextHandle) -> Int
    func textDelta(in txn: YTransaction, _ handle: TextHandle) -> [Delta]

    func encodeStateAsUpdate(in txn: YTransaction, since sv: StateVector?) -> Data
    func encodeStateVector(in txn: YTransaction) -> StateVector
    func applyUpdate(in txn: YTransaction, _ update: Data, origin: Origin?) throws

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
    func awarenessEncodeUpdate(_ aw: AnyObject, clients: [UInt64]?) -> Data
    func awarenessApplyUpdate(_ aw: AnyObject, _ update: Data) -> Bool
    func awarenessOnChange(_ aw: AnyObject, _ callback: @escaping @Sendable (Awareness.Change) -> Void) -> YSubscription

    func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription
    func observeText(_ handle: TextHandle, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription

    // Container types (Y.Array / Y.Map) — an extension beyond the §4 text subset.
    func arrayInsert(in txn: YTransaction, _ name: String, at index: Int, _ values: [YValue])
    func arrayDelete(in txn: YTransaction, _ name: String, at index: Int, count: Int)
    func arrayLength(in txn: YTransaction, _ name: String) -> Int
    func arrayValues(in txn: YTransaction, _ name: String) -> [YValue]

    func mapSet(in txn: YTransaction, _ name: String, _ key: String, _ value: YValue)
    func mapDelete(in txn: YTransaction, _ name: String, _ key: String)
    func mapGet(in txn: YTransaction, _ name: String, _ key: String) -> YValue?
    func mapKeys(in txn: YTransaction, _ name: String) -> [String]
    func mapToDictionary(in txn: YTransaction, _ name: String) -> [String: YValue]

    func xmlInsert(in txn: YTransaction, _ name: String, at index: Int, _ nodes: [YXmlNode])
    func xmlString(in txn: YTransaction, _ name: String) -> String

    func destroy()
}
