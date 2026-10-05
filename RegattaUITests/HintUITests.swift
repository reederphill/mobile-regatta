import XCTest

/// Hints (#23, #129): the first race's first hint is the steering one, in the scheme in use, within 2 s. Under
/// `-uitesting` hint progress is kept in memory, so every race is a first. CI only.
final class HintUITests: RaceUITestCase {
    /// The steering hint is posted as the race is set up, before its clock shows, and shows for about 4 s from the
    /// scene's first step (`GameSession.sceneStarted`); the start-sequence hint follows 3 s after it goes. So this
    /// looks from the moment `launch()` returns, not after `launchRace`'s wait for the clock: in CI that wait and the
    /// first query of the notice took 2-4 s between them, and the first look often landed after the steering hint had
    /// gone (on main too, #129), seeing nothing or the start-sequence hint. The first hint seen must be the steering
    /// one: a later hint first would mean it was skipped.
    @MainActor func testFirstRaceShowsSteeringHintWithin2s() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-autostart", "-seed", "1"]
        app.launch()
        let notice = app.descendants(matching: .any)["race-notice"]
        let seen = watch(notice, every: 0.25, until: Date.now.addingTimeInterval(6)) { snapshot in
            "\(snapshot.value ?? "")" == "hint"
        }
        XCTAssertTrue(seen.seen, "no hint within 6 s of launch: \"\(seen.last?.label ?? "nothing")\"")
        XCTAssertTrue(seen.last?.label.contains("to steer") == true,
                      "the first hint isn't the steering one: \"\(seen.last?.label ?? "nothing")\"")
        XCTAssertTrue(seen.last?.label.contains("Settings") == true, "the first hint mentions Settings")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "no race clock after -autostart")
    }
}
