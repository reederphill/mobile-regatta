import UIKit
import XCTest

/// The briefing (#130): a venue with current, with its current line, and a venue without current, both
/// practice briefings frozen at their start (`BriefingGalleryView`), and a practice briefing with rivals (#235). In a file of its own beside
/// `RenderFixtureUITests`, as the camera's are. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testBriefingMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["briefing-current", "briefing-steady", "briefing-rival"] {
            try assertMatchesReference(name)
        }
    }
}
