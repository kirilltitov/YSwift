#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The set of `client -> clock` pairs known to a document, encoded in the Yjs
/// wire format.
///
/// A distinct type (rather than raw `Data`) so a state vector and an update
/// payload cannot be accidentally interchanged.
public struct StateVector: Sendable, Hashable {
    public let data: Data

    public init(data: Data) { self.data = data }
}
