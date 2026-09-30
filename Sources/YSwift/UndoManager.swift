/// Selective undo/redo of changes on one or several text types (requirements §4.6).
///
/// Only edits whose transaction `origin` is in `trackedOrigins` are captured;
/// consecutive edits within `captureTimeout` merge into one undo step.
///
/// The scope is one text or several texts of the same document, like the type or array of types
/// a Yjs `UndoManager` is given. A transaction is captured when it changes any text of the scope
/// (or a type nested in one), and each `undo`/`redo` restores every text of the scope in one
/// transaction, emitting one update. A change that spans several texts is therefore undone as a
/// whole only by a manager whose scope covers them all; one manager per text sees and undoes only
/// its own part, in a transaction of its own.
///
/// Not `Sendable`: it is a stateful controller tied to a single document, and
/// `undo`/`redo` open their own transaction (serialized against the document's
/// transactions via the document lock). Use it from one context.
public final class UndoManager {
    private let doc: YDoc
    private let handle: AnyObject?

    /// A manager over the texts in `scope` (Yjs `new UndoManager([a, b])`). A text listed twice
    /// counts once, and the order of the texts does not change what an undo or redo writes.
    ///
    /// - Precondition: `scope` is not empty and all its texts belong to the same document.
    public init(_ scope: [YText], trackedOrigins: Set<Origin> = [], captureTimeout: Duration = .milliseconds(500)) {
        precondition(!scope.isEmpty, "an UndoManager needs at least one text in its scope")
        let doc = scope[0].doc
        precondition(scope.allSatisfy { $0.doc === doc }, "an UndoManager's texts must belong to one YDoc")
        self.doc = doc
        let parts = captureTimeout.components
        let millis =
            UInt64(max(0, parts.seconds)) * 1000
            + UInt64(max(0, parts.attoseconds) / 1_000_000_000_000_000)
        self.handle = doc.performExclusively {
            doc.engine.makeUndoManager(
                scope.map(\.handle),
                trackedOrigins: trackedOrigins,
                captureTimeoutMillis: millis,
            )
        }
    }

    /// A manager over one text; the same as `init([text], ...)`.
    public convenience init(
        _ text: YText,
        trackedOrigins: Set<Origin> = [],
        captureTimeout: Duration = .milliseconds(500),
    ) {
        self.init([text], trackedOrigins: trackedOrigins, captureTimeout: captureTimeout)
    }

    public func undo() {
        guard let handle = self.handle else { return }
        _ = self.doc.performExclusively { self.doc.engine.undoManagerUndo(handle) }
    }

    public func redo() {
        guard let handle = self.handle else { return }
        _ = self.doc.performExclusively { self.doc.engine.undoManagerRedo(handle) }
    }

    /// Ensures the next change starts a new undo step (does not merge).
    public func stopCapturing() {
        guard let handle = self.handle else { return }
        self.doc.performExclusively { self.doc.engine.undoManagerStopCapturing(handle) }
    }

    public var canUndo: Bool {
        guard let handle = self.handle else { return false }
        return self.doc.performExclusively { self.doc.engine.undoManagerCanUndo(handle) }
    }

    public var canRedo: Bool {
        guard let handle = self.handle else { return false }
        return self.doc.performExclusively { self.doc.engine.undoManagerCanRedo(handle) }
    }
}
