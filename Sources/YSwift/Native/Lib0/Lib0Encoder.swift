/// Byte-exact `lib0` v1 encoder (writes into a growing `[UInt8]`).
///
/// Matches lib0 0.2.117 (the version yjs 13.6.31 uses): var-ints are base-128
/// little-endian; floats/bigints are IEEE-754 **big-endian**; `varString` length
/// counts UTF-8 bytes.
struct Lib0Encoder {
    private(set) var bytes: [UInt8] = []

    init() {}

    /// Pre-sizes the backing buffer to avoid repeated reallocations on large writes.
    mutating func reserveCapacity(_ minimumCapacity: Int) {
        self.bytes.reserveCapacity(minimumCapacity)
    }

    mutating func writeUInt8(_ byte: UInt8) {
        self.bytes.append(byte)
    }

    mutating func writeBytes(_ data: [UInt8]) {
        self.bytes.append(contentsOf: data)
    }

    /// Unsigned LEB128 (base-128, low 7-bit group first). Valid up to 2^53.
    mutating func writeVarUint(_ value: UInt64) {
        var num = value
        while num > 0x7F {
            self.bytes.append(UInt8(0x80 | (num & 0x7F)))
            num >>= 7
        }
        self.bytes.append(UInt8(num & 0x7F))
    }

    /// Signed var-int (sign-magnitude): sign bit `0x40` in the first byte.
    mutating func writeVarInt(_ value: Int64) {
        self.writeVarInt(magnitude: value.magnitude, isNegative: value < 0)
    }

    mutating func writeVarInt(magnitude: UInt64, isNegative: Bool) {
        var num = magnitude
        var byte = UInt8(num & 0x3F) | (isNegative ? 0x40 : 0)
        if num > 0x3F { byte |= 0x80 }
        self.bytes.append(byte)
        num >>= 6
        while num > 0 {
            var next = UInt8(num & 0x7F)
            if num > 0x7F { next |= 0x80 }
            self.bytes.append(next)
            num >>= 7
        }
    }

    mutating func writeVarString(_ string: String) {
        let utf8 = Array(string.utf8)
        self.writeVarUint(UInt64(utf8.count))
        self.bytes.append(contentsOf: utf8)
    }

    mutating func writeVarUint8Array(_ data: [UInt8]) {
        self.writeVarUint(UInt64(data.count))
        self.bytes.append(contentsOf: data)
    }

    mutating func writeFloat32(_ value: Float) {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { self.bytes.append(contentsOf: $0) }
    }

    mutating func writeFloat64(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { self.bytes.append(contentsOf: $0) }
    }

    mutating func writeBigInt64(_ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { self.bytes.append(contentsOf: $0) }
    }

    mutating func writeAny(_ value: Lib0Any) {
        switch value {
        case .undefined: self.writeUInt8(127)
        case .null: self.writeUInt8(126)
        case .number(let number): self.writeNumber(number)
        case .bigInt(let int):
            self.writeUInt8(122)
            self.writeBigInt64(int)
        case .bool(let flag): self.writeUInt8(flag ? 120 : 121)
        case .string(let string):
            self.writeUInt8(119)
            self.writeVarString(string)
        case .object(let pairs):
            self.writeUInt8(118)
            self.writeVarUint(UInt64(pairs.count))
            for pair in pairs {
                self.writeVarString(pair.key)
                self.writeAny(pair.value)
            }
        case .array(let elements):
            self.writeUInt8(117)
            self.writeVarUint(UInt64(elements.count))
            for element in elements { self.writeAny(element) }
        case .bytes(let data):
            self.writeUInt8(116)
            self.writeVarUint8Array(data)
        }
    }

    /// lib0 number dispatch: integer (`|n| <= 2^31-1`) → float32 round-trip → float64.
    private mutating func writeNumber(_ number: Double) {
        if number.isFinite, number == number.rounded(.towardZero), abs(number) <= 2_147_483_647 {
            self.writeUInt8(125)
            self.writeVarInt(magnitude: UInt64(abs(number)), isNegative: number.sign == .minus)
        } else if Double(Float(number)) == number {
            self.writeUInt8(124)
            self.writeFloat32(Float(number))
        } else {
            self.writeUInt8(123)
            self.writeFloat64(number)
        }
    }
}
