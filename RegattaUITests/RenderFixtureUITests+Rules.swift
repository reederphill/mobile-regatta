import UIKit
import XCTest

/// The rule cues (#123) on the fleet bot race in course-up, through every vision filter (#22): `rules-call` a few
/// seconds after two calls, with their orange dashed lines and rule-number badges, your penalty arc counting the
/// complete deadline and ⚠ glyphs over the boats you keep clear of while turning (21.2); `rules-penalty` before your
/// turn is started, the arc counting the start deadline, ⚠ and chevron glyphs, and the HUD's "Turn" notice. In a file
/// of its own beside `RenderFixtureUITests`, as the cues' are.
extension RenderFixtureUITests {
    @objc @MainActor func testRuleCuesMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for base in ["rules-call", "rules-penalty"] {
            for vision in ["", "-deuteranopia", "-protanopia", "-tritanopia", "-greyscale", "-washout"] {
                try assertMatchesReference(base + vision)
            }
        }
    }
}
