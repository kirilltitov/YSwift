import CYrs
import Synchronization
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds the engine backing a new `YDoc`. Phase 1: the Yrs facade.
func makeDefaultEngine(clientID: UInt64?, gc: Bool) -> any YEngine {
    YrsEngine(clientID: clientID, gc: gc)
}

/// Boxes an opaque transaction pointer so it can ride inside `YTransaction.raw`.
final class RawTransaction {
    let ptr: OpaquePointer
    init(_ ptr: OpaquePointer) { self.ptr = ptr }
}

/// Owns a yrs `UndoManager` pointer; frees it on release.
///
/// Freeing unsubscribes the manager's document observers, so release it on the
/// same context that drives the document (not concurrently with a transaction).
final class RawUndoManager {
    let ptr: OpaquePointer
    init(_ ptr: OpaquePointer) { self.ptr = ptr }
    deinit { yundo_free(ptr) }
}

/// Holds a Swift update callback so the C trampoline can reach it via a `void*`.
final class UpdateCallbackBox {
    let callback: @Sendable (Data, Origin?) -> Void
    init(_ callback: @escaping @Sendable (Data, Origin?) -> Void) { self.callback = callback }
}

/// Raw handles released when a subscription is cancelled. `@unchecked Sendable`:
/// released exactly once, and the underlying yrs `Subscription` is `Send + Sync`.
private struct SubHandles: @unchecked Sendable {
    let sub: OpaquePointer
    let userData: UnsafeMutableRawPointer
}

/// C trampoline for `ydoc_observe_update_v1`: rebuilds `Data`/`Origin` from the
/// call-scoped buffers and invokes the boxed Swift callback.
private func yrsUpdateTrampoline(
    _ userData: UnsafeMutableRawPointer?,
    _ originPtr: UnsafePointer<UInt8>?,
    _ originLen: Int,
    _ updatePtr: UnsafePointer<UInt8>?,
    _ updateLen: Int
) {
    guard let userData else { return }
    let box = Unmanaged<UpdateCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    let update = (updateLen > 0 && updatePtr != nil) ? Data(bytes: updatePtr!, count: updateLen) : Data()
    let origin: Origin?
    if originLen > 0, let originPtr {
        origin = Origin(String(decoding: UnsafeBufferPointer(start: originPtr, count: originLen), as: UTF8.self))
    } else {
        origin = nil
    }
    box.callback(update, origin)
}

/// Phase-1 engine: a facade over the Rust `yrs` CRDT via the `cyrs` C ABI.
///
/// `@unchecked Sendable` invariant: the raw `yrs` document is only ever touched
/// while the owning `YDoc`'s `Mutex` is held (all transaction-scoped calls and
/// subscription registration) or via the one-shot free path below; there is at
/// most one live transaction per document. The engine holds no mutable shared
/// state besides the (idempotently freed) doc — text types are resolved by name
/// through the active transaction.
final class YrsEngine: YEngine, @unchecked Sendable {
    private let doc: OpaquePointer
    let clientID: UInt64
    private let alive = Mutex<Bool>(true)

    init(clientID: UInt64?, gc: Bool) {
        // v13 generates 32-bit client ids; match that for the random case.
        let requested = clientID ?? UInt64.random(in: 0 ..< (UInt64(1) << 32))
        doc = ydoc_new(requested, !gc)
        self.clientID = ydoc_client_id(doc)
    }

    deinit { freeDoc() }

    func destroy() { freeDoc() }

    private func freeDoc() {
        let shouldFree = alive.withLock { flag -> Bool in
            defer { flag = false }
            return flag
        }
        if shouldFree { ydoc_destroy(doc) }
    }

    // MARK: Handles & transactions

    func textHandle(_ name: String) -> TextHandle { TextHandle(name: name) }

    func beginTransaction(origin: Origin?, writable: Bool) -> YTransaction {
        let raw: OpaquePointer
        if let origin {
            let bytes = Array(origin.rawValue.utf8)
            raw = bytes.withUnsafeBufferPointer { ytxn_with_origin(doc, $0.baseAddress, $0.count)! }
        } else {
            raw = ytxn(doc)!
        }
        return YTransaction(engine: self, origin: origin, writable: writable, raw: RawTransaction(raw))
    }

    func endTransaction(_ txn: YTransaction) {
        if let t = txnPtr(txn) { ytxn_commit(t) }
    }

