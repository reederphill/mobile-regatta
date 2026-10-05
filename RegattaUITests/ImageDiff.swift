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
    /// Rows at the bottom of both images left out of the comparison: the home-indicator band, which the
    /// system dims and hides on its own timer, so no two screenshots agree on it. They count neither as
    /// differing nor towards `totalPixels`.
    let ignoredBottomRows: Int
    /// The status-bar clock's box, left out of the comparison too (`statusBarClock(width:height:)`): the system draws
    /// the wall-clock time, so a render and its reference, taken at different times, never agree on it. `nil` when
    /// the diff compares it.
    let ignoredClock: PixelBox?
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
        var ignored = ignoredBottomRows > 0 ? "; bottom \(ignoredBottomRows) rows not compared" : ""
        if ignoredClock != nil { ignored += "; status-bar clock not compared" }
        return "\(differingPixels) of \(totalPixels) pixels differ by more than \(tolerance.channel)/255 (\(percent)%, "
            + "limit \((tolerance.maxDifferingFraction * 100).formatted(.number.precision(.fractionLength(4))))%\(ignored))"
    }

    /// The diff of `actual` against `reference`, leaving out their bottom `ignoringBottomRows` rows (see
    /// `ignoredBottomRows`), and the status-bar clock's box when `ignoringStatusBarClock` is set; the diff image
    /// shows both in pale blue.
    init(actual: PixelImage, reference: PixelImage, tolerance: DiffTolerance = .standard, ignoringBottomRows: Int = 0,
         ignoringStatusBarClock: Bool = false) {
        self.tolerance = tolerance
        ignoredBottomRows = min(max(0, ignoringBottomRows), actual.height)
        ignoredClock = ignoringStatusBarClock ? Self.statusBarClock(width: actual.width, height: actual.height) : nil
        guard actual.width == reference.width, actual.height == reference.height else {
            sizeMismatch = true
            totalPixels = actual.width * actual.height
            differingPixels = totalPixels
            image = actual
            return
        }
        sizeMismatch = false
        let compared = actual.width * (actual.height - ignoredBottomRows)
        // Which of the compared pixels the clock's box covers.
        var skipped = [Bool](repeating: false, count: compared)
        var skippedCount = 0
        if let box = ignoredClock {
            for y in box.y..<min(box.y + box.height, actual.height - ignoredBottomRows) {
                for x in box.x..<min(box.x + box.width, actual.width) {
                    skipped[y * actual.width + x] = true
                    skippedCount += 1
                }
            }
        }
        totalPixels = compared - skippedCount
        var diff = [UInt8](repeating: 255, count: actual.pixels.count)
        for i in stride(from: compared * 4, to: diff.count, by: 4) {
            diff[i] = 190
            diff[i + 1] = 215
            diff[i + 2] = 245
        }
        var differing = 0
        let limit = Int(tolerance.channel)
        actual.pixels.withUnsafeBufferPointer { a in
            reference.pixels.withUnsafeBufferPointer { r in
                for p in 0..<compared {
                    let i = p * 4
                    if skipped[p] {
                        diff[i] = 190
                        diff[i + 1] = 215
                        diff[i + 2] = 245
                        continue
                    }
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

/// A rectangle of pixels, from the image's top-left corner.
struct PixelBox: Equatable {
    let x: Int, y: Int, width: Int, height: Int
}

extension ImageDiff {
    /// Where the status bar draws its clock in a screenshot `width` × `height` pixels, with room for any time
    /// ("9:41" to "12:40"): the clock is centred in the leading third of the bar, its box from 11% to 28% of the
    /// width and 2.2% to 5.5% of the height (iPhone 17: 1206 × 2622, the clock at about x 157-290, y 80-118).
    static func statusBarClock(width: Int, height: Int) -> PixelBox {
        let x = Int(Double(width) * 0.11), y = Int(Double(height) * 0.022)
        return PixelBox(x: x, y: y, width: Int(Double(width) * 0.28) - x, height: Int(Double(height) * 0.055) - y)
    }

    /// How many pixel rows at the bottom of a screenshot `imageRows` pixels tall cover a band `bandPoints`
    /// tall, when the screenshot shows `framePoints` of height: the band rounded out to whole rows.
    static func rows(coveringBottom bandPoints: Double, ofFrame framePoints: Double, imageRows: Int) -> Int {
        guard bandPoints > 0, framePoints > 0, imageRows > 0 else { return 0 }
        // Less a hair, so floating-point noise on an exact fit doesn't add a row.
        let rows = bandPoints * Double(imageRows) / framePoints - 1e-6
        return min(imageRows, Int(rows.rounded(.up)))
    }
}

/// Whether a filter over a render reaches its edges (#111): the render through a colour-vision filter against the
/// same fixture unfiltered, patch by patch around the frame. The filter was once the SpriteKit scene's own, which
/// covers the scene's frame and not the camera's view, so the render's right and bottom bands went unfiltered; a
/// filter over the whole view moves the mean colour of every patch.
struct FilterCoverage {
    struct Patch: Equatable {
        /// Where the patch is, such as `bottom-right`.
        let name: String
        let x: Int, y: Int, size: Int
        /// How far the patch's mean colour moved, in its most-moved channel, out of 255.
        let shift: Double
    }

    /// The least a patch's mean colour moves under a filter, out of 255. Every filter moves the water tones by twice
    /// this or more in some channel (`VisionFilterTests`), and two renders of one frame match exactly.
    static let minimumShift = 6.0

    /// The four corners and the four edges' middles, each `size` pixels square and `inset` from the edges, the
    /// bottom ones above the bottom `ignoringBottomRows` rows (the home-indicator band).
    let patches: [Patch]

    /// The patches the filter didn't reach.
    var unfiltered: [Patch] { patches.filter { $0.shift < Self.minimumShift } }

    var summary: String {
        patches.map { "\($0.name) \($0.shift.formatted(.number.precision(.fractionLength(1))))" }.joined(separator: ", ")
    }

    init?(filtered: PixelImage, unfiltered: PixelImage, ignoringBottomRows: Int = 0, size: Int = 32, inset: Int = 12) {
        let width = filtered.width, height = filtered.height - max(0, ignoringBottomRows)
        guard filtered.width == unfiltered.width, filtered.height == unfiltered.height,
              width >= 2 * (size + inset), height >= 2 * (size + inset) else { return nil }
        let left = inset, right = width - inset - size, centreX = (width - size) / 2
        let top = inset, bottom = height - inset - size, middleY = (height - size) / 2
        let places = [("top-left", left, top), ("top", centreX, top), ("top-right", right, top),
                      ("left", left, middleY), ("right", right, middleY),
                      ("bottom-left", left, bottom), ("bottom", centreX, bottom), ("bottom-right", right, bottom)]
        patches = places.map { name, x, y in
            let a = Self.mean(filtered, x, y, size), b = Self.mean(unfiltered, x, y, size)
            return Patch(name: name, x: x, y: y, size: size, shift: zip(a, b).map { abs($0 - $1) }.max() ?? 0)
        }
    }

    /// The mean r, g and b of the `size`-pixel square at (`x`, `y`).
    private static func mean(_ image: PixelImage, _ x: Int, _ y: Int, _ size: Int) -> [Double] {
        var sum = [0.0, 0.0, 0.0]
        for row in y..<(y + size) {
            for column in x..<(x + size) {
                let pixel = image[column, row]
                sum[0] += Double(pixel.r)
                sum[1] += Double(pixel.g)
                sum[2] += Double(pixel.b)
            }
        }
        return sum.map { $0 / Double(size * size) }
    }
}
