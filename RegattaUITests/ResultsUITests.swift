import XCTest

/// The results sheet (#132, #24, #25): it slides up about 3 s after your finish horn while the race runs on behind it;
/// Change setup returns to the practice setup; home's Last race reopens the results until the next race ends.
/// CI only, like every UI test.
final class ResultsUITests: RaceUITestCase {
    /// `-demo` sails your boat. On seed 2 at one lap it finishes at tick 8,279 and the race closes at tick 10,267
    /// (measured headless): 1,988 ticks after your finish. `-timescale 8` holds the race to at most 240 ticks/s, so the
    /// close comes at least 8 s of wall-clock time after your finish and the 3 s delay is the sheet's, not the close's.
    @MainActor func testSheetAppearsAbout3sAfterFinishWhileSceneRenders() throws {
        let app = launchRace(["-demo", "-seed", "2", "-laps", "1", "-timescale", "8"])
        let status = app.staticTexts["race-status"]
        let finished = watch(status, every: 0.5, until: .now.addingTimeInterval(200)) { $0.label.hasPrefix("Finished") }
        XCTAssertTrue(finished.seen, "your boat never finished: \(finished.last?.label ?? "no status")")
        let finishSeen = Date.now
        let results = app.staticTexts["race-results"]
        XCTAssertFalse(results.exists, "the results were up the moment you finished")
        XCTAssertTrue(results.waitForExistence(timeout: 12), "the results never slid up after your finish")
        let delay = Date.now.timeIntervalSince(finishSeen)
        XCTAssertLessThan(delay, 10, "the results took \(delay) s to come up")
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
    /// its close: the results are up.
    @MainActor private func openSetupAndRaceToTheClose() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-seed", "1", "-laps", "1", "-startSeconds", "10", "-timescale", "32",
                               "-hideScene"]
        app.launch()
        let practice = app.buttons["practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 30), "no Practice on the home screen")
        XCTAssertFalse(app.buttons["last-race"].exists, "a fresh launch already has a Last race")
        practice.tap()
        startFromSetup(app)
        let results = app.staticTexts["race-results"]
        let finish = watch(results, until: .now.addingTimeInterval(200)) { _ in true }
        XCTAssertTrue(finish.seen, "the race never reached its results")
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
