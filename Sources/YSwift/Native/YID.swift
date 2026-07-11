/// A Yjs struct identifier: `(client, clock)` — a Lamport timestamp.
struct YID: Hashable, Sendable {
    let client: UInt64
    let clock: UInt64
}
