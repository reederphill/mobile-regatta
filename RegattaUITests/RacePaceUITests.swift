import XCTest

/// A painted practice race keeps a measured pace (#361): `RaceFinishUITests` hides the scene so its watch doesn't hang
/// on the CI runner's draw speed, and this test is where a slowdown in drawing the race still fails.
final class RacePaceUITests: RaceUITestCase {
    /// How long the race runs painted before its pace is read.
    static let paintedSeconds: TimeInterval = 45

    /// The fewest ticks a painted race may run in its first `paintedSeconds` from the race clock showing: half the
    /// slowest pace measured on CI. From the `Saw … race-clock` lines of the two slowest painted runs (#361), with a
    /// 10 s start (300 ticks) the race reaches the gun and tick ~1,000 at 84-93 ticks/s (about 15 s), then runs the
    /// rest of the 45 s at 43-48 ticks/s as the fleet bunches on the first beat:
    /// - run 36994614457, job 110810914004, attempt 2, iteration 1: -1,602 at 11.0 s to 1,114 at 43.3 s (84/s), then
    ///   to 2,270 at 70.2 s (43/s): about 1,300 + 1,270 = 2,570 ticks in 45 s;
    /// - run 36997609099, job 110807872407, iteration 1: -1,619 at 16.0 s to 959 at 43.8 s (93/s), then to 2,318 at
    ///   72.2 s (48/s): about 1,300 + 1,490 = 2,790 ticks.
    /// Half of 2,570, rounded down: 1,250. Runners vary about 2x run to run, so this catches a slowdown of 3-4x or
    /// worse (a per-cone shader's 2x, #339, it can't); the deterministic guard for that one cause is
    /// `ShadowConeTests.ribbonsDrawAsOneFaintLayer` (the fleet's ribbons share one shader, #377).
    static let floorTicks = 1_250

    /// Sails the settings' two laps, so even a fast runner is still racing when the pace is read. The probe is looked
    /// at every 15 s (`watch`, each look a query that steals main-thread time), then read once more at the end.
    @MainActor func testPaintedRaceKeepsItsPace() throws {
        let app = launchRace(["-timescale", "32", "-startSeconds", "10"])
        let probe = app.descendants(matching: .any)["race-pace"].firstMatch
        _ = watch(probe, every: 15, until: .now.addingTimeInterval(Self.paintedSeconds)) { _ in false }
        let pace = reportPace(app, named: "race-pace")
        let ticks = try XCTUnwrap(pace.ticks, "no pace from the race-pace probe")
        XCTAssertGreaterThanOrEqual(ticks, Self.floorTicks, "the painted race ran \(ticks) ticks in "
                                    + "\(Int(Self.paintedSeconds)) s, under the floor of \(Self.floorTicks): "
                                    + (pace.line ?? ""))
    }
}
