/// Mirrors lib0's dynamic `any` value model used by the native `writeAny` /
/// `readAny`.
///
/// A single `.number(Double)` case mirrors JS's one numeric type — the
/// int / float32 / float64 wire choice is derived from the value at encode time,
/// not stored. Object keys are **ordered**: byte-exact encoding depends on the
/// order they were written.
enum Lib0Any: Sendable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case bigInt(Int64)
    case string(String)
    case bytes([UInt8])
    case array([Lib0Any])
    case object([(key: String, value: Lib0Any)])
}
