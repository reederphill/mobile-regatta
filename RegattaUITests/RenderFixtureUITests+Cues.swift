import UIKit
import XCTest

/// The boat-side cues (#122): the bot race on the default files in course-up, ladder lines on, your autohelm
/// pinching up the first beat: the yellow laylines, the faint ladder lines, your vermillion vane with its groove tick
/// and pinch arc, the sail's lifted luff, and the orange edge arrow to the windward mark off screen. Through every
/// vision filter (#22), plus a frame footing later up the beat. In a file of its own beside `RenderFixtureUITests`, as the
/// camera's are.
extension RenderFixtureUITests {
    @objc @MainActor func testBoatCuesMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["cues", "cues-deuteranopia", "cues-protanopia", "cues-tritanopia", "cues-greyscale", "cues-washout",
                     "cues-footed"] {
            try assertMatchesReference(name)
        }
    }
}
