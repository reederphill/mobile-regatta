import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The render-fixture diff (#62). Pure CoreGraphics, no XCTest, so the app's unit tests compile this same
// file (a membership exception in the project adds it to RegattaTests) and check the thresholds on
// synthetic images.

/// An image as 8-bit sRGB RGBA pixels, row by row from the top.
struct PixelImage: Equatable {
    let width: Int
    let height: Int
    /// `width × height × 4` bytes: r, g, b, a.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "expected \(width * height * 4) bytes, got \(pixels.count)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A `width × height` image of one colour.
    init(width: Int, height: Int, fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        self.init(width: width, height: height,
                  pixels: Array((0..<width * height).map { _ in [fill.r, fill.g, fill.b, fill.a] }.joined()))
    }

    /// `image` redrawn into 8-bit sRGB RGBA, whatever its own format.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    init?(pngData: Data) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image)
    }

    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        get {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    var cgImage: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    var pngData: Data? {
        guard let image = cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// How far an actual render may stray from its reference and still pass.
struct DiffTolerance: Equatable {
    /// A pixel differs when any channel is more than this far from the reference's, out of 255. Absorbs
    /// anti-aliasing and blending noise between GPU runs.
    var channel: UInt8 = 12
    /// The render passes while at most this fraction of its pixels differ.
    var maxDifferingFraction = 0.001

    static let standard = DiffTolerance()
    /// Every pixel exactly equal.
    static let exact = DiffTolerance(channel: 0, maxDifferingFraction: 0)
}

/// An actual image compared pixel by pixel with its reference.
struct ImageDiff {
    let tolerance: DiffTolerance
    /// The images differ in size: nothing lines up, so every pixel counts as differing.
    let sizeMismatch: Bool
    let differingPixels: Int
    let totalPixels: Int
    /// The reference greyed out with every differing pixel in red, for the result bundle.
    let image: PixelImage

    var differingFraction: Double { totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels) }

    var passes: Bool {
        !sizeMismatch && differingFraction <= tolerance.maxDifferingFraction
    }

    var summary: String {
        if sizeMismatch { return "size mismatch" }
        let percent = (differingFraction * 100).formatted(.number.precision(.fractionLength(4)))
        return "\(differingPixels) of \(totalPixels) pixels differ by more than \(tolerance.channel)/255 (\(percent)%, "
            + "limit \((tolerance.maxDifferingFraction * 100).formatted(.number.precision(.fractionLength(4))))%)"
    }

    init(actual: PixelImage, reference: PixelImage, tolerance: DiffTolerance = .standard) {
        self.tolerance = tolerance
        guard actual.width == reference.width, actual.height == reference.height else {
            sizeMismatch = true
            totalPixels = actual.width * actual.height
            differingPixels = totalPixels
            image = actual
            return
        }
        sizeMismatch = false
        let total = actual.width * actual.height
        totalPixels = total
        var diff = [UInt8](repeating: 255, count: actual.pixels.count)
        var differing = 0
        let limit = Int(tolerance.channel)
        actual.pixels.withUnsafeBufferPointer { a in
            reference.pixels.withUnsafeBufferPointer { r in
                for p in 0..<total {
                    let i = p * 4
                    var worst = 0
                    for c in 0..<4 { worst = max(worst, abs(Int(a[i + c]) - Int(r[i + c]))) }
                    if worst > limit {
                        differing += 1
                        diff[i] = 255
                        diff[i + 1] = 0
                        diff[i + 2] = 0
                    } else {
                        // The reference as faint grey, so the red reads against it.
                        let luma = (Int(r[i]) * 54 + Int(r[i + 1]) * 183 + Int(r[i + 2]) * 19) >> 8
                        let grey = UInt8(170 + luma / 3)
                        diff[i] = grey
                        diff[i + 1] = grey
                        diff[i + 2] = grey
                    }
                }
            }
        }
        differingPixels = differing
        image = PixelImage(width: actual.width, height: actual.height, pixels: diff)
    }
}
