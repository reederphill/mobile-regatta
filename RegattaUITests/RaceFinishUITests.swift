import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// Nobody steers your boat, so the race closes 2 min after the first bot finishes, or at the 16 min time
    /// limit if that comes first (#86): at most 17 min from the start of the sequence, 32 s at 32×. With the
    /// old 3 min window the results came up 20-25 s after the race clock on both the iOS 26.5 and iOS 27
    /// runners, and the close comes no later now; the 3 min wait is 7 times that, for a slow CI runner, and with the launch the waits add up to 3.5 min,
    /// under the 5 min CI gives a test (`RaceUITestCase`). A tick costs about 0.15 ms in a Debug build and a frame
    /// runs at most 0.1 s of real time, so 32× is at most about 100 ticks a frame, and at most 8 ms of them
    /// (`GameScene.tickBudget`): a slower simulator runs the race slower than 32×, never a frame longer.
    ///
    /// Each look for the results is one snapshot every 2 s (`watch`). A look that finds nothing, or times out
    /// while the app races, is tried again, where `waitForExistence` failed the test on one timed-out query.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "32"])
        let results = app.staticTexts["race-results"]
        let finish = watch(results, until: .now.addingTimeInterval(180)) { _ in true }
        XCTAssertTrue(finish.seen, "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
