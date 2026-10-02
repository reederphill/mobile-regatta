import XCTest

/// A practice race on the practice driver (#61) runs to its finish state: the results.
final class RaceFinishUITests: RaceUITestCase {
    /// The watch for the results: never widened (#354, #361). With the launch the waits add up to 3.5 min, under the
    /// 5 min CI gives a test (`RaceUITestCase`).
    static let watchSeconds: TimeInterval = 180

    /// Nobody steers your boat, so the race closes 2 min after the first bot finishes, or at the 16 min time limit if
    /// that comes first (#86). It sails one lap (`-laps 1`) from a 10 s start sequence (`-startSeconds 10`): on seed 1
    /// the first bot finishes at tick 7,320 and the race closes at tick 10,913, 11,213 ticks from the launch, against
    /// 12,408 from the settings' 60 s start (#361, measured headless).
    ///
    /// `-timescale 32` is an upper bound, not the pace: a frame starts at most 8 ms of ticks (`GameScene.tickBudget`),
    /// so ticks/s is frames/s times the ticks that fit in 8 ms. On the GPU-less CI runner, painting, the race ran
    /// 80-100 ticks/s through the start, 20-40 ticks/s for the ~100 s of the first beat while the fleet is bunched,
    /// and 4-6x faster once it spreads: 99-197 s for one lap against this 180 s watch (#361, runs 36997609099 and
    /// 36994614457). So this test hides the scene (`-hideScene`): SpriteKit rasterises nothing while `render(_:)`
    /// still moves every node, and the results, SwiftUI's, show as before. What painting costs is
    /// `RacePaceUITests`' floor, and the render references are what it looks like.
    ///
    /// Each look for the results is one snapshot every 2 s (`watch`). A look that finds nothing, or times out
    /// while the app races, is tried again, where `waitForExistence` failed the test on one timed-out query. At the
    /// end the race's pace line (`reportPace`) and the margin are logged, pass or fail, so every CI run says how
    /// far the race got and how close it came.
    @MainActor func testPracticeRaceReachesTheFinish() throws {
        let app = launchRace(["-timescale", "32", "-laps", "1", "-startSeconds", "10", "-hideScene"])
        let results = app.staticTexts["race-results"]
        let started = Date()
        let finish = watch(results, until: started.addingTimeInterval(Self.watchSeconds)) { _ in true }
        let elapsed = Date().timeIntervalSince(started)
        let pace = reportPace(app, named: "race-finish-pace")
        let margin = String(format: "after %.1f s of the %.0f s watch (margin %.1f s)", elapsed, Self.watchSeconds,
                            Self.watchSeconds - elapsed)
        XCTContext.runActivity(named: "Margin: \(finish.seen ? "results" : "no results") \(margin)") { _ in }
        XCTAssertTrue(finish.seen, "the race never reached its results: no results \(margin); "
                      + (pace.line ?? "no pace line"))
        attachScreenshot(named: "race-finish")
    }
}
