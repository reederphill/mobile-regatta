import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// Nobody steers your boat, so the race ends at the time limit after the bots finish: about 150 s at 8×,
    /// so the wait allows a slow CI runner.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "8"])
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 600), "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
