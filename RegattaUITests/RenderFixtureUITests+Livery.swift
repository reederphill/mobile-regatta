import UIKit
import XCTest

/// Liveries (#21, #119): each free skiff starter design's large render and chip, in fixed colours, on the water's
/// tone (`LiveryGalleryView`). The on-water scales, the open-water zoom and the pinch maximum, come with the boat's
/// livery (#372). In a file of its own beside `RenderFixtureUITests`, as the camera's are.
extension RenderFixtureUITests {
    @objc @MainActor func testLiveryAtThreeScalesMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["livery-large"] {
            try assertMatchesReference(name)
        }
    }
}
