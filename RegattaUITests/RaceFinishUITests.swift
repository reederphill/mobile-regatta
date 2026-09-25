import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// Nobody steers your boat, so the race ends at the time limit after the bots finish: about 20 min of race,
    /// 40 s at 32×. The wait allows a slow CI runner. A tick costs about 0.15 ms in a Debug build and a frame
    /// runs at most 0.1 s of real time, so 32× is at most about 100 ticks a frame.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "32"])
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 600), "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
