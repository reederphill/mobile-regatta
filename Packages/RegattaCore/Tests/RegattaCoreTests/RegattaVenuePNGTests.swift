import Foundation
import Testing
import RegattaCore
@testable import VenueTools
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// `regatta-venue-png` (#83): an overview PNG per shipped pairing, checked in under `docs/venues/` for #84.
@Suite struct RegattaVenuePNGTests {
    static let repositoryRoot = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }

    #if os(macOS) || os(Linux)
    @Test func rendersOnePNGPerPairingIntoDocsVenues() throws {
        let pairings = try ShippedVenues.pairings()
        let names = pairings.map(VenueOverview.fileName)
        #expect(names.count == 6 && Set(names).count == 6)
        #expect(names.first == "hollin-bay@1-classic-oscillating@2.png")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("regatta-venue-png-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try venuePNG([directory.path])
        #expect(run.status == 0)
        #expect(run.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent } == names)

        let docs = Self.repositoryRoot.appendingPathComponent("docs/venues")
        let checkedIn = try FileManager.default.contentsOfDirectory(atPath: docs.path).filter { $0.hasSuffix(".png") }.sorted()
        #expect(checkedIn == names.sorted(), "run regatta-venue-png from the repository root to refresh docs/venues/")
        for name in names {
            let written = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(written.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "\(name)")
            let docsFile = docs.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: docsFile.path) {
                // The same map: the size is fixed by the venue and the course; pixels may round apart across platforms.
                #expect(Self.dimensions(try Data(contentsOf: docsFile)) == Self.dimensions(written), "\(name)")
            }
        }
    }
    #endif

    @Test func overviewShowsLandWaterDepthAndTheCourse() throws {
        let pairingCase = try #require(try ShippedVenues.pairings().first { $0.venue.ref.id == "saltings-reach" })
        let image = VenueOverview.image(pairingCase)
        #expect(image.width > 100 && image.height > 100)
        let inks = Set(image.pixels)
        for ink: VenueOverview.Ink in [.land, .area, .areaRotated, .mark, .markRotated, .startLine, .landmark] {
            #expect(inks.contains(ink.rawValue), "\(ink)")
        }
        // The estuary is tinted by depth in more than one band, and its banks are land.
        #expect(inks.filter { (VenueOverview.Ink.depth1.rawValue...VenueOverview.Ink.depth5.rawValue).contains($0) }.count >= 3)
        #expect(!inks.contains(VenueOverview.Ink.water.rawValue))
    }

    @Test func pngHeaderAndChecksumsAreRight() {
        var image = IndexedImage(width: 3, height: 2, palette: [.init(0, 0, 0), .init(255, 255, 255)])
        image[1, 1] = 1
        let png = [UInt8](image.png)
        #expect(Self.dimensions(Data(png)) == [3, 2])
        // IHDR: 8-bit palette colour; the CRC of "IEND" with no data is fixed.
        #expect(Array(png[24..<29]) == [8, 3, 0, 0, 0])
        #expect(Array(png.suffix(12)) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        #expect(PNG.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(PNG.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    #if canImport(ImageIO)
    /// ImageIO decodes what the encoder writes, pixel for pixel: long runs, the row-above matches and
    /// literals all round-trip.
    @Test func pngDecodesPixelForPixel() throws {
        let palette: [IndexedImage.Colour] = [.init(10, 20, 30), .init(200, 100, 50), .init(0, 255, 0)]
        var image = IndexedImage(width: 300, height: 40, palette: palette)
        for y in 0..<40 {
            for x in 0..<300 { image[x, y] = UInt8((x / 7 + y / 3 + (x * y) % 5 == 0 ? 1 : 0) % 3) }
        }
        let source = try #require(CGImageSourceCreateWithData(image.png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 300 && decoded.height == 40)
        var rgba = [UInt8](repeating: 0, count: 300 * 40 * 4)
        let context = try #require(CGContext(
            data: &rgba, width: 300, height: 40, bitsPerComponent: 8, bytesPerRow: 300 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 300, height: 40))
        var mismatches = 0
        for y in 0..<40 {
            for x in 0..<300 {
                let colour = palette[Int(image[x, y])]
                let i = (y * 300 + x) * 4
                if abs(Int(rgba[i]) - Int(colour.red)) > 2 || abs(Int(rgba[i + 1]) - Int(colour.green)) > 2
                    || abs(Int(rgba[i + 2]) - Int(colour.blue)) > 2 { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }
    #endif

    /// Width and height from a PNG's IHDR.
    static func dimensions(_ png: Data) -> [Int] {
        let bytes = [UInt8](png)
        guard bytes.count >= 24 else { return [] }
        func word(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return [word(16), word(20)]
    }
}

#if os(macOS) || os(Linux)
private final class BundleMarker {}

/// Runs the built `regatta-venue-png` with `arguments` in its own process.
private func venuePNG(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
    let executable = try #require(venuePNGExecutable(), "regatta-venue-png not found next to the test bundle")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, printed)
}

/// SwiftPM builds `regatta-venue-png` into the same products directory as the test bundle.
private func venuePNGExecutable() -> URL? {
    var directories: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        directories.append(bundle.bundleURL.deletingLastPathComponent())
    }
    let marker = Bundle(for: BundleMarker.self).bundleURL
    directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
    directories.append(Bundle.main.bundleURL)
    directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    return directories.lazy
        .map { $0.appendingPathComponent("regatta-venue-png") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
#endif
