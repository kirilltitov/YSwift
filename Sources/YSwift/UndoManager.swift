/// Selective undo/redo of changes on a text type (requirements §4.6).
///
/// Only edits whose transaction `origin` is in `trackedOrigins` are captured;
/// consecutive edits within `captureTimeout` merge into one undo step.
///
/// Not `Sendable`: it is a stateful controller tied to a single document, and
/// `undo`/`redo` open their own transaction (serialized against the document's
/// transactions via the document lock). Use it from one context.
public final class UndoManager {
    private let doc: YDoc
    private let handle: AnyObject?

    public init(_ text: YText, trackedOrigins: Set<Origin> = [], captureTimeout: Duration = .milliseconds(500)) {
        doc = text.doc
        let parts = captureTimeout.components
        let millis = UInt64(max(0, parts.seconds)) * 1000
            + UInt64(max(0, parts.attoseconds) / 1_000_000_000_000_000)
        handle = text.doc.performExclusively {
            text.doc.engine.makeUndoManager(text.handle, trackedOrigins: trackedOrigins, captureTimeoutMillis: millis)
        }
    }

    public func undo() {
        guard let handle else { return }
        _ = doc.performExclusively { doc.engine.undoManagerUndo(handle) }
    }

    public func redo() {
        guard let handle else { return }
        _ = doc.performExclusively { doc.engine.undoManagerRedo(handle) }
    }

    /// Ensures the next change starts a new undo step (does not merge).
    public func stopCapturing() {
        guard let handle else { return }
        doc.performExclusively { doc.engine.undoManagerStopCapturing(handle) }
    }

    public var canUndo: Bool {
        guard let handle else { return false }
        return doc.performExclusively { doc.engine.undoManagerCanUndo(handle) }
    }

    public var canRedo: Bool {
        guard let handle else { return false }
        return doc.performExclusively { doc.engine.undoManagerCanRedo(handle) }
    }
}
