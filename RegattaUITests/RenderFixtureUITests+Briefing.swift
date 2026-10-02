import UIKit
import XCTest

/// The briefing (#130): a tidal venue with its tide graph and the one-off callouts, and a venue without current, both
/// practice briefings frozen at their start (`BriefingGalleryView`). In a file of its own beside
/// `RenderFixtureUITests`, as the camera's are. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testBriefingMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["briefing-tidal", "briefing-steady"] {
            try assertMatchesReference(name)
        }
    }
}
