import Foundation

/// A palette image: `pixels` holds `width × height` palette indices, row by row from the top.
public struct IndexedImage: Sendable, Equatable {
    public struct Colour: Sendable, Equatable {
        public let red: UInt8, green: UInt8, blue: UInt8
        public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public let width: Int
    public let height: Int
    public let palette: [Colour]
    public var pixels: [UInt8]

    public init(width: Int, height: Int, palette: [Colour], fill: UInt8 = 0) {
        precondition(width > 0 && height > 0 && (1...256).contains(palette.count))
        self.width = width
        self.height = height
        self.palette = palette
        pixels = Array(repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Sets the pixel at (`x`, `y`) to `index` if it is in the image.
    public mutating func plot(_ x: Int, _ y: Int, _ index: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = index
    }

    /// The image as a PNG file: 8-bit palette colour, no interlace, one zlib stream compressed with
    /// deflate's fixed Huffman codes and matches against the previous byte and the row above. Pure Swift,
    /// so it writes the same bytes on every platform.
    public var png: Data {
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (width + 1))
        for y in 0..<height {
            raw.append(0)  // filter type None
            raw.append(contentsOf: pixels[(y * width)..<((y + 1) * width)])
        }
        var header: [UInt8] = []
        header += PNG.bigEndian(UInt32(width)) + PNG.bigEndian(UInt32(height))
        header += [8, 3, 0, 0, 0]  // bit depth, colour type palette, deflate, adaptive filtering, no interlace
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += PNG.chunk("IHDR", header)
        file += PNG.chunk("PLTE", palette.flatMap { [$0.red, $0.green, $0.blue] })
        file += PNG.chunk("IDAT", PNG.zlib(raw, rowBytes: width + 1))
        file += PNG.chunk("IEND", [])
        return Data(file)
    }
}

/// The pieces of a PNG file (RFC 2083) and its zlib stream (RFC 1950, RFC 1951).
enum PNG {
    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return bigEndian(UInt32(data.count)) + typeBytes + data + bigEndian(crc32(typeBytes + data))
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
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
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for byte in bytes[chunk..<min(chunk + 5552, bytes.count)] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    /// A zlib stream of `data`: one final deflate block with the fixed Huffman codes, matching each
    /// position against a run of the previous byte (distance 1) and against the row above (distance
    /// `rowBytes`), whichever is longer.
    static func zlib(_ data: [UInt8], rowBytes: Int) -> [UInt8] {
        var out = BitWriter()
        out.bytes = [0x78, 0x01]  // deflate, 32K window, no dictionary, fastest; 0x7801 % 31 == 0
        out.write(1, count: 1)  // final block
        out.write(1, count: 2)  // fixed Huffman codes
        var i = 0
        while i < data.count {
            var best = (length: 0, distance: 0)
            for distance in [1, rowBytes] where distance <= i && distance <= 32768 {
                var length = 0
                while length < 258, i + length < data.count, data[i + length] == data[i + length - distance] { length += 1 }
                if length > best.length { best = (length, distance) }
            }
            if best.length >= 3 {
                out.writeLength(best.length)
                out.writeDistance(best.distance)
                i += best.length
            } else {
                out.writeLiteral(Int(data[i]))
                i += 1
            }
        }
        out.writeLiteral(256)  // end of block
        out.flush()
        return out.bytes + bigEndian(adler32(data))
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var count = 0

        /// Writes the low `count` bits of `value`, least significant first (deflate's order for data).
        mutating func write(_ value: Int, count bits: Int) {
            buffer |= UInt64(value) << UInt64(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        /// Writes a Huffman code of `bits` bits, most significant first.
        mutating func writeCode(_ code: Int, bits: Int) {
            var reversed = 0
            for k in 0..<bits { reversed |= ((code >> k) & 1) << (bits - 1 - k) }
            write(reversed, count: bits)
        }

        /// A literal/length symbol in the fixed code (RFC 1951 3.2.6).
        mutating func writeLiteral(_ symbol: Int) {
            switch symbol {
            case 0...143: writeCode(0x30 + symbol, bits: 8)
            case 144...255: writeCode(0x190 + symbol - 144, bits: 9)
            case 256...279: writeCode(symbol - 256, bits: 7)
            default: writeCode(0xC0 + symbol - 280, bits: 8)
            }
        }

        static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                                  131, 163, 195, 227]
        static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
        static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
                                    1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                        12, 12, 13, 13]

        /// A match length, 3...258.
        mutating func writeLength(_ length: Int) {
            if length == 258 {
                writeLiteral(285)
                return
            }
            let k = Self.lengthBases.lastIndex { $0 <= length }!
            writeLiteral(257 + k)
            write(length - Self.lengthBases[k], count: Self.lengthExtraBits[k])
        }

        /// A match distance, 1...32768: five-bit fixed codes.
        mutating func writeDistance(_ distance: Int) {
            let k = Self.distanceBases.lastIndex { $0 <= distance }!
            writeCode(k, bits: 5)
            write(distance - Self.distanceBases[k], count: Self.distanceExtraBits[k])
        }

        /// Pads the last byte with zeros.
        mutating func flush() {
            if count > 0 { write(0, count: 8 - count) }
        }
    }
}
