import UIKit
import XCTest

/// A hint and its thin leader line (#129, #23) on the HUD: `hud-hint-leader` shows the red-glow hint pointing at the
/// nearest boat, early in the light-and-patchy race, course-up. In a file of its own beside `RenderFixtureUITests`.
/// CI records the reference; the owner approves it before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testHintLeaderLineMatchesItsReference() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        try assertMatchesReference("hud-hint-leader")
    }
}
