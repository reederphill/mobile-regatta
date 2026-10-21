import XCTest

/// The results sheet (#132, #24, #25): it slides up about 3 s after your finish horn while the race runs on behind it;
/// Change setup returns to the practice setup; home's Last race reopens the results until the next race ends.
/// CI only, like every UI test.
final class ResultsUITests: RaceUITestCase {
    /// `-demo` sails your boat, one lap from a 10 s start, on `SeedTable.resultsSheet`: the first seed on which a
    /// headless probe has your boat finish at least 1,680 ticks before the race closes (#404, `scripts/pick-ui-seeds.sh`;
    /// it was re-picked by hand four times, 13, 77, 107, 394, as sim changes stopped the clock too soon). `-timescale 4`
    /// holds the race to at most 120 ticks/s (30 Hz × 4), so the close comes at least 14 s of wall-clock time after your
    /// finish and the 3 s delay is the sheet's, not the close's. It ran at 8× until a one-lap fleet no longer spread the
    /// 3,360 ticks that needed (#445).
    ///
    /// In race time (#572): CI's runner sailed this race at about 1× (24-30 ticks/s), not 4×, so a 200 s watch ran
    /// out on leg 1. The watch now follows the race clock to `SeedTable.resultsSheetFinishTick` (6,302 from the gun,
    /// 6,602 with the 10 s start: 236 s at 28 ticks/s, 275 s at 24), failing early once the clock is 30 s past it
    /// without her finish, and the delay is the app's own measure (`race-results-delay`), in wall-clock and race
    /// seconds: a look at the screen took up to 10 s on the runner, which read 11.5 s for a 3 s delay. The waits
    /// (launch 30 s, the finish 280 s, the delay 30 s, the sheet 15 s, the clock 20 s) need more than CI's 5 min, so
    /// it asks for 7 min, as `PracticeUITests.testFifteenBotRaceRunsFullLength` does.
    @MainActor func testSheetAppearsAbout3sAfterFinishWhileSceneRenders() throws {
        executionTimeAllowance = 420
        let app = launchRace(["-demo", "-seed", "\(SeedTable.resultsSheet)", "-laps", "1", "-startSeconds", "10",
                              "-timescale", "4"])
        let status = app.staticTexts["race-status"]
        let finishSecond = SeedTable.resultsSheetFinishTick / 30
        let clock = { (snapshot: any XCUIElementSnapshot) in Int(snapshot.value as? String ?? "") ?? .min }
        let finished = watch(status, every: 0.5, until: .now.addingTimeInterval(280)) {
            $0.label.hasPrefix("Finished") || clock($0) > finishSecond + 30
        }
        let seen = finished.last.map { "\($0.label) at race second \(clock($0))" } ?? "no status"
        if finished.last?.label.hasPrefix("Finished") != true { reportPace(app, named: "results-sheet-pace") }
        XCTAssertTrue(finished.seen, "the race didn't reach your boat's finish, at race second \(finishSecond), in "
                      + "280 s: \(seen)")
        XCTAssertTrue(finished.last?.label.hasPrefix("Finished") == true,
                      "your boat never finished: \(seen), 30 s past the probe's finish at \(finishSecond)")

        // The app's own measure of the delay: wall-clock seconds, then race seconds, from your finish horn.
        let delayProbe = app.descendants(matching: .any)["race-results-delay"]
        let up = watch(delayProbe, every: 0.5, until: .now.addingTimeInterval(30)) { $0.label == "Results up" }
        XCTAssertTrue(up.seen, "the results never slid up after your finish")
        let delay = (up.last?.value as? String ?? "").split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(delay.count, 2, "\(delayProbe) read \(up.last?.value as? String ?? "no value")")
        let (wall, race) = (delay[0], delay[1])
        XCTContext.runActivity(named: "Results up \(wall) s after your finish, \(race) race seconds") { _ in }
        XCTAssertGreaterThanOrEqual(wall, 3, "the results were up \(wall) s after your finish, before the sheet's 3 s")
        XCTAssertLessThan(wall, 10, "the results took \(wall) s to come up")
        // The close is at least 1,680 ticks after her finish: before it, the sheet is the delay's.
        XCTAssertGreaterThan(race, 0, "the race stood still between your finish and the results")
        XCTAssertLessThan(race, 1680 / 30, "the results came up \(race) race seconds after your finish, at the close")
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 15), "the results sheet isn't on screen")
        // The race keeps running and drawing behind the sheet: the viewport is still there and its clock moves on.
        XCTAssertTrue(app.otherElements["race-viewport"].exists, "the race viewport went away under the results")
        let before = Int(status.value as? String ?? "") ?? 0
        let moved = watch(status, every: 1, until: .now.addingTimeInterval(20)) {
            (Int($0.value as? String ?? "") ?? 0) > before
        }
        XCTAssertTrue(moved.seen, "the race clock stood still behind the results")
        attachScreenshot(named: "results-after-finish")
    }

    /// The results' Change setup returns to the practice setup page (#25), the race cover gone.
    @MainActor func testChangeSetupReturnsToPracticeSetup() throws {
        executionTimeAllowance = 420
        let app = openSetupAndRaceToTheClose()
        app.buttons["results-changeSetup"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page-practiceSetup"].firstMatch.waitForExistence(timeout: 15),
                      "Change setup didn't return to the practice setup")
        XCTAssertTrue(app.descendants(matching: .any)["race-cover"].firstMatch.waitForNonExistence(timeout: 10),
                      "the race cover stayed up")
    }

    /// Home's Last race appears once a race has ended, reopens its results with Close only, and stays when the next
    /// race is left mid-race: it lasts until the next race ends (#24, #25).
    @MainActor func testLastRaceRowReopensResultsUntilNextRaceEnds() throws {
        executionTimeAllowance = 420
        let app = openSetupAndRaceToTheClose()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "results-row").count, 10,
                       "the results don't hold the ten boats")
        app.buttons["results-menu"].tap()
        let lastRace = app.buttons["last-race"]
        XCTAssertTrue(lastRace.waitForExistence(timeout: 15), "no Last race on home after the race")
        let summary = lastRace.label
        XCTAssertTrue(summary.contains("of 10") || summary.contains("DSQ") || summary.contains("OCS"),
                      "Last race reads \(summary)")

        lastRace.tap()
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 10), "Last race didn't reopen the results")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "results-row").count, 10)
        XCTAssertFalse(app.buttons["results-sailAgain"].exists, "the reopened results offer Sail again")
        app.buttons["results-close"].tap()
        XCTAssertTrue(app.staticTexts["race-results"].waitForNonExistence(timeout: 10), "Close didn't close the results")

        // The next race, left mid-race, doesn't end: the row stays as it was.
        app.buttons["practice"].tap()
        startFromSetup(app)
        let pause = app.buttons["race-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "no pause button")
        pause.tap()
        XCTAssertTrue(app.buttons["pause-leave"].waitForExistence(timeout: 10), "the pause menu didn't open")
        app.buttons["pause-leave"].tap()
        XCTAssertTrue(lastRace.waitForExistence(timeout: 15), "Last race went away after a race left mid-race")
        XCTAssertEqual(lastRace.label, summary, "a race left mid-race replaced the last race")
    }

    /// Home → Practice → Start race → Ready, a one-lap race on the default ten boats at `-timescale 32` that nobody
    /// steers, from a 10 s start with the scene hidden (as `PracticeUITests.testFifteenBotRaceRunsFullLength`), run to
    /// its close: the results are up. The beat is 120 m (`-beatMetres 120`): on the full beat a slow runner sailed
    /// skiff@9's race past the 200 s watch about every other run (#504's and #505's CI).
    ///
    /// The watch is sized in race ticks (#572): the race runs at whatever ticks a second the runner manages, not 32×,
    /// and on 120 m it still ran past a 200 s watch on main's scheduled CI (79baafcb; 175 s on the retry).
    /// `PracticeSetupTests.tenBoatUITestRaceClosesInsideItsTickBudget` sails the same race without the UI and holds its
    /// close under 7,100 ticks (6,759 on skiff@9), which take 254 s at the slowest pace CI has run a race at, 28 ticks a second: the watch
    /// is 330 s, as the sixteen-boat test's, and the tests calling this ask for 7 min (`executionTimeAllowance`).
    @MainActor private func openSetupAndRaceToTheClose() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-seed", "1", "-laps", "1", "-startSeconds", "10", "-timescale", "32",
                               "-hideScene", "-beatMetres", "120"]
        app.launch()
        let practice = app.buttons["practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 30), "no Practice on the home screen")
        XCTAssertFalse(app.buttons["last-race"].exists, "a fresh launch already has a Last race")
        practice.tap()
        startFromSetup(app)
        let results = app.staticTexts["race-results"]
        let finish = watch(results, until: .now.addingTimeInterval(330)) { _ in true }
        if !finish.seen {
            let ticks = reportPace(app, named: "results-race-pace").ticks
            XCTFail("the race never reached its results: \(ticks.map(String.init) ?? "unknown") ticks run in 330 s, "
                    + "its close is inside 7,100")
        }
        return app
    }

    /// Start race on the setup page, then the briefing's Ready: the race.
    @MainActor private func startFromSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["page-practiceSetup"].firstMatch.waitForExistence(timeout: 20),
                      "Practice didn't push its setup")
        let start = app.buttons["practice-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no Start race on the practice setup")
        start.tap()
        let ready = app.buttons["briefing-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Start race didn't show the briefing's Ready")
        ready.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Ready didn't start the race")
    }
}
