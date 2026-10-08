import UIKit
import XCTest

/// Render fixtures (#62): a race log replayed to a freeze tick, screenshot, and diffed pixel by pixel.
final class RenderFixtureUITests: RenderFixtureTestCase {
    /// The same fixture launched twice draws exactly the same pixels outside the home-indicator band. That's
    /// also the control for the vision fixtures' edge check (`RenderFixtureFilterUITests`): across two launches,
    /// no patch of the unfiltered render moves, so every one counts as unfiltered.
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

    /// A `-fixtures` launch (`renderFixtures`) draws each fixture exactly as its own launch does: after a gallery and
    /// another race fixture in the same launch, prestart's pixels are a fresh launch's outside the home-indicator band.
    /// The render job's reference tests share a launch per test on the strength of this; it runs in every render job.
    @MainActor func testFixtureSequenceRendersAsFreshLaunches() throws {
        let fresh = try renderFixture("prestart")
        var sequenced: FixtureRender?
        try renderFixtures(["results-live", "hud-racing", "prestart"]) { name, render in
            if name == "prestart" { sequenced = render }
        }
        // A handshake that timed out falls back to a launch per fixture, which would pass here without testing a thing.
        XCTAssertFalse(Self.sequencesFailed, "a -fixtures handshake timed out, so the run launched each fixture alone")
        let render = try XCTUnwrap(sequenced)
        let diff = assertMatches(render.image, fresh.image, named: "prestart-sequenced", tolerance: .exact,
                                 ignoringBottomRows: max(render.homeIndicatorRows, fresh.homeIndicatorRows))
        XCTAssertFalse(diff.sizeMismatch)
    }

    /// The committed reference for this device (References/<device>/prestart.png).
    @MainActor func testPrestartMatchesItsReference() throws {
        try skipOnIPad()
        try assertMatchesReference("prestart")
    }

    // The water (#116): puffs, lulls, ripple and whitecaps in two conditions, and the pressure (#289).

    /// Light and patchy (no whitecaps, sparse strong puffs, many lulls) against gusty offshore (whitecaps, puffs
    /// everywhere), both on the fun-pass @3 files (each also in greyscale, in `RenderFixtureFilterUITests`); and
    /// the pressure field on the @6 files, the whole course in view, on the water and the minimap.
    @MainActor func testWaterFixturesMatchReferences() throws {
        try assertAllMatchReferences(["water-light-and-patchy", "water-gusty-offshore", "water-pressure"])
    }

    // The fleet (#117): hulls with their outlines, your glow, heel, sails, and a ghost that must read "not racing"
    // through every filter (#30).

    /// A bot race on the default files just after the first boat finished: her ghost and at least three racing
    /// boats around yours (through every vision filter in `RenderFixtureFilterUITests`).
    @MainActor func testFleetFixtureMatchesReferences() throws {
        try assertAllMatchReferences(["fleet"])
    }

    // The HUD (#114): clock, place, ground wind, minimap and the notice line over the scene.

    /// Before the gun (yellow sequence clock, place hidden), racing, OCS (place reads OCS, the OCS notice), and
    /// after the first finish (the yellow countdown to the close).
    @MainActor func testHUDFixturesMatchReferences() throws {
        try assertAllMatchReferences(["hud-prestart", "hud-racing", "hud-ocs", "hud-afterfirstfinish"])
    }

    // The live leaderboard (#268): the compact board under the clock and place, and tapped open.

    /// The compact board on the fleet log mid-race (you 4th of 6: leader, a skip, the boat ahead, you, the boat
    /// behind; through every vision filter in `RenderFixtureFilterUITests`), and the board open to the whole fleet.
    @MainActor func testLeaderboardMatchesReference() throws {
        try assertAllMatchReferences(["hud-leaderboard", "hud-leaderboard-expanded"])
    }
}
