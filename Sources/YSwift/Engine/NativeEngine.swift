#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Default engine: the pure-Swift YATA + `lib0` implementation behind `YEngine`.
/// Wraps a `NativeDoc` and is differentially checked against Yjs/`YrsEngine`.
///
/// `@unchecked Sendable` under the same invariant as `YrsEngine`: the owning
/// `YDoc`'s `Mutex` serialises every call, so the mutable `NativeDoc` is never
/// touched concurrently.
///
final class NativeEngine: YEngine, @unchecked Sendable {
    let doc: NativeDoc
    var clientID: UInt64 { self.doc.clientID }

    init(clientID: UInt64?, gc: Bool) {
        // v13 uses 32-bit client ids; match that for the random case.
        let resolved = clientID ?? UInt64.random(in: 0..<(UInt64(1) << 32))
        self.doc = NativeDoc(clientID: resolved, gc: gc)
    }

    // MARK: Handles & transactions

    func textHandle(_ name: String) -> TextHandle {
        _ = self.doc.get(name)
        return TextHandle(name: name)
    }

    func beginTransaction(origin: Origin?, writable: Bool) -> YTransaction {
        self.doc.beginTransaction(origin: origin)
        return YTransaction(engine: self, origin: origin, writable: writable, raw: nil)
    }

    func endTransaction(_ txn: YTransaction) {
        self.doc.commitTransaction()
    }

    // MARK: Text operations

    func textInsert(
        in txn: YTransaction, _ handle: TextHandle, at index: Int, _ string: String, attributes: Attributes?
    ) {
        self.doc.text(handle.name).insert(index, string, attributes: attributes.map(Self.lib0Attributes))
    }

    func textDelete(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int) {
        self.doc.text(handle.name).delete(index, length)
    }

    func textFormat(in txn: YTransaction, _ handle: TextHandle, at index: Int, length: Int, attributes: Attributes) {
        self.doc.text(handle.name).format(index, length, attributes: Self.lib0Attributes(attributes))
    }

    func textString(in txn: YTransaction, _ handle: TextHandle) -> String {
        self.doc.getText(handle.name)
    }

    func textLength(in txn: YTransaction, _ handle: TextHandle) -> Int {
        self.doc.text(handle.name).length
    }

    func textDelta(in txn: YTransaction, _ handle: TextHandle) -> [Delta] {
        .decodeDelta(from: Data(self.doc.text(handle.name).toDeltaJSON().utf8))
    }

    // MARK: Encoding & sync

    func encodeStateAsUpdate(in txn: YTransaction, since sv: StateVector?) -> Data {
        let target = (sv.flatMap { try? NativeDoc.decodeStateVector(Array($0.data)) }) ?? [:]
        return Data(self.doc.encodeStateAsUpdate(target: target))
    }

    func encodeStateVector(in txn: YTransaction) -> StateVector {
        StateVector(data: Data(self.doc.encodeStateVector()))
    }

    func applyUpdate(in txn: YTransaction, _ update: Data, origin: Origin?) throws {
        // Origin belongs to the enclosing transaction (set at beginTransaction),
        // as in yjs; this source-compatible method argument cannot retag it.
        do {
            try self.doc.applyUpdate(Array(update))
        } catch {
            throw YError.invalidUpdate
        }
    }

    // MARK: Sticky index

    func stickyFromIndex(in txn: YTransaction, _ handle: TextHandle, index: Int, assoc: StickyIndex.Assoc) -> Data? {
        let position = self.doc.text(handle.name).stickyIndex(at: index, assoc: assoc == .before ? -1 : 0)
        return Data(position.encode())
    }

    func stickyToIndex(in txn: YTransaction, _ raw: Data) -> Int? {
        guard let position = try? NativeRelativePosition.decode(Array(raw)) else { return nil }
        return self.doc.resolve(position)?.index
    }

    // MARK: Observers

    func onUpdate(_ callback: @escaping @Sendable (Data, Origin?) -> Void) -> YSubscription {
        let id = self.doc.onUpdate { bytes, origin in callback(Data(bytes), origin) }
        return YSubscription { [weak self] in self?.doc.removeUpdateHandler(id) }
    }

    func observeText(_ handle: TextHandle, _ callback: @escaping @Sendable (YTextEvent) -> Void) -> YSubscription {
        _ = self.doc.get(handle.name)
        let id = self.doc.observeText(handle.name, callback)
        let name = handle.name
        return YSubscription { [weak self] in self?.doc.removeTextObserver(name, id) }
    }

    // MARK: Undo manager & awareness

