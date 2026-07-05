import Synchronization

/// A cancellable token for an observer registration (`onUpdate`, `observe`,
/// `onChange`). Cancels automatically when released, or explicitly via `cancel()`.
public final class YSubscription: Sendable {
    private let state: Mutex<(@Sendable () -> Void)?>

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.state = Mutex(onCancel)
    }

    /// Cancels the subscription. Idempotent; safe to call more than once.
    public func cancel() {
        let handler = self.state.withLock { (h: inout (@Sendable () -> Void)?) -> (@Sendable () -> Void)? in
            defer { h = nil }
            return h
        }
        handler?()
    }

    deinit { self.cancel() }
}
