import UIKit
import XCTest

/// Render fixtures (#62): a race log replayed to a freeze tick, screenshot, and diffed pixel by pixel.
final class RenderFixtureUITests: RenderFixtureTestCase {
    /// The same fixture launched twice draws exactly the same pixels outside the home-indicator band.
    @MainActor func testFixtureRendersIdenticallyTwice() throws {
        let first = try renderFixture("prestart")
        let second = try renderFixture("prestart")
        let diff = assertMatches(second.image, first.image, named: "prestart-twice", tolerance: .exact,
                                 ignoringBottomRows: first.homeIndicatorRows)
        XCTAssertFalse(diff.sizeMismatch)
    }

    /// One pixel changed past the colour tolerance is under the differing-pixel limit, so it passes.
    @MainActor func testOnePixelChangeOnARealRenderPasses() throws {
        let render = try renderFixture("prestart").image
        var touched = render
        let pixel = touched[render.width / 2, render.height / 2]
        touched[render.width / 2, render.height / 2] = (pixel.r &+ 128, pixel.g &+ 128, pixel.b &+ 128, pixel.a)
        let diff = assertMatches(touched, render, named: "prestart-one-pixel")
        XCTAssertEqual(diff.differingPixels, 1)
        XCTAssertTrue(diff.passes)
    }

    /// The fleet a second further on fails the diff, and the failure attaches actual, reference and diff PNGs.
    @MainActor func testMovedBoatFailsWithTheDiffAttached() throws {
        let reference = try renderFixture("prestart").image
        let moved = try renderFixture("prestart-moved").image
        let diff = ImageDiff(actual: moved, reference: reference)
        XCTAssertFalse(diff.passes, "the moved fleet passed: \(diff.summary)")
        XCTAssertGreaterThan(diff.differingFraction, DiffTolerance.standard.maxDifferingFraction)

        let attachments = attachDiff(diff, actual: moved, reference: reference, named: "prestart-moved")
        XCTAssertEqual(attachments.map(\.name), ["prestart-moved-actual.png", "prestart-moved-reference.png", "prestart-moved-diff.png"])
        let pngs = [moved.pngData, reference.pngData, diff.image.pngData]
        XCTAssertTrue(pngs.allSatisfy { ($0?.count ?? 0) > 0 }, "an attached PNG is empty")
    }

    /// The committed reference for this device (References/<device>/prestart.png). References are
    /// recorded on iPhone only; the iPad run skips here on purpose. Anywhere else, a missing reference
    /// fails in CI rather than skipping.
    @MainActor func testPrestartMatchesItsReference() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        try assertMatchesReference("prestart")
    }
}
