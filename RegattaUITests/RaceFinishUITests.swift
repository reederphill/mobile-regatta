import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// Nobody steers your boat, so the race closes 2 min after the first bot finishes, or at the 16 min time
    /// limit if that comes first (#86). It sails one lap (`-laps 1`): on seed 1 the first bot finishes at tick 7,008
    /// and the race closes at tick 10,608, against 17,014 for the settings' two laps (#354, measured headless).
    ///
    /// `-timescale 32` is an upper bound, not the pace: a frame starts at most 8 ms of ticks
    /// (`GameScene.tickBudget`), and a tick of the eight-boat fleet costs about 0.9 ms in a Debug build on a Mac
    /// (more on a CI runner), so the race runs as fast as the simulator lets it. On CI that was 4-10x real time
    /// before #339 (about 120-290 ticks/s; two laps took 125-155 s of the 180 s wait) and 2x after it, when each
    /// cone's own shader slowed every frame (#354, fixed: one shared shader). One lap needs about 90 s at 120 ticks/s,
    /// half the 3 min wait; with the launch the waits add up to 3.5 min, under the 5 min CI gives a test
    /// (`RaceUITestCase`).
    ///
    /// Each look for the results is one snapshot every 2 s (`watch`). A look that finds nothing, or times out
    /// while the app races, is tried again, where `waitForExistence` failed the test on one timed-out query.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "32", "-laps", "1"])
        let results = app.staticTexts["race-results"]
        let finish = watch(results, until: .now.addingTimeInterval(180)) { _ in true }
        XCTAssertTrue(finish.seen, "the race never reached its results")
        attachScreenshot(named: "race-finish")
    }
}
