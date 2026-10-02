import UIKit
import XCTest

/// The results sheet on a sample race (#132), as off-water galleries (`ResultsGalleryView`): boats still sailing, and
/// the race closed, both with the Your race card. In a file of its own beside `RenderFixtureUITests`, as the practice
/// menus' are. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testResultsMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["results-live", "results-closed"] {
            try assertMatchesReference(name)
        }
    }
}
