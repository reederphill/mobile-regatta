import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// Nobody steers your boat, so the race ends at the time limit after the bots finish: about 20 min of race,
    /// 40 s at 32×. The results came up 20-25 s after the race clock on both the iOS 26.5 and iOS 27 runners;
    /// the 3 min wait is 7 times that, for a slow CI runner, and with the launch it stays under the 5 min CI
    /// gives a test (`RaceUITestCase`). A tick costs about 0.15 ms in a Debug build and a frame
    /// runs at most 0.1 s of real time, so 32× is at most about 100 ticks a frame, and at most 8 ms of them
    /// (`GameScene.tickBudget`): a slower simulator runs the race slower than 32×, never a frame longer.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "32"])
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 180), "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