    // MARK: Text operations (name resolved through the active transaction)

    func textInsert(in txn: YTransaction, _ handle: TextHandle, at index: Int, _ string: String, attributes: Attributes?) {
        guard let t = txnPtr(txn) else { return }
        let name = Array(handle.name.utf8)
        let str = Array(string.utf8)
        name.withUnsafeBufferPointer { n in
            if let attributes, !attributes.isEmpty {
                let json = attributesJSON(attributes)
                str.withUnsafeBufferPointer { s in
                    json.withUnsafeBufferPointer { a in
                        ytext_insert_attrs(t, n.baseAddress, n.count, UInt32(index), s.baseAddress, s.count, a.baseAddress, a.count)
                    }
                }
            } else {
                str.withUnsafeBufferPointer { s in
                    ytext_insert(t, n.baseAddress, n.count, UInt32(index), s.baseAddress, s.count)
                }
            }
        }
    }

    func textDelete(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int) {
        guard let t = txnPtr(txn) else { return }
        let name = Array(handle.name.utf8)
        name.withUnsafeBufferPointer { n in
            ytext_remove(t, n.baseAddress, n.count, UInt32(index), UInt32(length))
        }
    }

    func textFormat(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int, attributes: Attributes) {
        guard let t = txnPtr(txn) else { return }
        let name = Array(handle.name.utf8)
        let json = attributesJSON(attributes)
        name.withUnsafeBufferPointer { n in
            json.withUnsafeBufferPointer { a in
                ytext_format(t, n.baseAddress, n.count, UInt32(index), UInt32(length), a.baseAddress, a.count)
            }
        }
    }

    func textString(in txn: YTransaction, _ handle: TextHandle) -> String {
        guard let t = txnPtr(txn) else { return "" }
        let name = Array(handle.name.utf8)
        var outLen = 0
        let ptr = name.withUnsafeBufferPointer { n in ytext_string(t, n.baseAddress, n.count, &outLen) }
        return String(decoding: consumeBytes(ptr, outLen), as: UTF8.self)
    }

    func textLength(in txn: YTransaction, _ handle: TextHandle) -> Int {
        guard let t = txnPtr(txn) else { return 0 }
        let name = Array(handle.name.utf8)
        return name.withUnsafeBufferPointer { n in Int(ytext_len(t, n.baseAddress, n.count)) }
    }

    func textDelta(in txn: YTransaction, _ handle: TextHandle) -> [Delta] {
        guard let t = txnPtr(txn) else { return [] }
        let name = Array(handle.name.utf8)
        var outLen = 0
        let ptr = name.withUnsafeBufferPointer { n in ytext_delta(t, n.baseAddress, n.count, &outLen) }
        let data = consumeBytes(ptr, outLen)
        guard let ops = try? JSONDecoder().decode([DeltaInsertDTO].self, from: data) else { return [] }
        return ops.compactMap { op in op.insert.map { .insert($0, attributes: op.attributes) } }
    }

    // MARK: Encoding & sync

    func encodeStateAsUpdate(in txn: YTransaction, since sv: StateVector?) -> Data {
        guard let t = txnPtr(txn) else { return Data() }
        var outLen = 0
        let ptr: UnsafeMutablePointer<UInt8>?
        if let sv {
            let svBytes = Array(sv.data)
            ptr = svBytes.withUnsafeBufferPointer {
                ytxn_state_as_update_v1(t, $0.baseAddress, $0.count, &outLen)
            }
        } else {
            ptr = ytxn_state_as_update_v1(t, nil, 0, &outLen)
        }
        return consumeBytes(ptr, outLen)
    }

    func encodeStateVector(in txn: YTransaction) -> StateVector {
        guard let t = txnPtr(txn) else { return StateVector(data: Data()) }
        var outLen = 0
        let ptr = ytxn_state_vector_v1(t, &outLen)
        return StateVector(data: consumeBytes(ptr, outLen))
    }

    func applyUpdate(in txn: YTransaction, _ update: Data, origin: Origin?) {
        guard let t = txnPtr(txn) else { return }
        let bytes = Array(update)
        _ = bytes.withUnsafeBufferPointer { ytxn_apply_update_v1(t, $0.baseAddress, $0.count) }
    }

    // MARK: Sticky index

