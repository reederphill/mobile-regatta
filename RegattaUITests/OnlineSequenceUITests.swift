import XCTest

/// The online race sequence from fleet lock to Home again (#141) on the fake session (`-fakeServices joinable`,
/// `rejoinable`, `cancelled-race`): the briefing into the sequence and the race, the race menu, Leave before and
/// after the gun, Rejoin race after a drop, the background, the close while away, a cancel, Race again and the
/// rating badge. CI only, like every UI test; the state machine itself is unit-tested (`OnlineRaceControllerTests`).
///
/// The fake race (`FakeRaceDirector`) starts at fleet lock: 15 s of briefing, the gun 75 s after the lock, the close
/// `-raceSeconds` (20 without it) after the gun, the rating a second and a half later, all at `-timescale`. The
/// scripted queue locks four states, a second each on the same scale, after the join. At `-timescale 2` the gun is
/// some 40 s after the Race online tap.
final class OnlineSequenceUITests: RaceUITestCase {
    @MainActor private func launch(_ scenario: String, timescale: String = "2", _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario, "-timescale", timescale] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Race online, through the queue and the locked fleet's briefing, to the water.
    @MainActor private func sailToTheWater(_ app: XCUIApplication) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "no Race online")
        raceOnline.tap()
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 40), "no takeover")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 60), "the briefing didn't lead to the race")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 20), "no race clock on the water")
    }

    /// The race clock's tick, from its value.
    @MainActor private func tick(_ app: XCUIApplication) -> Int? {
        (try? app.staticTexts["race-clock"].snapshot())?.value.flatMap { Int("\($0)") }
    }

    /// Waits for the gun: the race clock's tick at zero or past it.
    @MainActor private func waitForTheGun(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        let seen = watch(app.staticTexts["race-clock"], every: 1, until: Date().addingTimeInterval(timeout)) { clock in
            (clock.value.flatMap { Int("\($0)") } ?? -1) >= 0
        }
        XCTAssertTrue(seen.seen, "the gun never came: the clock reads \(seen.last?.label ?? "nothing")")
    }

    /// Opens the race menu.
    @MainActor private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["race-pause"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no menu button on an online race")
        menu.tap()
        XCTAssertTrue(element(app, "pause-menu").waitForExistence(timeout: 10), "the menu button opened no menu")
    }

    /// Home, with Race online open again.
    @MainActor private func waitForRaceOnlineOpen(_ app: XCUIApplication, _ message: String) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20), "\(message): no Race online")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: raceOnline)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 15), .completed, "\(message): Race online stayed closed")
    }

    @MainActor private func sendToTheBackground(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5),
                      "the app didn't go to the background")
    }

    /// Fleet lock's briefing gives way to the race in the same cover: the start sequence with the menu button, the
    /// gun, and at the close the online results with Race again and Home.
    @MainActor func testFleetLockBriefingThenTheSequenceThenTheRace() {
        let app = launch("joinable")
        sailToTheWater(app)
        XCTAssertFalse(element(app, "briefing").exists, "the briefing is still up over the race")
        XCTAssertTrue(homeIsCovered(app), "Home shows through the race")
        XCTAssertEqual(app.buttons["race-pause"].label, "Race menu")
        XCTAssertLessThan(tick(app) ?? 0, 0, "the race came up after its gun")
        XCTAssertFalse(element(app, "race-joining").exists)
        waitForTheGun(app)
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 60), "no results at the close")
        XCTAssertTrue(app.buttons["results-raceAgain"].exists, "the online results have no Race again")
        XCTAssertTrue(app.buttons["results-menu"].exists, "the online results have no Home")
    }

    /// The race menu says the race continues, and it does: the clock runs on under it. It has the practice menu's
    /// toggles, Help and Leave race, and no Restart or Tuning.
    @MainActor func testRaceMenuKeepsTheRaceRunningAndHasThePracticeToggles() {
        let app = launch("joinable", timescale: "1")
        sailToTheWater(app)
        let before = tick(app)
        openMenu(app)
        XCTAssertTrue(app.staticTexts["Race continues"].exists, "the menu doesn't say the race continues")
        XCTAssertFalse(app.staticTexts["Paused"].exists)
        for id in ["pause-resume", "pause-help", "pause-leave"] {
            XCTAssertTrue(app.buttons[id].exists, "no \(id) on the race menu")
        }
        for id in ["pause-steering", "pause-camera", "pause-laylines", "pause-ladderLines"] {
            XCTAssertTrue(element(app, id).exists, "no \(id) on the race menu")
        }
        XCTAssertFalse(app.buttons["pause-restart"].exists, "an online race can be restarted")
        XCTAssertFalse(app.buttons["pause-tuning"].exists, "an online race has the tuning panel")

        Thread.sleep(forTimeInterval: 3)
        app.buttons["pause-resume"].tap()
        XCTAssertTrue(element(app, "pause-menu").waitForNonExistence(timeout: 10), "Resume left the menu up")
        let after = tick(app)
        XCTAssertNotNil(before)
        XCTAssertGreaterThanOrEqual((after ?? Int.min) - (before ?? 0), 60, "the race stopped under its menu")
        XCTAssertTrue(app.otherElements["race-viewport"].exists)
    }

    /// Leave race before the gun asks first, in the briefing's words: Stay keeps the seat, Leave goes home, where
    /// Race online opens again and nothing offers a way back.
    @MainActor func testLeaveInTheSequenceGoesHomeFree() {
        let app = launch("joinable", timescale: "1")
        sailToTheWater(app)
        openMenu(app)
        app.buttons["pause-leave"].tap()
        let stay = app.buttons["race-leave-confirm-stay"]
        XCTAssertTrue(stay.waitForExistence(timeout: 10), "Leave race didn't ask")
        XCTAssertTrue(app.staticTexts["Leave the race?"].exists && app.staticTexts["A bot takes your seat."].exists)
        stay.tap()
        XCTAssertTrue(stay.waitForNonExistence(timeout: 10), "Stay left the question up")
        XCTAssertTrue(app.otherElements["race-viewport"].exists, "Stay left the race")

        XCTAssertTrue(app.buttons["pause-leave"].waitForExistence(timeout: 10), "the menu went with the question")
        app.buttons["pause-leave"].tap()
        let leave = app.buttons["race-leave-confirm-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "Leave race didn't ask the second time")
        leave.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 15), "Leave left the race up")
        waitForRaceOnlineOpen(app, "after leaving before the gun")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a race she left offers a way back")
        XCTAssertFalse(element(app, "home-notice").exists, "leaving the race by hand posted a notice")
        XCTAssertFalse(app.buttons["last-race"].exists, "a race she left is Home's Last race")
    }

    /// Leave race after the gun is final (owner 2026-10-12): the question says she is scored as retired, and Home has
    /// Race online open again, with no Rejoin race, and no Last race row while the race runs on (it is her Last race
    /// once it closes, #163 G1).
    @MainActor func testLeaveAfterTheGunGoesHomeWithNoRejoin() {
        let app = launch("joinable", ["-raceSeconds", "240"])
        sailToTheWater(app)
        waitForTheGun(app)
        openMenu(app)
        app.buttons["pause-leave"].tap()
        let leave = app.buttons["race-leave-confirm-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "Leave race didn't ask")
        XCTAssertTrue(app.staticTexts["You'll be scored as retired."].exists, "the question doesn't say what leaving costs")
        XCTAssertFalse(app.staticTexts["A bot takes your seat."].exists)
        leave.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 15), "Leave left the race up")
        waitForRaceOnlineOpen(app, "after leaving after the gun")
        // The race runs on without her: still no way back.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a race she left offers a way back")
        XCTAssertTrue(app.buttons["race-online"].isEnabled)
        XCTAssertFalse(app.buttons["last-race"].exists, "a race she retired from is Home's Last race before it closes")
        XCTAssertFalse(element(app, "home-notice").exists)
    }

    /// A race she dropped out of (the app relaunched while it runs): Rejoin race stands in for Race online with the
    /// race clock counting, Practice stays, and at the close Race online is back with the race as Home's Last race
    /// and, once pushed, its rating.
    @MainActor func testADroppedRaceOffersRejoinWithTheClockUntilTheClose() {
        // The race is 38 s old at launch and closes 30 s later.
        let app = launch("rejoinable", timescale: "1", ["-raceSeconds", "30"])
        let rejoin = app.buttons["race-rejoin"]
        XCTAssertTrue(rejoin.waitForExistence(timeout: 30), "no Rejoin race for a race still running")
        XCTAssertTrue(rejoin.label.contains("Rejoin race"), "it reads \(rejoin.label)")
        XCTAssertFalse(app.buttons["race-online"].exists, "Race online is there beside Rejoin race")
        XCTAssertFalse(element(app, "queue-bar").exists)
        XCTAssertTrue(app.buttons["practice"].exists, "Practice went with Race online")
        let first = rejoin.value as? String
        XCTAssertTrue(first?.hasPrefix("0:") == true, "no race clock on Rejoin race: \(first ?? "nil")")
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", first ?? ""), object: rejoin)
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 10), .completed, "the race clock on Rejoin race stands still")

        XCTAssertTrue(rejoin.waitForNonExistence(timeout: 60), "Rejoin race outlived the race")
        waitForRaceOnlineOpen(app, "after the close")
        let lastRace = app.buttons["last-race"]
        XCTAssertTrue(lastRace.waitForExistence(timeout: 15), "the race that closed while she was away isn't Home's Last race")
        XCTAssertFalse(element(app, "home-notice").exists, "the close while away posted a notice")
        let rated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Rating plus 12"), object: lastRace)
        XCTAssertEqual(XCTWaiter().wait(for: [rated], timeout: 15), .completed, "no rating on the Last race row: \(lastRace.label)")
    }

    /// Rejoin race goes straight to the water, well into the race: no briefing, the menu there.
    @MainActor func testRejoinGoesStraightToTheWater() {
        let app = launch("rejoinable", timescale: "1", ["-raceSeconds", "180"])
        let rejoin = app.buttons["race-rejoin"]
        XCTAssertTrue(rejoin.waitForExistence(timeout: 30), "no Rejoin race")
        rejoin.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Rejoin race didn't lead to the water")
        XCTAssertFalse(element(app, "briefing").exists, "a rejoin shows the briefing")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 20), "no race clock after the rejoin")
        let seen = watch(app.staticTexts["race-clock"], every: 1, until: Date().addingTimeInterval(30)) { clock in
            (clock.value.flatMap { Int("\($0)") } ?? 0) >= 38 * 30
        }
        XCTAssertTrue(seen.seen, "the rejoined race isn't the one under way: tick \(seen.last?.value ?? "none")")
        XCTAssertTrue(element(app, "race-joining").waitForNonExistence(timeout: 10))
        openMenu(app)
        XCTAssertTrue(app.buttons["pause-leave"].exists)
    }

    /// The background mid-race is a drop, not a leave: back before the close she is on the water where the race now
    /// is, with no Home between and the connection line gone.
    @MainActor func testBackgroundMidRaceReturnsToTheWater() {
        let app = launch("joinable", ["-raceSeconds", "240"])
        sailToTheWater(app)
        waitForTheGun(app)
        let before = tick(app) ?? 0
        sendToTheBackground(app)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 15), "the race isn't up on return")
        XCTAssertTrue(homeIsCovered(app), "Home shows on return")
        XCTAssertFalse(app.buttons["race-rejoin"].exists)
        // 5 s away at twice the pace: the race is some 300 ticks on, not where she left it.
        let seen = watch(app.staticTexts["race-clock"], every: 1, until: Date().addingTimeInterval(30)) { clock in
            (clock.value.flatMap { Int("\($0)") } ?? Int.min) >= before + 240
        }
        XCTAssertTrue(seen.seen, "the race didn't sail on while she was away: tick \(seen.last?.value ?? "none"), was \(before)")
        XCTAssertTrue(element(app, "race-reconnecting").waitForNonExistence(timeout: 20), "still reconnecting")
        XCTAssertFalse(app.staticTexts["race-results"].exists)
    }

    /// The race closes while she is away: on return Home, with the race as its Last race and nothing said.
    @MainActor func testReturnAfterTheCloseShowsTheLastRaceRow() {
        // The close 12 s after the gun.
        let app = launch("joinable", ["-raceSeconds", "24"])
        sailToTheWater(app)
        waitForTheGun(app)
        sendToTheBackground(app)
        Thread.sleep(forTimeInterval: 18)
        app.activate()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 30), "a closed race is still up")
        waitForRaceOnlineOpen(app, "after a close while away")
        XCTAssertTrue(app.buttons["last-race"].waitForExistence(timeout: 15), "no Last race row for the race that closed")
        XCTAssertFalse(element(app, "home-notice").exists, "the close while away posted a notice")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a closed race offers a rejoin")
        XCTAssertFalse(app.staticTexts["race-results"].exists)
    }

    /// The server cancels the race: Home, with the notice, Race online open, and nothing kept of the race.
    @MainActor func testRaceCancelledGoesHomeWithTheNotice() {
        // Cancelled 8 s after the gun.
        let app = launch("cancelled-race")
        sailToTheWater(app)
        let notice = element(app, "home-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 90), "no notice for a cancelled race")
        XCTAssertTrue(notice.label.contains("The race was cancelled"), "the notice reads \(notice.label)")
        XCTAssertFalse(app.otherElements["race-viewport"].exists, "a cancelled race is still up")
        waitForRaceOnlineOpen(app, "after a cancel")
        XCTAssertFalse(app.buttons["last-race"].exists, "a cancelled race is Home's Last race")
        XCTAssertFalse(app.buttons["race-rejoin"].exists)
        XCTAssertFalse(app.staticTexts["race-results"].exists)
    }

    /// Race again from the results: Home, with the queue's bar running and the race kept as Last race.
    @MainActor func testRaceAgainFromTheResultsQueuesWithTheBarRunning() {
        let app = launch("joinable")
        sailToTheWater(app)
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "no results at the close")
        let raceAgain = app.buttons["results-raceAgain"]
        XCTAssertTrue(raceAgain.waitForExistence(timeout: 10), "no Race again on the online results")
        raceAgain.tap()
        XCTAssertTrue(element(app, "queue-bar").waitForExistence(timeout: 20), "Race again didn't queue")
        XCTAssertFalse(app.otherElements["race-viewport"].exists, "the race is still up")
        XCTAssertTrue(app.buttons["practice"].exists)
        XCTAssertTrue(app.buttons["last-race"].waitForExistence(timeout: 10), "the race isn't Home's Last race")
        XCTAssertFalse(element(app, "home-notice").exists)
    }

    /// Home from the results: the Last race row carries the rating change, and only that.
    @MainActor func testRatingBadgeLandsOnTheLastRaceRow() {
        let app = launch("joinable")
        sailToTheWater(app)
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "no results at the close")
        let home = app.buttons["results-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "no Home on the online results")
        home.tap()
        let lastRace = app.buttons["last-race"]
        XCTAssertTrue(lastRace.waitForExistence(timeout: 20), "no Last race row")
        let rated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Rating plus 12"), object: lastRace)
        XCTAssertEqual(XCTWaiter().wait(for: [rated], timeout: 15), .completed, "no rating on the Last race row: \(lastRace.label)")
        XCTAssertFalse(lastRace.label.contains("1512"), "the row shows the new rating too: \(lastRace.label)")
        waitForRaceOnlineOpen(app, "after Home from the results")
    }
}
