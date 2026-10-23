// A minimal definite-length CBOR decoder (RFC 8949), only as much as App Attest's attestation object and assertion
// need (#158, ADR 0014): unsigned integers, byte strings, text strings, arrays and maps. Everything else is refused:
// negative integers, tags, floats and simple values, indefinite lengths, reserved length codes, 8-byte lengths,
// duplicate map keys, more than `maxCount` items in an array or map, invalid UTF-8, nesting deeper than `maxDepth`, and bytes after the item. It never traps: every
// length is checked against the bytes left before anything is read or reserved, so a hostile input can't make it
// allocate past its own size.

/// A decoded CBOR item.
public indirect enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    /// Pairs in the order they came; keys are distinct.
    case map([(key: CBOR, value: CBOR)])

    public static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.unsigned(let x), .unsigned(let y)): x == y
        case (.bytes(let x), .bytes(let y)): x == y
        case (.text(let x), .text(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// The value under text key `key` in a map, or nil.
    public subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .text(key) }?.value
    }

    public var byteString: [UInt8]? {
        if case .bytes(let b) = self { return b }
        return nil
    }

    public var textString: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    public var arrayItems: [CBOR]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

public enum CBORError: Error, Equatable, Sendable {
    /// The bytes ended inside an item.
    case truncated
    /// Bytes after the top-level item.
    case trailingBytes
    /// A major type, length code or value this decoder doesn't take.
    case unsupported(String)
    /// Nested past the decoder's depth.
    case tooDeep
    /// A map with the same key twice.
    case duplicateKey
    /// A text string that isn't UTF-8.
    case invalidText
}

public enum CBORDecoder {
    /// Arrays and maps nest at most this deep (the attestation object's `attStmt.x5c` is at depth 3).
    public static let maxDepth = 4
    /// An array or map holds at most this many items (App Attest's have 2 or 3), so the duplicate-key check stays small.
    public static let maxCount = 64

    /// Decodes exactly one item from `bytes`.
    public static func decode(_ bytes: [UInt8], maxDepth: Int = maxDepth) throws(CBORError) -> CBOR {
        var reader = Reader(bytes: bytes)
        let item = try reader.item(depth: 0, maxDepth: maxDepth)
        guard reader.offset == bytes.count else { throw .trailingBytes }
        return item
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var remaining: Int { bytes.count - offset }

        mutating func byte() throws(CBORError) -> UInt8 {
            guard offset < bytes.count else { throw .truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        /// A big-endian unsigned integer of `width` bytes.
        mutating func bigEndian(_ width: Int) throws(CBORError) -> UInt64 {
            guard width <= remaining else { throw .truncated }
            var value: UInt64 = 0
            for _ in 0..<width { value = value << 8 | UInt64(try byte()) }
            return value
        }

        /// The head's argument: immediate (0–23), or 1, 2 or 4 bytes after it; 8 bytes only for an integer's value.
        mutating func argument(_ info: UInt8, allowEightBytes: Bool) throws(CBORError) -> UInt64 {
            switch info {
            case 0...23: return UInt64(info)
            case 24: return try bigEndian(1)
            case 25: return try bigEndian(2)
            case 26: return try bigEndian(4)
            case 27 where allowEightBytes: return try bigEndian(8)
            case 27: throw .unsupported("8-byte length")
            case 31: throw .unsupported("indefinite length")
            default: throw .unsupported("reserved length code")
            }
        }

        /// A length no larger than the bytes left, so nothing past the input is ever reserved.
        mutating func length(_ info: UInt8, minimumItemSize: Int) throws(CBORError) -> Int {
            let n = try argument(info, allowEightBytes: false)
            guard n <= UInt64(remaining / minimumItemSize) else { throw .truncated }
            return Int(n)
        }

        mutating func item(depth: Int, maxDepth: Int) throws(CBORError) -> CBOR {
            let head = try byte()
            let major = head >> 5, info = head & 0x1F
            switch major {
            case 0:
                return .unsigned(try argument(info, allowEightBytes: true))
            case 2:
                let n = try length(info, minimumItemSize: 1)
                defer { offset += n }
                return .bytes(Array(bytes[offset..<(offset + n)]))
            case 3:
                let n = try length(info, minimumItemSize: 1)
                let raw = bytes[offset..<(offset + n)]
                offset += n
                let text = String(decoding: raw, as: UTF8.self)
                guard text.utf8.elementsEqual(raw) else { throw .invalidText }
                return .text(text)
            case 4:
                guard depth < maxDepth else { throw .tooDeep }
                let n = try length(info, minimumItemSize: 1)
                guard n <= CBORDecoder.maxCount else { throw .unsupported("too many items") }
                var items: [CBOR] = []
                items.reserveCapacity(n)
                for _ in 0..<n { items.append(try item(depth: depth + 1, maxDepth: maxDepth)) }
                return .array(items)
            case 5:
                guard depth < maxDepth else { throw .tooDeep }
                let n = try length(info, minimumItemSize: 2)
                guard n <= CBORDecoder.maxCount else { throw .unsupported("too many items") }
                var pairs: [(key: CBOR, value: CBOR)] = []
                pairs.reserveCapacity(n)
                for _ in 0..<n {
                    let key = try item(depth: depth + 1, maxDepth: maxDepth)
                    guard !pairs.contains(where: { $0.key == key }) else { throw .duplicateKey }
                    pairs.append((key, try item(depth: depth + 1, maxDepth: maxDepth)))
                }
                return .map(pairs)
            case 1: throw .unsupported("negative integer")
            case 6: throw .unsupported("tag")
            default: throw .unsupported("float or simple value")
            }
        }
    }
}
