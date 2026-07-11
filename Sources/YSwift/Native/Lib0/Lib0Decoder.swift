enum Lib0DecodingError: Error, Sendable {
    case endOfBuffer
    case invalidAnyTag(UInt8)
    case integerOverflow
}

/// Byte-exact `lib0` v1 decoder over a `[UInt8]` buffer. Mirror of `Lib0Encoder`.
struct Lib0Decoder {
    private let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.position = 0
    }

    var hasRemaining: Bool { self.position < self.bytes.count }

    mutating func readUInt8() throws -> UInt8 {
        guard self.position < self.bytes.count else { throw Lib0DecodingError.endOfBuffer }
        defer { self.position += 1 }
        return self.bytes[self.position]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, self.position + count <= self.bytes.count else { throw Lib0DecodingError.endOfBuffer }
        defer { self.position += count }
        return Array(self.bytes[self.position..<self.position + count])
    }

    mutating func readVarUint() throws -> UInt64 {
        var num: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try self.readUInt8()
            num |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return num }
            shift += 7
            if shift >= 64 { throw Lib0DecodingError.integerOverflow }
        }
    }

    mutating func readVarInt() throws -> Int64 {
        let first = try self.readUInt8()
        let isNegative = (first & 0x40) != 0
        var num = UInt64(first & 0x3F)
        var shift: UInt64 = 6
        if first & 0x80 != 0 {
            while true {
                let byte = try self.readUInt8()
                num |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { break }
                shift += 7
                if shift >= 64 { throw Lib0DecodingError.integerOverflow }
            }
        }
        return isNegative ? -Int64(num) : Int64(num)
    }

    mutating func readVarString() throws -> String {
        String(decoding: try self.readVarUint8Array(), as: UTF8.self)
    }

    mutating func readVarUint8Array() throws -> [UInt8] {
        try self.readBytes(Int(try self.readVarUint()))
    }

    mutating func readFloat32() throws -> Float {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try self.readUInt8()) }
        return Float(bitPattern: value)
    }

    mutating func readFloat64() throws -> Double {
        Double(bitPattern: try self.readUInt64BE())
    }

    mutating func readBigInt64() throws -> Int64 {
        Int64(bitPattern: try self.readUInt64BE())
    }

    mutating func readAny() throws -> Lib0Any {
        let tag = try self.readUInt8()
        switch tag {
        case 127: return .undefined
        case 126: return .null
        case 125: return .number(Double(try self.readVarInt()))
        case 124: return .number(Double(try self.readFloat32()))
        case 123: return .number(try self.readFloat64())
        case 122: return .bigInt(try self.readBigInt64())
        case 121: return .bool(false)
        case 120: return .bool(true)
        case 119: return .string(try self.readVarString())
        case 118:
            let count = try self.readVarUint()
            var pairs: [(key: String, value: Lib0Any)] = []
            pairs.reserveCapacity(Int(count))
            for _ in 0..<count {
                let key = try self.readVarString()
                pairs.append((key, try self.readAny()))
            }
            return .object(pairs)
        case 117:
            let count = try self.readVarUint()
            var elements: [Lib0Any] = []
            elements.reserveCapacity(Int(count))
            for _ in 0..<count { elements.append(try self.readAny()) }
            return .array(elements)
        case 116: return .bytes(try self.readVarUint8Array())
        default: throw Lib0DecodingError.invalidAnyTag(tag)
        }
    }

    private mutating func readUInt64BE() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(try self.readUInt8()) }
        return value
    }
}