    func makeUndoManager(_ handle: TextHandle, trackedOrigins: Set<Origin>, captureTimeoutMillis: UInt64) -> AnyObject?
    {
        _ = self.doc.get(handle.name)
        return NativeUndoManager(
            doc: self.doc, typeName: handle.name, trackedOrigins: trackedOrigins,
            captureTimeoutMillis: captureTimeoutMillis)
    }
    func undoManagerUndo(_ mgr: AnyObject) -> Bool { (mgr as? NativeUndoManager)?.undo() ?? false }
    func undoManagerRedo(_ mgr: AnyObject) -> Bool { (mgr as? NativeUndoManager)?.redo() ?? false }
    func undoManagerCanUndo(_ mgr: AnyObject) -> Bool { (mgr as? NativeUndoManager)?.canUndo ?? false }
    func undoManagerCanRedo(_ mgr: AnyObject) -> Bool { (mgr as? NativeUndoManager)?.canRedo ?? false }
    func undoManagerStopCapturing(_ mgr: AnyObject) { (mgr as? NativeUndoManager)?.stopCapturing() }

    func makeAwareness() -> AnyObject? { NativeAwareness(clientID: self.doc.clientID) }

    private func awareness(_ aw: AnyObject) -> NativeAwareness? { aw as? NativeAwareness }

    func awarenessSetLocalState(_ aw: AnyObject, json: Data) {
        self.awareness(aw)?.setLocalState(String(decoding: json, as: UTF8.self))
    }
    func awarenessCleanLocalState(_ aw: AnyObject) { self.awareness(aw)?.cleanLocalState() }
    func awarenessRemoveState(_ aw: AnyObject, client: UInt64) { self.awareness(aw)?.removeState(client) }
    func awarenessStates(_ aw: AnyObject) -> Data { self.awareness(aw).map { Data($0.statesJSON()) } ?? Data() }
    func awarenessEncodeUpdate(_ aw: AnyObject, clients: [UInt64]?) -> Data {
        self.awareness(aw).map { Data($0.encodeUpdate(clients: clients)) } ?? Data()
    }
    func awarenessApplyUpdate(_ aw: AnyObject, _ update: Data) -> Bool {
        self.awareness(aw)?.applyUpdate(Array(update)) ?? false
    }
    func awarenessOnChange(_ aw: AnyObject, _ callback: @escaping @Sendable (Awareness.Change) -> Void) -> YSubscription
    {
        guard let awareness = self.awareness(aw) else { return YSubscription {} }
        let id = awareness.onChange(callback)
        return YSubscription { awareness.removeOnChange(id) }
    }

    // MARK: Containers

    func arrayInsert(in txn: YTransaction, _ name: String, at index: Int, _ values: [YValue]) {
        self.doc.array(name).insert(index, values.map(ValueBridge.lib0))
    }
    func arrayDelete(in txn: YTransaction, _ name: String, at index: Int, count: Int) {
        self.doc.array(name).delete(index, count)
    }
    func arrayLength(in txn: YTransaction, _ name: String) -> Int { self.doc.array(name).length }
    func arrayValues(in txn: YTransaction, _ name: String) -> [YValue] {
        self.doc.array(name).toArray().map(ValueBridge.yValue)
    }

    func mapSet(in txn: YTransaction, _ name: String, _ key: String, _ value: YValue) {
        self.doc.map(name).set(key, ValueBridge.lib0(value))
    }
    func mapDelete(in txn: YTransaction, _ name: String, _ key: String) {
        self.doc.map(name).delete(key)
    }
    func mapGet(in txn: YTransaction, _ name: String, _ key: String) -> YValue? {
        self.doc.map(name).get(key).map(ValueBridge.yValue)
    }
    func mapKeys(in txn: YTransaction, _ name: String) -> [String] {
        self.doc.map(name).keys()
    }
    func mapToDictionary(in txn: YTransaction, _ name: String) -> [String: YValue] {
        self.doc.map(name).toDictionary().mapValues(ValueBridge.yValue)
    }

    func xmlInsert(in txn: YTransaction, _ name: String, at index: Int, _ nodes: [YXmlNode]) {
        let type = self.doc.get(name)
        self.doc.transact { NativeXml(doc: self.doc).insert(into: type, at: index, nodes.map(Self.xmlNode)) }
    }
    func xmlString(in txn: YTransaction, _ name: String) -> String {
        NativeXml(doc: self.doc).string(of: self.doc.get(name))
    }

    private static func xmlNode(_ node: YXmlNode) -> XmlNode {
        switch node {
        case .text(let string): .text(string)
        case .element(let tag, let attributes, let children):
            .element(
                tag: tag,
                attributes: attributes.map { (key: $0.key, value: ValueBridge.lib0($0.value)) },
                children: children.map(Self.xmlNode))
        }
    }

    func destroy() {}

    // MARK: Helpers

    private static func lib0Attributes(_ attributes: Attributes) -> [String: Lib0Any] {
        attributes.mapValues(Self.lib0)
    }

    private static func lib0(_ value: YValue) -> Lib0Any {
        switch value {
        case .null: .null
        case .undefined: .undefined
        case .bool(let flag): .bool(flag)
        case .int(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .string(let text): .string(text)
        case .data(let bytes): .bytes(Array(bytes))
        case .array(let items): .array(items.map(Self.lib0))
        case .object(let pairs): .object(pairs.map { (key: $0.key, value: Self.lib0($0.value)) })
        }
    }
}
