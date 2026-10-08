import UIKit
import XCTest

/// The colour-vision sweeps (#22, #111): render fixtures through each colour-vision filter (deuteranopia, protanopia,
/// tritanopia, greyscale, sunlight washout), each against its reference; their unfiltered twins are in
/// `RenderFixtureUITests`. A class of their own so that CI can leave them out of a pull request (`-skip-testing`) when
/// the change can't reach what they guard: the race's drawing, its colours and the filters (ci.yml's `sweeps` filter).
/// Main and nightly runs always run them.
///
/// Each test renders its fixtures in one launch (`assertAllMatchReferences`), and every render compares before a
/// failure ends the test, so each one that moved (or has no reference yet) reaches render-actuals in one CI run.
final class RenderFixtureFilterUITests: RenderFixtureTestCase {
    /// The five filters, as the fixtures' name suffixes.
    static let filters = ["deuteranopia", "protanopia", "tritanopia", "greyscale", "washout"]

    /// `name` through each filter: `name-deuteranopia`, …, `name-washout`.
    static func filtered(_ name: String) -> [String] { filters.map { "\(name)-\($0)" } }

    /// The prestart fleet through each filter, each render first checked to the edges of the frame against the
    /// unfiltered one (`assertFilterReachesEveryEdge`), then against its reference. One launch: the unfiltered render
    /// first, then the five. The iPad skips before any launch, as a reference test; `RaceViewVisionTests` checks the
    /// letterboxed race view's filter.
    @MainActor func testPrestartUnderFiltersMatchesReferences() throws {
        try skipOnIPad()
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        var plain: FixtureRender?
        try renderFixtures(["prestart"] + Self.filtered("prestart")) { name, render in
            guard let unfiltered = plain else {
                plain = render
                return
            }
            assertFilterReachesEveryEdge(render, unfiltered: unfiltered, named: name)
            try assertMatchesReference(name, render: render)
        }
    }

    /// The water in greyscale (#116), where the puffs must still read: light and patchy, and gusty offshore.
    @MainActor func testWaterInGreyscaleMatchesReferences() throws {
        try assertAllMatchReferences(["water-light-and-patchy-greyscale", "water-gusty-offshore-greyscale"])
    }

    /// The fleet (#117) just after the first boat finished, her ghost reading "not racing" through every filter (#30).
    @MainActor func testFleetUnderFiltersMatchesReferences() throws {
        try assertAllMatchReferences(Self.filtered("fleet"))
    }

    /// The compact live leaderboard (#268) through every filter (#62, #111).
    @MainActor func testLeaderboardUnderFiltersMatchesReferences() throws {
        try assertAllMatchReferences(Self.filtered("hud-leaderboard"))
    }

    /// Each venue's chart (#115) through tritanopia.
    @MainActor func testChartsUnderTritanopiaMatchReferences() throws {
        try assertAllMatchReferences(["chart-hollin-bay-tritanopia", "chart-saltings-reach-tritanopia",
                                      "chart-fellmere-tritanopia"])
    }

    /// The boat-side cues (#122) through every filter (#22).
    @MainActor func testBoatCuesUnderFiltersMatchReferences() throws {
        try assertAllMatchReferences(Self.filtered("cues"))
    }

    /// The rule calls' cues (#123) through every filter: the orange dashed lines, badges and red glows.
    @MainActor func testRuleCallCuesUnderFiltersMatchReferences() throws {
        try assertAllMatchReferences(Self.filtered("rules-call"))
    }

    /// The penalty's cues (#123) through every filter: the arc, the red and green glows and the "Turn" notice.
    @MainActor func testPenaltyCuesUnderFiltersMatchReferences() throws {
        try assertAllMatchReferences(Self.filtered("rules-penalty"))
    }

    /// The filter reaches every edge of the render (#111): around the frame, each corner and edge patch of the
    /// filtered render has moved from the unfiltered one (`FilterCoverage`). The scene's own `SKScene.filter`
    /// covered only a top-left part of the camera's view, leaving the right and bottom bands unfiltered, and a
    /// reference adopted from such a render would match it. `RenderFixtureUITests.testFixtureRendersIdenticallyTwice`
    /// is the control: across two launches, no patch of the unfiltered render moves.
    ///
    /// A failure here doesn't end the test, so the reference compare after it still leaves a moved render for
    /// render-actuals (`assertMatchesReference(_:render:)`), and one run reports both.
    @MainActor private func assertFilterReachesEveryEdge(_ render: FixtureRender, unfiltered plain: FixtureRender,
                                                         named name: String, file: StaticString = #filePath,
                                                         line: UInt = #line) {
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
}
