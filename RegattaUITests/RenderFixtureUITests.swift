import UIKit
import XCTest

/// Render fixtures (#62): a race log replayed to a freeze tick, screenshot, and diffed pixel by pixel.
final class RenderFixtureUITests: RenderFixtureTestCase {
    /// The same fixture launched twice draws exactly the same pixels outside the home-indicator band. That's
    /// also the control for the vision fixtures' edge check: across two launches, no patch of the unfiltered
    /// render moves, so every one counts as unfiltered.
    @MainActor func testFixtureRendersIdenticallyTwice() throws {
        let first = try renderFixture("prestart")
        let second = try renderFixture("prestart")
        let diff = assertMatches(second.image, first.image, named: "prestart-twice", tolerance: .exact,
                                 ignoringBottomRows: first.homeIndicatorRows)
        XCTAssertFalse(diff.sizeMismatch)
        let control = try XCTUnwrap(FilterCoverage(filtered: second.image, unfiltered: first.image,
                                                   ignoringBottomRows: max(first.homeIndicatorRows,
                                                                           second.homeIndicatorRows)))
        XCTAssertEqual(control.unfiltered, control.patches, control.summary)
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

    /// The committed reference for this device (References/<device>/prestart.png).
    @MainActor func testPrestartMatchesItsReference() throws {
        try skipOnIPad()
        try assertMatchesReference("prestart")
    }

    // The same fixture through each colour-vision filter (#22, #111): with the unfiltered one above, a reference
    // diff in all six modes, each render first checked to the edges of the frame. One test each, so every
    // filter's render reaches render-actuals when it moves: a failed compare ends its test
    // (`continueAfterFailure = false`).

    @MainActor func testPrestartUnderDeuteranopiaMatchesItsReference() throws {
        try assertVisionFixtureMatchesItsReference("deuteranopia")
    }

    @MainActor func testPrestartUnderProtanopiaMatchesItsReference() throws {
        try assertVisionFixtureMatchesItsReference("protanopia")
    }

    @MainActor func testPrestartUnderTritanopiaMatchesItsReference() throws {
        try assertVisionFixtureMatchesItsReference("tritanopia")
    }

    @MainActor func testPrestartInGreyscaleMatchesItsReference() throws {
        try assertVisionFixtureMatchesItsReference("greyscale")
    }

    @MainActor func testPrestartInSunlightWashoutMatchesItsReference() throws {
        try assertVisionFixtureMatchesItsReference("washout")
    }

    /// Fixture `prestart-<vision>`: its render reaches every edge of the frame through the filter
    /// (`assertFilterReachesEveryEdge`), then matches its reference.
    ///
    /// Launches: the filtered fixture once, and the unfiltered one only if no vision test in this run has
    /// launched it yet (`unfilteredPrestart`), so two at most in a test and six across the five. The iPad skips
    /// before any launch, as a reference test; `RaceViewVisionTests` checks the letterboxed race view's filter.
    @MainActor private func assertVisionFixtureMatchesItsReference(_ vision: String, file: StaticString = #filePath,
                                                                    line: UInt = #line) throws {
        try skipOnIPad()
        let name = "prestart-\(vision)"
        let plain = try unfilteredPrestart(file: file, line: line)
        let render = try renderFixture(name, file: file, line: line)
        assertFilterReachesEveryEdge(render, unfiltered: plain, named: name, file: file, line: line)
        try assertMatchesReference(name, render: render, file: file, line: line)
    }

    /// The unfiltered prestart render, kept for the rest of the run once a vision test has launched it. Fixture
    /// renders are the same in every launch (`testFixtureRendersIdenticallyTwice`).
    @MainActor private static var unfilteredPrestartRender: FixtureRender?

    @MainActor private func unfilteredPrestart(file: StaticString, line: UInt) throws -> FixtureRender {
        if let render = Self.unfilteredPrestartRender { return render }
        let render = try renderFixture("prestart", file: file, line: line)
        Self.unfilteredPrestartRender = render
        return render
    }

    /// The filter reaches every edge of the render (#111): around the frame, each corner and edge patch of the
    /// filtered render has moved from the unfiltered one (`FilterCoverage`). The scene's own `SKScene.filter`
    /// covered only a top-left part of the camera's view, leaving the right and bottom bands unfiltered, and a
    /// reference adopted from such a render would match it.
    ///
    /// A failure here doesn't end the test, so the reference compare after it still leaves a moved render for
    /// render-actuals (`assertMatchesReference(_:render:)`), and one run reports both.
    @MainActor private func assertFilterReachesEveryEdge(_ render: FixtureRender, unfiltered plain: FixtureRender,
                                                         named name: String, file: StaticString, line: UInt) {
        let failure: String
        if let coverage = FilterCoverage(filtered: render.image, unfiltered: plain.image,
                                         ignoringBottomRows: max(render.homeIndicatorRows, plain.homeIndicatorRows)) {
            guard !coverage.unfiltered.isEmpty else { return }
            failure = "\(name) leaves \(coverage.unfiltered.map(\.name)) unfiltered (\(coverage.summary))"
        } else {
            failure = "\(name) isn't the unfiltered render's size"
        }
        if let png = render.image.pngData {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name)-coverage.png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let continues = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = continues }
        XCTFail(failure, file: file, line: line)
    }

    // The water (#116): puffs, lulls, ripple and whitecaps in two conditions, and the pressure (#289).

    /// Light and patchy (no whitecaps, sparse strong puffs, many lulls) against gusty offshore (whitecaps, puffs
    /// everywhere), both on the fun-pass @3 files, each also in greyscale, where the puffs must still read; and
    /// the pressure field on the @6 files, the whole course in view, on the water and the minimap.
    @MainActor func testWaterFixturesMatchReferences() throws {
        try assertAllMatchIPhoneReferences(["water-light-and-patchy", "water-gusty-offshore",
                                            "water-light-and-patchy-greyscale", "water-gusty-offshore-greyscale",
                                            "water-pressure"])
    }

    /// `assertMatchesReference` on iPhone (see `skipOnIPad`) for several fixtures in one test: each renders and
    /// compares before any failure ends the test, so every render that moved (or has no reference yet) reaches
    /// render-actuals in one CI run rather than one per run.
    @MainActor private func assertAllMatchIPhoneReferences(_ names: [String], file: StaticString = #filePath,
                                                           line: UInt = #line) throws {
        try skipOnIPad()
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in names {
            try assertMatchesReference(name, file: file, line: line)
        }
    }

    /// References are recorded on iPhone only; the iPad run skips a reference test on purpose. Anywhere else, a
    /// missing reference fails in CI rather than skipping.
    @MainActor private func skipOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
    }
}
