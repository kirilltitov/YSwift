/// Selective undo/redo of changes on a text type (requirements §4.6).
///
/// Only edits whose transaction `origin` is in `trackedOrigins` are captured;
/// consecutive edits within `captureTimeout` merge into one undo step.
public final class UndoManager: Sendable {
    private let text: YText
    private let trackedOrigins: Set<Origin>
    private let captureTimeout: Duration

    public init(_ text: YText, trackedOrigins: Set<Origin> = [], captureTimeout: Duration = .milliseconds(500)) {
        self.text = text
        self.trackedOrigins = trackedOrigins
        self.captureTimeout = captureTimeout
    }

    public func undo() {
        fatalError("YSwift: UndoManager.undo is not implemented yet. See DECISIONS.md.")
    }

    public func redo() {
        fatalError("YSwift: UndoManager.redo is not implemented yet. See DECISIONS.md.")
    }

    /// Ensures the next change starts a new undo step (does not merge).
    public func stopCapturing() {
        fatalError("YSwift: UndoManager.stopCapturing is not implemented yet. See DECISIONS.md.")
    }

    public var canUndo: Bool {
        fatalError("YSwift: UndoManager.canUndo is not implemented yet. See DECISIONS.md.")
    }

    public var canRedo: Bool {
        fatalError("YSwift: UndoManager.canRedo is not implemented yet. See DECISIONS.md.")
    }
}