    func stickyFromIndex(in txn: YTransaction, _ handle: TextHandle, index: Int, assoc: StickyIndex.Assoc) -> Data? {
        guard let t = txnPtr(txn) else { return nil }
        let name = Array(handle.name.utf8)
        let a: Int8 = assoc == .before ? -1 : 0
        var outLen = 0
        let ptr = name.withUnsafeBufferPointer { n in
            ysticky_from_index(t, n.baseAddress, n.count, UInt32(index), a, &outLen)
        }
        guard let ptr else { return nil }
        let data = consumeBytes(ptr, outLen)
        return data.isEmpty ? nil : data
    }

    func stickyToIndex(in txn: YTransaction, _ raw: Data) -> Int? {
        guard let t = txnPtr(txn) else { return nil }
        let bytes = Array(raw)
        let resolved = bytes.withUnsafeBufferPointer { ysticky_to_index(t, $0.baseAddress, $0.count) }
        return resolved < 0 ? nil : Int(resolved)
    }

    // MARK: Undo manager

    func makeUndoManager(_ handle: TextHandle, trackedOrigins: Set<Origin>, captureTimeoutMillis: UInt64) -> AnyObject? {
        let name = Array(handle.name.utf8)
        guard let ptr = name.withUnsafeBufferPointer({ n in yundo_new(doc, n.baseAddress, n.count, captureTimeoutMillis) }) else {
            return nil
        }
        for origin in trackedOrigins {
            let bytes = Array(origin.rawValue.utf8)
            bytes.withUnsafeBufferPointer { o in yundo_include_origin(ptr, o.baseAddress, o.count) }
        }
        return RawUndoManager(ptr)
    }

    func undoManagerUndo(_ mgr: AnyObject) -> Bool { (mgr as? RawUndoManager).map { yundo_undo($0.ptr) } ?? false }
    func undoManagerRedo(_ mgr: AnyObject) -> Bool { (mgr as? RawUndoManager).map { yundo_redo($0.ptr) } ?? false }
    func undoManagerCanUndo(_ mgr: AnyObject) -> Bool { (mgr as? RawUndoManager).map { yundo_can_undo($0.ptr) } ?? false }
    func undoManagerCanRedo(_ mgr: AnyObject) -> Bool { (mgr as? RawUndoManager).map { yundo_can_redo($0.ptr) } ?? false }
    func undoManagerStopCapturing(_ mgr: AnyObject) { _ = (mgr as? RawUndoManager).map { yundo_stop_capturing($0.ptr) } }

    // MARK: Observers

    func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription {
        let box = UpdateCallbackBox(callback)
        let userData = Unmanaged.passRetained(box).toOpaque()
        guard let sub = ydoc_observe_update_v1(doc, yrsUpdateTrampoline, userData) else {
            Unmanaged<UpdateCallbackBox>.fromOpaque(userData).release()
            return YSubscription {}
        }
        let handles = SubHandles(sub: sub, userData: userData)
        return YSubscription {
            ysubscription_free(handles.sub)
            Unmanaged<UpdateCallbackBox>.fromOpaque(handles.userData).release()
        }
    }

    func observeText(_ handle: TextHandle, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription {
        // Wired in a Phase-1 follow-up (needs yrs text observer + delta bridging).
        YSubscription {}
    }

    // MARK: Helpers

    private func txnPtr(_ txn: YTransaction) -> OpaquePointer? {
        (txn.raw as? RawTransaction)?.ptr
    }

    /// Copies a `cyrs`-owned buffer into `Data` and frees it.
    private func consumeBytes(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Data {
        guard let ptr else { return Data() }
        defer { ybytes_free(ptr, len) }
        return len > 0 ? Data(bytes: ptr, count: len) : Data()
    }

    private func attributesJSON(_ attrs: Attributes) -> [UInt8] {
        let object = attrs.mapValues(\.foundationJSON)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Array("{}".utf8)
        }
        return Array(data)
    }
}

/// Wire shape of one `toDelta` op (insert-only, as Yjs toDelta produces).
private struct DeltaInsertDTO: Decodable {
    let insert: YValue?
    let attributes: [String: YValue]?
}

private extension YValue {
    /// A `JSONSerialization`-compatible representation, for FFI attribute transport.
    var foundationJSON: Any {
        switch self {
        case .null, .undefined: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .data(let d): d.base64EncodedString()
        case .array(let a): a.map(\.foundationJSON)
        case .object(let o): o.mapValues(\.foundationJSON)
        }
    }
}
