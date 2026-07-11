#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Converts between the public `YValue` and the internal `Lib0Any`. JS has a single
/// numeric type, so `Int`/`Double` both map to `Lib0Any.number` and the wire
/// encoder picks the compact representation from the value.
enum ValueBridge {
    static func lib0(_ value: YValue) -> Lib0Any {
        switch value {
        case .null: .null
        case .undefined: .undefined
        case .bool(let flag): .bool(flag)
        case .int(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .string(let text): .string(text)
        case .data(let bytes): .bytes(Array(bytes))
        case .array(let items): .array(items.map(Self.lib0))
        case .object(let fields): .object(fields.map { (key: $0.key, value: Self.lib0($0.value)) })
        }
    }

    static func yValue(_ any: Lib0Any) -> YValue {
        switch any {
        case .undefined: .undefined
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number):
            number == number.rounded(.towardZero) && abs(number) < 9_007_199_254_740_992
                ? .int(Int64(number)) : .double(number)
        case .bigInt(let number): .int(number)
        case .string(let text): .string(text)
        case .bytes(let bytes): .data(Data(bytes))
        case .array(let items): .array(items.map(Self.yValue))
        case .object(let pairs):
            .object(Dictionary(pairs.map { ($0.key, Self.yValue($0.value)) }) { first, _ in first })
        }
    }
}
