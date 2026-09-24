// The hand-rolled binary codec (#63). Fixed-width integers are little-endian; lengths and counts are
// unsigned LEB128 varints in their shortest form; strings are a length and UTF-8. Decoding is strict:
// every value the encoder can't produce is rejected (truncation, trailing bytes, unknown codes, set
// reserved bits, over-long varints, invalid UTF-8, lengths over a field's limit), so each message has
// exactly one encoding and a peer can't make the other side allocate more than the limits allow.

public enum WireError: Error, Equatable, Sendable {
    /// The bytes ended inside a value.
    case truncated
    /// Bytes left over after the message.
    case trailingBytes(Int)
    case unknownMessageType(UInt8)
    /// A code, flag or string the decoder doesn't accept, naming the field.
    case invalidValue(String)
    /// A length or count over the field's limit.
    case tooLong(String)
    /// Encoding: a value the wire can't represent, naming the field.
    case outOfRange(String)
}

/// Appends wire values to `bytes`.
public struct WireWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func i8(_ v: Int8) { u8(UInt8(bitPattern: v)) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }

    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }

    /// A signed 24-bit value, −2²³ ..< 2²³.
    mutating func i24(_ v: Int32, _ field: String) throws {
        guard (-(1 << 23)..<(1 << 23)).contains(v) else { throw WireError.outOfRange(field) }
        let bits = UInt32(bitPattern: v)
        for shift in stride(from: 0, to: 24, by: 8) { bytes.append(UInt8(truncatingIfNeeded: bits >> UInt32(shift))) }
    }

    /// An `Int` that must fit in 32 signed bits, such as a tick.
    mutating func i32(_ v: Int, _ field: String) throws {
        guard let narrow = Int32(exactly: v) else { throw WireError.outOfRange(field) }
        u32(UInt32(bitPattern: narrow))
    }

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    /// A count or length, at most `limit`.
    mutating func count(_ n: Int, limit: Int, _ field: String) throws {
        guard n >= 0 else { throw WireError.outOfRange(field) }
        guard n <= limit else { throw WireError.tooLong(field) }
        varint(UInt64(n))
    }

    /// A small non-negative `Int` (a seat, place or index) as one byte.
    mutating func index(_ v: Int, _ field: String) throws {
        guard let narrow = UInt8(exactly: v) else { throw WireError.outOfRange(field) }
        u8(narrow)
    }

    mutating func string(_ s: String, limit: Int, _ field: String) throws {
        let utf8 = Array(s.utf8)
        try count(utf8.count, limit: limit, field)
        bytes.append(contentsOf: utf8)
    }

    mutating func blob(_ b: [UInt8], limit: Int, _ field: String) throws {
        try count(b.count, limit: limit, field)
        bytes.append(contentsOf: b)
    }
}

/// Reads wire values from `bytes` in order.
public struct WireReader: Sendable {
    let bytes: [UInt8]
    private(set) var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    /// Throws unless every byte has been read.
    func finish() throws {
        if remaining != 0 { throw WireError.trailingBytes(remaining) }
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    mutating func bool(_ field: String) throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw WireError.invalidValue(field)
        }
    }

    mutating func u16() throws -> UInt16 {
        let lo = UInt16(try u8()), hi = UInt16(try u8())
        return lo | hi << 8
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) { v |= UInt32(try u8()) << UInt32(shift) }
        return v
    }

    mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) { v |= UInt64(try u8()) << UInt64(shift) }
        return v
    }

    mutating func i24() throws -> Int32 {
        var bits: UInt32 = 0
        for shift in stride(from: 0, to: 24, by: 8) { bits |= UInt32(try u8()) << UInt32(shift) }
        return Int32(bitPattern: bits << 8) >> 8 // sign-extend bit 23
    }

    mutating func i32() throws -> Int { Int(Int32(bitPattern: try u32())) }

    /// Shortest-form LEB128 only, so every value has one encoding.
    mutating func varint(_ field: String) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            let payload = UInt64(byte & 0x7F)
            guard shift < 64, shift < 63 || payload <= 1 else { throw WireError.invalidValue(field) }
            value |= payload << shift
            if byte & 0x80 == 0 {
                if byte == 0 && shift > 0 { throw WireError.invalidValue(field) } // over-long
                return value
            }
            shift += 7
        }
    }

    mutating func count(limit: Int, _ field: String) throws -> Int {
        let n = try varint(field)
        guard n <= UInt64(limit) else { throw WireError.tooLong(field) }
        guard n <= UInt64(remaining) else { throw WireError.truncated } // every element is at least a byte
        return Int(n)
    }

    mutating func index() throws -> Int { Int(try u8()) }

    mutating func blob(limit: Int, _ field: String) throws -> [UInt8] {
        let n = try count(limit: limit, field)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    mutating func string(limit: Int, _ field: String) throws -> String {
        let raw = try blob(limit: limit, field)
        let text = String(decoding: raw, as: UTF8.self)
        guard Array(text.utf8) == raw else { throw WireError.invalidValue(field) } // invalid UTF-8 was repaired
        return text
    }
}

/// Field limits. Generous for what the fields hold, small enough that a hostile peer can't make a
/// decoder allocate much.
enum WireLimit {
    /// Names, builds, versions, ids, mark names and reasons.
    static let string = 256
    /// Tokens and attestation assertions.
    static let token = 4096
    /// A versioned payload's bytes.
    static let payload = 65_536
    /// Seats in a race (the core allows 16).
    static let seats = 64
    /// Data files, finishes, revealed wind keys.
    static let list = 1024
}
