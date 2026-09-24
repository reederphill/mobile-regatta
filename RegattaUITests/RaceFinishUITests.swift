import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Nobody steers your boat, so the race ends at the time limit after the bots finish: about 130 s at 8×
    /// on a fast Mac, so the wait allows a slow CI runner.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-autostart", "-seed", "1", "-timescale", "8"]
        app.launch()

        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 60), "no race clock after -autostart")
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 600), "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
