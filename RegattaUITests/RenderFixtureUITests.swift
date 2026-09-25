import XCTest

/// Render fixtures (#62): a race log replayed to a freeze tick, screenshot, and diffed pixel by pixel.
final class RenderFixtureUITests: RenderFixtureTestCase {
    /// The same fixture launched twice draws exactly the same pixels.
    @MainActor func testFixtureRendersIdenticallyTwice() throws {
        let first = try renderFixture("prestart")
        let second = try renderFixture("prestart")
        let diff = assertMatches(second, first, named: "prestart-twice", tolerance: .exact)
        XCTAssertEqual(diff.differingPixels, 0)
        XCTAssertFalse(diff.sizeMismatch)
    }

    /// One pixel changed past the colour tolerance is under the differing-pixel limit, so it passes.
    @MainActor func testOnePixelChangeOnARealRenderPasses() throws {
        let render = try renderFixture("prestart")
        var touched = render
        let pixel = touched[render.width / 2, render.height / 2]
        touched[render.width / 2, render.height / 2] = (pixel.r &+ 128, pixel.g &+ 128, pixel.b &+ 128, pixel.a)
        let diff = assertMatches(touched, render, named: "prestart-one-pixel")
        XCTAssertEqual(diff.differingPixels, 1)
        XCTAssertTrue(diff.passes)
    }

    /// The fleet a second further on fails the diff, and the failure attaches actual, reference and diff PNGs.
    @MainActor func testMovedBoatFailsWithTheDiffAttached() throws {
        let reference = try renderFixture("prestart")
        let moved = try renderFixture("prestart-moved")
        let diff = ImageDiff(actual: moved, reference: reference)
        XCTAssertFalse(diff.passes, "the moved fleet passed: \(diff.summary)")
        XCTAssertGreaterThan(diff.differingFraction, DiffTolerance.standard.maxDifferingFraction)

        let attachments = attachDiff(diff, actual: moved, reference: reference, named: "prestart-moved")
        XCTAssertEqual(attachments.map(\.name), ["prestart-moved-actual.png", "prestart-moved-reference.png", "prestart-moved-diff.png"])
    }

    /// The committed reference for this device (References/<device>/prestart.png).
    @MainActor func testPrestartMatchesItsReference() throws {
        try assertMatchesReference("prestart")
    }
}
