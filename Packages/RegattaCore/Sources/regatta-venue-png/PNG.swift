import Foundation

/// A minimal PNG writer: 8-bit indexed colour, one IDAT compressed with fixed-Huffman deflate using only runs
/// (distance-1 matches), which suits flat venue charts. Pure Swift, so it builds on Linux; same pixels, same bytes.
enum PNG {
    static func encode(width: Int, height: Int, pixels: [UInt8], palette: [(UInt8, UInt8, UInt8)], title: String) -> Data {
        precondition(pixels.count == width * height && palette.count <= 256)
        var raw = [UInt8]()
        raw.reserveCapacity((width + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            raw += pixels[(y * width)..<((y + 1) * width)]
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        header += [8, 3, 0, 0, 0]
        chunk("IHDR", header, into: &out)
        chunk("PLTE", palette.flatMap { [$0.0, $0.1, $0.2] }, into: &out)
        chunk("tEXt", Array("Title".utf8) + [0] + Array(title.utf8), into: &out)
        chunk("IDAT", zlib(raw), into: &out)
        chunk("IEND", [], into: &out)
        return out
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8], into out: inout Data) {
        let typed = Array(type.utf8) + body
        out += bigEndian(UInt32(body.count))
        out += typed
        out += bigEndian(crc32(typed))
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    /// Writes bits least significant first, as deflate packs them.
    private struct Bits {
        var bytes: [UInt8] = []
        var current: UInt32 = 0
        var count = 0

        mutating func write(_ value: UInt32, _ bits: Int) {
            for i in 0..<bits {
                current |= ((value >> UInt32(i)) & 1) << UInt32(count)
                count += 1
                if count == 8 { bytes.append(UInt8(current)); current = 0; count = 0 }
            }
        }

        /// A Huffman code, most significant bit first.
        mutating func code(_ value: UInt32, _ bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) { write((value >> UInt32(i)) & 1, 1) }
        }

        mutating func flush() -> [UInt8] {
            if count > 0 { bytes.append(UInt8(current)) }
            return bytes
        }
    }

    private static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                      115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

    private static func symbol(_ v: Int, _ bits: inout Bits) {
        switch v {
        case 0...143: bits.code(UInt32(0x30 + v), 8)
        case 144...255: bits.code(UInt32(0x190 + v - 144), 9)
        case 256...279: bits.code(UInt32(v - 256), 7)
        default: bits.code(UInt32(0xC0 + v - 280), 8)
        }
    }

    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var bits = Bits()
        bits.write(1, 1) // final block
        bits.write(1, 2) // fixed Huffman
        var i = 0
        while i < data.count {
            var run = 0
            if i > 0 {
                while run < 258 && i + run < data.count && data[i + run] == data[i - 1] { run += 1 }
            }
            if run >= 3 {
                let index = lengthBases.lastIndex { $0 <= run }!
                symbol(257 + index, &bits)
                bits.write(UInt32(run - lengthBases[index]), lengthExtra[index])
                bits.code(0, 5) // distance code 0: distance 1
                i += run
            } else {
                symbol(Int(data[i]), &bits)
                i += 1
            }
        }
        symbol(256, &bits)
        return [0x78, 0x01] + bits.flush() + bigEndian(adler32(data))
    }
}
