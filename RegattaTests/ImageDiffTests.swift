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

    /// `image` with the pixels in `columns` × `rows` pushed through a stand-in filter (red up, blue down).
    static func filtered(_ image: PixelImage, columns: Range<Int>, rows: Range<Int>) -> PixelImage {
        var out = image
        for y in rows {
            for x in columns {
                let p = image[x, y]
                out[x, y] = (p.r &+ 30, p.g, p.b &- 25, p.a)
            }
        }
        return out
    }

    /// A filter over the whole frame moves every patch around its edge (#111).
    @Test func aFilterOverTheWholeFrameReachesEveryEdge() throws {
        let plain = Self.sea(boatAt: 90, 80)
        let coverage = try #require(FilterCoverage(filtered: Self.filtered(plain, columns: 0..<200, rows: 0..<200),
                                                   unfiltered: plain))
        #expect(coverage.patches.count == 8)
        #expect(coverage.unfiltered.isEmpty, "\(coverage.summary)")
    }

    /// The scene's own filter over the camera's scaled view (#111): it covered a top-left rectangle about 79% × 80%
    /// of the frame, so the right and bottom patches didn't move.
    @Test func aFilterOverTheTopLeftOfTheFrameMissesTheRightAndBottom() throws {
        let plain = Self.sea(boatAt: 90, 80)
        let coverage = try #require(FilterCoverage(filtered: Self.filtered(plain, columns: 0..<158, rows: 0..<160),
                                                   unfiltered: plain))
        #expect(Set(coverage.unfiltered.map(\.name)) == ["top-right", "right", "bottom-left", "bottom", "bottom-right"],
                "\(coverage.summary)")
    }

    /// With no filter, nothing moves, so every patch counts as unfiltered: the check can fail.
    @Test func noFilterLeavesEveryPatchUnfiltered() throws {
        let plain = Self.sea(boatAt: 90, 80)
        let coverage = try #require(FilterCoverage(filtered: plain, unfiltered: plain))
        #expect(coverage.patches.count == 8)
        #expect(coverage.unfiltered == coverage.patches, "\(coverage.summary)")
    }

    /// The bottom patches sit above the home-indicator band, which a render's diff leaves out.
    @Test func coverageLeavesTheBottomBandOut() throws {
        let plain = Self.sea(boatAt: 90, 80)
        // Filtered everywhere but the bottom 50 rows, which stand for the band.
        let filtered = Self.filtered(plain, columns: 0..<200, rows: 0..<150)
        #expect(try #require(FilterCoverage(filtered: filtered, unfiltered: plain)).unfiltered.count == 3)
        let coverage = try #require(FilterCoverage(filtered: filtered, unfiltered: plain, ignoringBottomRows: 50))
        #expect(coverage.unfiltered.isEmpty, "\(coverage.summary)")
        #expect(coverage.patches.allSatisfy { $0.y + $0.size <= 150 })
    }

    @Test func coverageNeedsTwoRendersOfOneSize() {
        #expect(FilterCoverage(filtered: PixelImage(width: 200, height: 200, fill: Self.water),
                               unfiltered: PixelImage(width: 200, height: 199, fill: Self.water)) == nil)
    }

    /// A gallery's status-bar clock shows the wall-clock time, so the clock's box isn't compared when asked: a whole
    /// box of changed pixels isn't a difference, and the box leaves `totalPixels`. Beside the box it still counts.
    @Test func theStatusBarClockBoxIsLeftOutWhenAsked() {
        let reference = Self.sea(boatAt: 50, 50)
        let box = ImageDiff.statusBarClock(width: 200, height: 200)
        var actual = reference
        for row in box.y..<(box.y + box.height) {
            for column in box.x..<(box.x + box.width) { actual[column, row] = (255, 255, 255, 255) }
        }
        let compared = ImageDiff(actual: actual, reference: reference, tolerance: .exact, ignoringStatusBarClock: true)
        #expect(compared.differingPixels == 0)
        #expect(compared.totalPixels == 200 * 200 - box.width * box.height)
        #expect(compared.image[box.x, box.y] == (190, 215, 245, 255), "the box is pale blue in the diff")
        #expect(ImageDiff(actual: actual, reference: reference, tolerance: .exact).differingPixels == box.width * box.height,
                "the box is compared unless asked")
        var beside = reference
        beside[box.x - 1, box.y] = (255, 255, 255, 255)
        #expect(ImageDiff(actual: beside, reference: reference, tolerance: .exact,
                          ignoringStatusBarClock: true).differingPixels == 1)
    }

    /// On an iPhone 17 screenshot (1206 × 2622) the box holds the clock at about x 157-290, y 80-118, and the
    /// leading edge of the bar's Wi-Fi and battery (x 860 and up) stays outside.
    @Test func theStatusBarClockBoxCoversTheIPhoneClock() {
        let box = ImageDiff.statusBarClock(width: 1206, height: 2622)
        #expect(box.x <= 150 && box.x + box.width >= 300)
        #expect(box.y <= 75 && box.y + box.height >= 125)
        #expect(box.x + box.width < 860)
    }
}
