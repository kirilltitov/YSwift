enum JSONSyntaxError: Error, Sendable {
    case invalidSyntax
    case nestingLimitExceeded
}

/// Validates JSON text without materialising it. This intentionally follows the
/// JSON lexical grammar used by `JSON.parse`: escaped UTF-16 code units are
/// syntax, so an unpaired `\uXXXX` surrogate remains valid and is preserved in
/// the original string.
struct JSONSyntaxValidator {
    private static let maximumNestingDepth = 64

    private let bytes: [UInt8]
    private var position = 0

    init(_ value: String) {
        self.bytes = Array(value.utf8)
    }

    mutating func validate() throws {
        self.skipWhitespace()
        try self.readValue(depth: 0)
        self.skipWhitespace()
        guard self.position == self.bytes.count else { throw JSONSyntaxError.invalidSyntax }
    }

    private mutating func readValue(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw JSONSyntaxError.nestingLimitExceeded
        }
        guard let byte = self.peek() else { throw JSONSyntaxError.invalidSyntax }
        switch byte {
        case 0x22: try self.readString()
        case 0x7B: try self.readObject(depth: depth)
        case 0x5B: try self.readArray(depth: depth)
        case 0x74: try self.readLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: try self.readLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: try self.readLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39: try self.readNumber()
        default: throw JSONSyntaxError.invalidSyntax
        }
    }

    private mutating func readObject(depth: Int) throws {
        try self.consume(0x7B)
        self.skipWhitespace()
        if self.consumeIf(0x7D) { return }
        while true {
            try self.readString()
            self.skipWhitespace()
            try self.consume(0x3A)
            self.skipWhitespace()
            try self.readValue(depth: depth + 1)
            self.skipWhitespace()
            if self.consumeIf(0x7D) { return }
            try self.consume(0x2C)
            self.skipWhitespace()
            guard self.peek() != 0x7D else { throw JSONSyntaxError.invalidSyntax }
        }
    }

    private mutating func readArray(depth: Int) throws {
        try self.consume(0x5B)
        self.skipWhitespace()
        if self.consumeIf(0x5D) { return }
        while true {
            try self.readValue(depth: depth + 1)
            self.skipWhitespace()
            if self.consumeIf(0x5D) { return }
            try self.consume(0x2C)
            self.skipWhitespace()
            guard self.peek() != 0x5D else { throw JSONSyntaxError.invalidSyntax }
        }
    }

    private mutating func readString() throws {
        try self.consume(0x22)
        while let byte = self.peek() {
            self.position += 1
            switch byte {
            case 0x22:
                return
            case 0x5C:
                guard let escape = self.peek() else { throw JSONSyntaxError.invalidSyntax }
                self.position += 1
                switch escape {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    for _ in 0..<4 {
                        guard let hex = self.peek(), Self.isHexDigit(hex) else {
                            throw JSONSyntaxError.invalidSyntax
                        }
                        self.position += 1
                    }
                default:
                    throw JSONSyntaxError.invalidSyntax
                }
            case 0x00...0x1F:
                throw JSONSyntaxError.invalidSyntax
            default:
                break
            }
        }
        throw JSONSyntaxError.invalidSyntax
    }

    private mutating func readNumber() throws {
        _ = self.consumeIf(0x2D)
        guard let first = self.peek() else { throw JSONSyntaxError.invalidSyntax }
        if first == 0x30 {
            self.position += 1
            if let next = self.peek(), Self.isDigit(next) { throw JSONSyntaxError.invalidSyntax }
        } else {
            guard first >= 0x31, first <= 0x39 else { throw JSONSyntaxError.invalidSyntax }
            repeat { self.position += 1 } while self.peek().map(Self.isDigit) == true
        }

        if self.consumeIf(0x2E) {
            guard self.peek().map(Self.isDigit) == true else { throw JSONSyntaxError.invalidSyntax }
            repeat { self.position += 1 } while self.peek().map(Self.isDigit) == true
        }

        if let byte = self.peek(), byte == 0x65 || byte == 0x45 {
            self.position += 1
            if let sign = self.peek(), sign == 0x2B || sign == 0x2D { self.position += 1 }
            guard self.peek().map(Self.isDigit) == true else { throw JSONSyntaxError.invalidSyntax }
            repeat { self.position += 1 } while self.peek().map(Self.isDigit) == true
        }
    }

    private mutating func readLiteral(_ literal: [UInt8]) throws {
        guard self.position <= self.bytes.count - literal.count,
            self.bytes[self.position..<self.position + literal.count].elementsEqual(literal)
        else {
            throw JSONSyntaxError.invalidSyntax
        }
        self.position += literal.count
    }

    private mutating func skipWhitespace() {
        while let byte = self.peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            self.position += 1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard self.consumeIf(byte) else { throw JSONSyntaxError.invalidSyntax }
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard self.peek() == byte else { return false }
        self.position += 1
        return true
    }

    private func peek() -> UInt8? {
        self.position < self.bytes.count ? self.bytes[self.position] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        Self.isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }
}
