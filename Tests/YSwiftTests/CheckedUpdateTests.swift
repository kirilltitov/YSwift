import Foundation
import Testing

@testable import YSwift

@Suite("checked v1 update ingress")
struct CheckedUpdateTests {
    private func doc(clientID: UInt64) -> YDoc {
        YDoc(clientID: clientID)
    }

    @Test("canonical empty, generated and duplicate updates are accepted")
    func acceptsValidUpdates() throws {
        let source = self.doc(clientID: 11)
        source.transact { transaction in
            source.text("content").insert(transaction, at: 0, "valid")
        }
        let update = source.transact { transaction in
            source.encodeStateAsUpdate(transaction)
        }

        let target = self.doc(clientID: 12)
        try target.transact { transaction in
            try target.applyUpdateChecked(transaction, Data([0, 0]))
            try target.applyUpdateChecked(transaction, update)
            try target.applyUpdateChecked(transaction, update)
        }

        #expect(
            target.transact { transaction in
                target.text("content").string(transaction)
            } == "valid")
    }

    @Test("clocks above the supported UInt32 range are rejected without divergence")
    func rejectsClockAboveUInt32() throws {
        let target = self.doc(clientID: 13)
        let initialState = target.transact { target.encodeStateAsUpdate($0) }

        do {
            try target.transact { transaction in
                try target.applyUpdateChecked(transaction, Self.updateAboveUInt32Clock())
            }
            Issue.record("native implementation must reject clocks above UInt32")
        } catch let error as YError {
            #expect(error == .invalidUpdate)
        }
        #expect(target.transact { target.encodeStateAsUpdate($0) } == initialState)
    }

    @Test("structural validation accepts canonical boundary values")
    func acceptsCanonicalBoundaries() throws {
        try YUpdate.validateV1(Self.contentJSONUndefinedUpdate())
        try YUpdate.validateV1(
            Self.gcUpdate(firstClock: UInt64(UInt32.max) - 1, length: 1)
        )
    }

    @Test("JSON syntax matches JSON.parse without materialising UTF-16 escapes")
    func validatesJSONSyntax() throws {
        let valid = [
            "null", " true\n", "0", "-0", "1.25e-2", "[]", "{}",
            "{\"a\":[true,false,null,\"\\ud800\"]}",
            String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64),
        ]
        for value in valid {
            var validator = JSONSyntaxValidator(value)
            try validator.validate()
        }

        let invalid = [
            "", "\u{feff}{}", "{\"x\":1,}", "[1,]", "01", "+1", ".1", "1.", "1e",
            "\"\\x00\"", "\"\u{0001}\"",
            String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65),
        ]
        for value in invalid {
            do {
                var validator = JSONSyntaxValidator(value)
                try validator.validate()
                Issue.record("JSON must be rejected: \(value.debugDescription)")
            } catch {
                // Expected.
            }
        }
    }

    @Test("a yjs lone-surrogate JSON embed validates and Native preserves its bytes")
    func acceptsYjsLoneSurrogateJSON() throws {
        let update = Self.contentEmbedUpdate("{\"x\":\"\\ud800\"}")
        #expect(
            update
                == Data([
                    1, 1, 1, 0, 5, 1, 1, 116, 14, 123, 34, 120, 34, 58, 34, 92, 117, 100,
                    56, 48, 48, 34, 125, 0,
                ]))
        try YUpdate.validateV1(update)

        let native = self.doc(clientID: 14)
        try native.transact { try native.applyUpdateChecked($0, update) }
        #expect(native.transact { native.encodeStateAsUpdate($0) } == update)
    }

    @Test("unique nested Any object keys remain valid")
    func acceptsUniqueAnyObjectKeys() throws {
        var object: [UInt8] = [118, 2]
        object += Self.varString("first") + [125, 1]
        object += Self.varString("nested") + [117, 1, 118, 1]
        object += Self.varString("second") + [120]
        try YUpdate.validateV1(Self.contentAnyUpdate(object))
    }

    @Test("malformed wire throws before the document mutates")
    func rejectsMalformedWireWithoutMutation() throws {
        let target = self.doc(clientID: 20)
        let initialState = target.transact { transaction in
            target.encodeStateAsUpdate(transaction)
        }

        for malformed in Self.malformedUpdates() {
            do {
                try target.transact { transaction in
                    try target.applyUpdateChecked(transaction, malformed.bytes)
                }
                Issue.record("\(malformed.name) must throw")
            } catch let error as YError {
                #expect(error == .invalidUpdate, "\(malformed.name)")
            } catch {
                Issue.record("\(malformed.name): unexpected \(error)")
            }

            let currentState = target.transact { transaction in
                target.encodeStateAsUpdate(transaction)
            }
            #expect(currentState == initialState, "\(malformed.name) mutated")
        }
    }

    private static func malformedUpdates() -> [(name: String, bytes: Data)] {
        var clientOverflow: [UInt8] = [1, 1]
        clientOverflow += Self.varUint((UInt64(1) << 53))
        clientOverflow += [0, 0, 1, 0]

        var idClockOverflow: [UInt8] = [1, 1, 1, 0, 0x84]
        idClockOverflow += Self.varUint(2)
        idClockOverflow += Self.varUint(UInt64(UInt32.max) + 1)
        idClockOverflow += Self.varString("x")
        idClockOverflow += [0]

        var duplicateAnyObject: [UInt8] = [118, 2]
        duplicateAnyObject += Self.varString("x") + [125, 1]
        duplicateAnyObject += Self.varString("x") + [125, 2]

        var nestedDuplicateAnyObject: [UInt8] = [118, 1]
        nestedDuplicateAnyObject += Self.varString("outer") + [117, 1]
        nestedDuplicateAnyObject += duplicateAnyObject

        var protoAnyObject: [UInt8] = [118, 1]
        protoAnyObject += Self.varString("__proto__") + [126]

        let nestedProtoAnyObject: [UInt8] = [117, 1] + protoAnyObject

        return [
            ("empty-buffer", Data()),
            ("truncated-delete-set", Data([0])),
            ("trailing-byte", Data([0, 0, 0xff])),
            ("noncanonical-varint", Data([0x80, 0x00, 0x00])),
            ("unterminated-varint", Data(repeating: 0xff, count: 10)),
            ("declared-count-exceeds-buffer", Data([0x7f, 0x00])),
            ("client-id-outside-yjs-range", Data(clientOverflow)),
            ("struct-clock-end-overflow", Self.gcUpdate(firstClock: UInt64(UInt32.max), length: 1)),
            ("struct-length-outside-supported-range", Self.gcUpdate(firstClock: 0, length: UInt64(UInt32.max) + 1)),
            ("id-clock-outside-supported-range", Data(idClockOverflow)),
            ("zero-length-gc", Data([1, 1, 1, 0, 0, 0, 0])),
            ("zero-length-skip", Data([1, 1, 1, 0, 10, 0, 0])),
            ("zero-length-content-deleted", Data([1, 1, 1, 0, 1, 1, 1, 0x74, 0, 0])),
            ("zero-length-content-string", Data([1, 1, 1, 0, 4, 1, 1, 0x74, 0, 0])),
            ("zero-length-delete-range", Self.deleteSetUpdate(client: 42, clock: 0, length: 0)),
            (
                "delete-clock-outside-supported-range",
                Self.deleteSetUpdate(client: 42, clock: UInt64(UInt32.max) + 1, length: 1)
            ),
            (
                "delete-range-end-overflow",
                Self.deleteSetUpdate(client: 42, clock: UInt64(UInt32.max), length: 1)
            ),
            ("flagged-skip-control-byte", Data([1, 1, 1, 0, 0x8a, 1, 0])),
            ("invalid-content-json", Data([1, 1, 1, 0, 2, 1, 1, 0x74, 1, 1, 0x78, 0])),
            ("invalid-content-embed", Data([1, 1, 1, 0, 5, 1, 1, 0x74, 1, 0x78, 0])),
            ("invalid-content-format", Data([1, 1, 1, 0, 6, 1, 1, 0x74, 1, 0x6b, 1, 0x78, 0])),
            ("content-embed-trailing-comma", Self.contentEmbedUpdate("{\"x\":1,}")),
            ("content-embed-leading-bom", Self.contentEmbedUpdate("\u{feff}{}")),
            ("duplicate-any-object-key", Self.contentAnyUpdate(duplicateAnyObject)),
            ("nested-duplicate-any-object-key", Self.contentAnyUpdate(nestedDuplicateAnyObject)),
            ("reserved-any-proto-key", Self.contentAnyUpdate(protoAnyObject)),
            ("nested-reserved-any-proto-key", Self.contentAnyUpdate(nestedProtoAnyObject)),
            ("unknown-content-ref", Data([1, 1, 1, 0, 11, 1, 1, 0x74, 0])),
            ("invalid-utf8", Data([1, 1, 1, 0, 4, 1, 1, 0xff, 1, 0x61, 0])),
        ]
    }

    private static func updateAboveUInt32Clock() -> Data {
        Self.gcUpdate(firstClock: UInt64(UInt32.max) + 1, length: 1)
    }

    private static func contentJSONUndefinedUpdate() -> Data {
        Self.contentItemUpdate(ref: 2, payload: [1] + Self.varString("undefined"))
    }

    private static func contentEmbedUpdate(_ json: String) -> Data {
        Self.contentItemUpdate(ref: 5, payload: Self.varString(json))
    }

    private static func contentAnyUpdate(_ encodedAny: [UInt8]) -> Data {
        Self.contentItemUpdate(ref: 8, payload: [1] + encodedAny, root: "a")
    }

    private static func contentItemUpdate(
        ref: UInt8, payload: [UInt8], root: String = "t"
    ) -> Data {
        var bytes: [UInt8] = [1, 1, 1, 0, ref, 1]
        bytes += Self.varString(root)
        bytes += payload
        bytes += [0]
        return Data(bytes)
    }

    private static func gcUpdate(firstClock: UInt64, length: UInt64) -> Data {
        var bytes: [UInt8] = [1, 1, 1]
        bytes += Self.varUint(firstClock)
        bytes += [0]
        bytes += Self.varUint(length)
        bytes += [0]
        return Data(bytes)
    }

    private static func deleteSetUpdate(client: UInt64, clock: UInt64, length: UInt64) -> Data {
        var bytes: [UInt8] = [0, 1]
        bytes += Self.varUint(client)
        bytes += [1]
        bytes += Self.varUint(clock)
        bytes += Self.varUint(length)
        return Data(bytes)
    }

    private static func varString(_ value: String) -> [UInt8] {
        let utf8 = Array(value.utf8)
        return Self.varUint(UInt64(utf8.count)) + utf8
    }

    private static func varUint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
}
