import UIKit
import XCTest

/// The results sheet on a sample race (#132), as off-water galleries (`ResultsGalleryView`): boats still sailing, and
/// the race closed, both with the Your race card; and the closed race with practice rivals (#235). In a file of its own beside `RenderFixtureUITests`, as the practice
/// menus' are. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testResultsMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["results-live", "results-closed", "results-rival"] {
            try assertMatchesReference(name)
        }
    }

    /// The online results (#133) on the fake online race: mid-race with your rating pending, closed and rated
    /// (provisional), and closed unrated. Separate from the practice ones, which must not move.
    @objc @MainActor func testOnlineResultsMatchReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["results-online-live", "results-online-rated", "results-online-unrated"] {
            try assertMatchesReference(name)
        }
    }
}
