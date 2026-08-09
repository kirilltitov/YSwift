/// Errors surfaced by the public API. Internal engine failures are mapped into
/// these so callers only see stable YSwift error cases.
public enum YError: Error, Sendable, Hashable {
    /// An update failed structural validation or engine integration.
    case invalidUpdate
    /// A `YTransaction` was used outside the `transact` closure that created it.
    case transactionEscaped
    /// The backend engine failed; carries a human-readable reason.
    case engine(String)
}
