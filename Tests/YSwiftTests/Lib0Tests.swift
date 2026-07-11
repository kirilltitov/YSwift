import Foundation
import Testing

@testable import YSwift

// Mirrors fixtures/lib0-vectors.mjs output.
private struct Lib0Vectors: Decodable {
    struct VarUintVec: Decodable {
        let u: UInt64
        let bytes: [UInt8]
    }
    struct VarIntVec: Decodable {
        let i: Int64
        let bytes: [UInt8]
    }
    struct VarStringVec: Decodable {
        let s: String
        let bytes: [UInt8]
    }
    struct AnyVec: Decodable {
        let y: TaggedAny
        let bytes: [UInt8]
    }

    let varUint: [VarUintVec]
    let varInt: [VarIntVec]
    let varString: [VarStringVec]
    let any: [AnyVec]
}

/// The tagged `any` value from the generator, decoded into a `Lib0Any`.
private struct TaggedAny: Decodable {
    let value: Lib0Any
    /// `-0` decodes to `+0` in Swift (no signed integer zero), so its re-encode
    /// is not byte-stable — the test skips that one round-trip check.
    let isNegativeZero: Bool

    private enum CodingKeys: String, CodingKey { case t, v, entries }
    private struct Entry: Decodable {
        let k: String
        let v: TaggedAny
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .t)
        self.isNegativeZero = tag == "negzero"
        switch tag {
        case "null": self.value = .null
        case "undefined": self.value = .undefined
        case "bool": self.value = .bool(try container.decode(Bool.self, forKey: .v))
        case "int": self.value = .number(Double(try container.decode(Int64.self, forKey: .v)))
        case "double": self.value = .number(try container.decode(Double.self, forKey: .v))
        case "negzero": self.value = .number(-0.0)
        case "nan": self.value = .number(.nan)
        case "inf": self.value = .number(.infinity)
        case "ninf": self.value = .number(-.infinity)
        case "string": self.value = .string(try container.decode(String.self, forKey: .v))
        case "bytes": self.value = .bytes(try container.decode([UInt8].self, forKey: .v))
        case "array": self.value = .array(try container.decode([TaggedAny].self, forKey: .v).map(\.value))
        case "object":
            let entries = try container.decode([Entry].self, forKey: .entries)
            self.value = .object(entries.map { ($0.k, $0.v.value) })
        default:
            throw DecodingError.dataCorruptedError(forKey: .t, in: container, debugDescription: "unknown tag \(tag)")
        }
    }
}

@Suite("lib0 v1 codec")
struct Lib0CodecTests {
    private static func vectors() throws -> Lib0Vectors {
        let url = try #require(
            Bundle.module.url(forResource: "lib0_v1_vectors", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(Lib0Vectors.self, from: Data(contentsOf: url))
    }

    @Test("varUint encodes byte-exactly and round-trips")
    func varUint() throws {
        for vec in try Self.vectors().varUint {
            var encoder = Lib0Encoder()
            encoder.writeVarUint(vec.u)
            #expect(encoder.bytes == vec.bytes, "encode \(vec.u)")
            var decoder = Lib0Decoder(vec.bytes)
            #expect(try decoder.readVarUint() == vec.u, "decode \(vec.u)")
        }
    }

    @Test("varInt encodes byte-exactly and round-trips")
    func varInt() throws {
        for vec in try Self.vectors().varInt {
            var encoder = Lib0Encoder()
            encoder.writeVarInt(vec.i)
            #expect(encoder.bytes == vec.bytes, "encode \(vec.i)")
            var decoder = Lib0Decoder(vec.bytes)
            #expect(try decoder.readVarInt() == vec.i, "decode \(vec.i)")
        }
    }

    @Test("varString encodes byte-exactly and round-trips")
    func varString() throws {
        for vec in try Self.vectors().varString {
            var encoder = Lib0Encoder()
            encoder.writeVarString(vec.s)
            #expect(encoder.bytes == vec.bytes, "encode \(vec.s.debugDescription)")
            var decoder = Lib0Decoder(vec.bytes)
            #expect(try decoder.readVarString() == vec.s, "decode \(vec.s.debugDescription)")
        }
    }

    @Test("writeAny matches lib0 bytes; decode re-encodes stably")
    func writeAny() throws {
        for vec in try Self.vectors().any {
            var encoder = Lib0Encoder()
            encoder.writeAny(vec.y.value)
            #expect(encoder.bytes == vec.bytes, "encode \(vec.bytes)")

            if !vec.y.isNegativeZero {
                var decoder = Lib0Decoder(vec.bytes)
                let decoded = try decoder.readAny()
                var reencoder = Lib0Encoder()
                reencoder.writeAny(decoded)
                #expect(reencoder.bytes == vec.bytes, "re-encode \(vec.bytes)")
            }
        }
    }
}
