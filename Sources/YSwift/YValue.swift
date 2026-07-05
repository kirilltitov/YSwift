#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A JSON-like dynamic value, mirroring Yjs / `lib0` `any`. Used for text
/// formatting attributes and embedded content.
///
/// `Sendable` (unlike `Any`) so it crosses isolation boundaries safely under the
/// concurrency model. A typed model is also required to reproduce `lib0`'s
/// byte-exact `any` encoding in Phase 2.
public enum YValue: Sendable, Hashable {
    case null
    /// JS `undefined` — distinct from `null` (`lib0` encodes them differently).
    case undefined
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case array([YValue])
    case object([String: YValue])
}

/// Formatting attributes attached to a text range or delta operation.
public typealias Attributes = [String: YValue]

extension YValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension YValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension YValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension YValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension YValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension YValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: YValue...) { self = .array(elements) }
}

extension YValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, YValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
