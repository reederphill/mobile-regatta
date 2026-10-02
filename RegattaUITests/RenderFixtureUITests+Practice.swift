import UIKit
import XCTest

/// The practice setup page on a fresh install's choices and the pause menu at the device defaults (#131), as off-water
/// galleries (`MenuGalleryView`). In a file of its own beside `RenderFixtureUITests`, as the briefing's are. CI records
/// the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testPracticeMenusMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["practice-setup", "pause-menu"] {
            try assertMatchesReference(name)
        }
    }
}
