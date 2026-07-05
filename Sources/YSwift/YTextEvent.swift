/// Describes a change to a `YText`, delivered to `observe` callbacks.
public struct YTextEvent: Sendable, Hashable {
    /// The change expressed as a Quill-style delta (retain / insert / delete).
    public let delta: [Delta]

    public init(delta: [Delta]) { self.delta = delta }
}
