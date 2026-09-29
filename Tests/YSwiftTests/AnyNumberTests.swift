import Foundation
import Testing

@testable import YSwift

@Suite("any numbers from the wire")
struct AnyNumberTests {
    /// Root array `content` of client 5 holding one any value given by its lib0 bytes.
    private static func update(_ value: [UInt8]) -> Data {
        Data([1, 1, 5, 0, 0x08, 1, 7] + Array("content".utf8) + [1] + value + [0])
    }

    private static func state(after value: [UInt8]) throws -> Data {
        let doc = YDoc(clientID: 999)
        try doc.transact { try doc.applyUpdateChecked($0, Self.update(value)) }
        return doc.transact { doc.encodeStateAsUpdate($0) }
    }

    @Test(
        "every NaN is written as the quiet NaN",
        arguments: [
            [0x7b, 0x7f, 0xf0, 0, 0, 0, 0, 0, 1],  // signalling
            [0x7b, 0xff, 0xf8, 0, 0, 0, 0, 0, 0],  // negative
            [0x7b, 0x7f, 0xf8, 0, 0, 0, 0, 0, 1],  // quiet, with a payload
            [0x7c, 0x7f, 0xc0, 0, 1],  // float32
        ] as [[UInt8]]
    )
    func writesTheQuietNaN(value: [UInt8]) throws {
        // Yjs 13.6.31 writes back what the engine's DataView gives it: WebKit (JSC) always the quiet NaN
        // 7ff8000000000000, V8 that too for a signalling NaN but otherwise the bits it read, a float32
        // NaN widened, and not always the same way. YSwift writes the one NaN every engine can produce.
        #expect(try Self.state(after: value) == Self.update([0x7b, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0]))
    }

    @Test(
        "negative zero keeps its sign",
        arguments: [[0x7d, 0x40], [0x7c, 0x80, 0, 0, 0], [0x7b, 0x80, 0, 0, 0, 0, 0, 0, 0]] as [[UInt8]]
    )
    func keepsNegativeZero(value: [UInt8]) throws {
        // Yjs 13.6.31 in Node, Chromium and WebKit: -0 is written as the varint 0x40.
        #expect(try Self.state(after: value) == Self.update([0x7d, 0x40]))
    }
}
