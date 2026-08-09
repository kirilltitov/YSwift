enum Lib0DecodingError: Error, Sendable {
    case endOfBuffer
    case invalidAnyTag(UInt8)
    case invalidCount
    case invalidUTF8
    case invalidValue
    case integerOverflow
    case nestingLimitExceeded
    case nonCanonicalVarInt
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
    var remainingByteCount: Int { self.bytes.count - self.position }

    mutating func readUInt8() throws -> UInt8 {
        guard self.position < self.bytes.count else { throw Lib0DecodingError.endOfBuffer }
        defer { self.position += 1 }
        return self.bytes[self.position]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= self.remainingByteCount else {
            throw Lib0DecodingError.endOfBuffer
        }
        defer { self.position += count }
        return Array(self.bytes[self.position..<self.position + count])
    }

    mutating func readVarUint() throws -> UInt64 {
        var num: UInt64 = 0
        var shift = 0
        while true {
            let byte = try self.readUInt8()
            let payload = UInt64(byte & 0x7F)
            guard shift < UInt64.bitWidth, payload <= UInt64.max >> shift else {
                throw Lib0DecodingError.integerOverflow
            }
            num |= payload << shift
            if byte < 0x80 {
                guard shift == 0 || payload != 0 else {
                    throw Lib0DecodingError.nonCanonicalVarInt
                }
                return num
            }
            shift += 7
            guard shift < UInt64.bitWidth else { throw Lib0DecodingError.integerOverflow }
        }
    }

    mutating func readVarInt() throws -> Int64 {
        let first = try self.readUInt8()
        let isNegative = (first & 0x40) != 0
        var num = UInt64(first & 0x3F)
        var shift = 6
        var finalPayload = num
        if first & 0x80 != 0 {
            while true {
                let byte = try self.readUInt8()
                let payload = UInt64(byte & 0x7F)
                guard shift < UInt64.bitWidth, payload <= UInt64.max >> shift else {
                    throw Lib0DecodingError.integerOverflow
                }
                num |= payload << shift
                finalPayload = payload
                if byte < 0x80 { break }
                shift += 7
                guard shift < UInt64.bitWidth else { throw Lib0DecodingError.integerOverflow }
            }
            guard finalPayload != 0 else { throw Lib0DecodingError.nonCanonicalVarInt }
        }
        let negativeLimit = UInt64(Int64.max) + 1
        if isNegative {
            guard num <= negativeLimit else { throw Lib0DecodingError.integerOverflow }
            return num == negativeLimit ? Int64.min : -Int64(num)
        }
        guard num <= UInt64(Int64.max) else { throw Lib0DecodingError.integerOverflow }
        return Int64(num)
    }

    mutating func readVarString() throws -> String {
        let bytes = try self.readVarUint8Array()
        guard let value = String(validating: bytes, as: UTF8.self) else {
            throw Lib0DecodingError.invalidUTF8
        }
        return value
    }

    mutating func readVarUint8Array() throws -> [UInt8] {
        let rawCount = try self.readVarUint()
        guard rawCount <= UInt64(self.remainingByteCount), let count = Int(exactly: rawCount) else {
            throw Lib0DecodingError.invalidCount
        }
        return try self.readBytes(count)
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

    mutating func readAny(depth: Int = 0) throws -> Lib0Any {
        guard depth <= 64 else { throw Lib0DecodingError.nestingLimitExceeded }
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
            let count = try self.readBoundedCount()
            var pairs: [(key: String, value: Lib0Any)] = []
            var seenKeys: Set<String> = []
            for _ in 0..<count {
                let key = try self.readVarString()
                guard key != "__proto__", seenKeys.insert(key).inserted else {
                    throw Lib0DecodingError.invalidValue
                }
                pairs.append((key, try self.readAny(depth: depth + 1)))
            }
            return .object(pairs)
        case 117:
            let count = try self.readBoundedCount()
            var elements: [Lib0Any] = []
            for _ in 0..<count { elements.append(try self.readAny(depth: depth + 1)) }
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

    mutating func readBoundedCount() throws -> Int {
        let rawCount = try self.readVarUint()
        guard rawCount <= UInt64(self.remainingByteCount), let count = Int(exactly: rawCount) else {
            throw Lib0DecodingError.invalidCount
        }
        return count
    }
}
