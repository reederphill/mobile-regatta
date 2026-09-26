import Foundation
import Testing

/// The render-fixture diff (#62) on synthetic images: `ImageDiff.swift` is the UI tests' own file,
/// compiled into this target too.
@Suite struct ImageDiffTests {
    static let water: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (20, 70, 120, 255)
    static let hull: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (240, 90, 40, 255)

    /// A 200×200 sea with a 12×40 "boat" whose top-left corner is at (`x`, `y`).
    static func sea(boatAt x: Int, _ y: Int) -> PixelImage {
        var image = PixelImage(width: 200, height: 200, fill: water)
        for row in y..<(y + 40) {
            for column in x..<(x + 12) { image[column, row] = hull }
        }
        return image
    }

    @Test func identicalImagesDifferNowhere() {
        let diff = ImageDiff(actual: Self.sea(boatAt: 50, 50), reference: Self.sea(boatAt: 50, 50), tolerance: .exact)
        #expect(diff.differingPixels == 0)
        #expect(diff.passes)
    }

    /// One pixel pushed well past the colour tolerance: 1 of 40 000 pixels is under the 0.1 % limit.
    @Test func aSubThresholdOnePixelChangePasses() {
        let reference = Self.sea(boatAt: 50, 50)
        var actual = reference
        actual[10, 10] = (255, 255, 255, 255)
        let diff = ImageDiff(actual: actual, reference: reference)
        #expect(diff.differingPixels == 1)
        #expect(diff.passes, "\(diff.summary)")
        #expect(diff.image[10, 10] == (255, 0, 0, 255))
    }

    /// A pixel nudged within the colour tolerance doesn't count as differing at all.
    @Test func aChangeWithinTheColourToleranceIsNotADifference() {
        let reference = Self.sea(boatAt: 50, 50)
        var actual = reference
        let p = actual[10, 10]
        actual[10, 10] = (p.r + DiffTolerance.standard.channel, p.g, p.b, p.a)
        #expect(ImageDiff(actual: actual, reference: reference).differingPixels == 0)
        #expect(ImageDiff(actual: actual, reference: reference, tolerance: .exact).differingPixels == 1)
    }

    /// The boat 20 pixels on: its old and new footprints differ, far past the limit, and the diff marks them.
    @Test func aMovedBoatFailsAndTheDiffMarksIt() throws {
        let reference = Self.sea(boatAt: 50, 50)
        let actual = Self.sea(boatAt: 50, 70)
        let diff = ImageDiff(actual: actual, reference: reference)
        #expect(!diff.passes)
        #expect(diff.differingPixels == 2 * 12 * 20)
        #expect(diff.image[55, 55] == (255, 0, 0, 255), "the old footprint is marked")
        #expect(diff.image[55, 105] == (255, 0, 0, 255), "the new footprint is marked")
        #expect(diff.image[55, 75] != (255, 0, 0, 255), "where both have the boat nothing differs")
        #expect(diff.image[5, 5] != (255, 0, 0, 255))
        let png = try #require(diff.image.pngData)
        #expect(PixelImage(pngData: png) == diff.image, "the diff attaches as a PNG")
    }

    /// The home-indicator band differs (as when the system has dimmed the indicator in one screenshot):
    /// ignored, the rest matches exactly, and the band counts neither as differing nor towards the total.
    @Test func differencesInTheIgnoredBottomRowsDontCount() {
        let reference = Self.sea(boatAt: 50, 50)
        var actual = reference
        for row in 190..<200 {
            for column in 70..<130 { actual[column, row] = (255, 255, 255, 255) }
        }
        #expect(!ImageDiff(actual: actual, reference: reference).passes, "the band alone fails a full compare")

        let diff = ImageDiff(actual: actual, reference: reference, tolerance: .exact, ignoringBottomRows: 10)
        #expect(diff.differingPixels == 0)
        #expect(diff.totalPixels == 200 * 190)
        #expect(diff.passes, "\(diff.summary)")
        #expect(diff.image[100, 195] != (255, 0, 0, 255), "the band isn't marked as differing")
        #expect(diff.image[100, 195] != diff.image[100, 185], "the band shows as not compared")
    }

    /// Only the bottom rows are ignored: a difference just above the band still counts.
    @Test func aDifferenceAboveTheIgnoredRowsStillCounts() {
        let reference = Self.sea(boatAt: 50, 50)
        var actual = reference
        actual[100, 189] = (255, 255, 255, 255)
        let diff = ImageDiff(actual: actual, reference: reference, tolerance: .exact, ignoringBottomRows: 10)
        #expect(diff.differingPixels == 1)
        #expect(diff.image[100, 189] == (255, 0, 0, 255))
    }

    /// The band in points becomes whole screenshot rows: iPhone 17's 34 pt inset on its 874 pt, 2622 px
    /// screen is exactly 102 rows; a fractional band rounds out; no band, no rows.
    @Test func theBandInPointsBecomesWholeRows() {
        #expect(ImageDiff.rows(coveringBottom: 34, ofFrame: 874, imageRows: 2622) == 102)
        #expect(ImageDiff.rows(coveringBottom: 20, ofFrame: 1180, imageRows: 2360) == 40)
        #expect(ImageDiff.rows(coveringBottom: 10.2, ofFrame: 100, imageRows: 100) == 11)
        #expect(ImageDiff.rows(coveringBottom: 0, ofFrame: 874, imageRows: 2622) == 0)
        #expect(ImageDiff.rows(coveringBottom: 1000, ofFrame: 874, imageRows: 2622) == 2622)
    }

    @Test func differentSizesFail() {
        let diff = ImageDiff(actual: PixelImage(width: 10, height: 10, fill: Self.water),
                             reference: PixelImage(width: 10, height: 11, fill: Self.water))
        #expect(diff.sizeMismatch)
        #expect(!diff.passes)
    }

    @Test func pngRoundTripsExactly() throws {
        let image = Self.sea(boatAt: 3, 7)
        let png = try #require(image.pngData)
        #expect(PixelImage(pngData: png) == image)
    }
}
