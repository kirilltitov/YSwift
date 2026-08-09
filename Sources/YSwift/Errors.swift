/// Errors surfaced by the public API. Backend-specific failures are mapped into
/// these so callers never see FFI or Rust details.
public enum YError: Error, Sendable, Hashable {
    /// An update failed structural validation or backend integration.
    case invalidUpdate
    /// A `YTransaction` was used outside the `transact` closure that created it.
    case transactionEscaped
    /// The backend engine failed; carries a human-readable reason.
    case engine(String)
}
