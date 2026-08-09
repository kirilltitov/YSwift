/// Identifies the source of a transaction.
///
/// Used to distinguish local from remote changes (echo-loop prevention,
/// requirements §9.3) and to scope `UndoManager` via tracked origins. Set it
/// when opening `YDoc.transact(origin:_:)`; an update method cannot retag an
/// already-open transaction.
public struct Origin: Sendable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension Origin: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension Origin: CustomStringConvertible {
    public var description: String { self.rawValue }
}
