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

extension YValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([YValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: YValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null, .undefined: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .data(let d): try c.encode(d.base64EncodedString())
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
