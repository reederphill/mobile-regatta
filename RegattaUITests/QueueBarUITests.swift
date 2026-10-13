import XCTest

/// The queue from Race online to the locked fleet's briefing (#140) on the fake services' scripted queue
/// (`-fakeServices joinable`, `joinable-hold`): the bar on Home and every pushed page, Leave, the hold, the background,
/// and the takeover over a page and over a practice race, with the briefing's Leave. CI only, like every UI test; the
/// state machine itself is unit-tested (`QueueControllerTests`). What follows the briefing is `OnlineSequenceUITests`'
/// (#141).
///
/// The scripted queue gives a state a second, slowed by `-timescale` (a join is still answered within 2 s):
/// `joinable` locks four states after the first, `joinable-hold` seven, its first three a hold. The takeover's
/// briefing counts its 15 s on the same scale.
final class QueueBarUITests: RaceUITestCase {
    @MainActor private func launch(_ scenario: String, timescale: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario, "-timescale", timescale] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Taps Race online and waits for the bar.
    @MainActor private func joinQueue(_ app: XCUIApplication) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "no Race online")
        XCTAssertTrue(raceOnline.isEnabled, "Race online is closed on a joinable queue")
        raceOnline.tap()
        XCTAssertTrue(element(app, "queue-bar").waitForExistence(timeout: 15), "Race online didn't show the queue bar")
    }

    /// The bar's words, once they contain `text`.
    @MainActor private func waitForStatus(_ app: XCUIApplication, containing text: String, timeout: TimeInterval,
                                          _ message: String) {
        let status = element(app, "queue-bar-status")
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", text), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [matched], timeout: timeout), .completed,
                       "\(message): \(status.exists ? status.label : "no bar")")
    }

    /// Race online joins the queue: the bar stands in for the button, Practice stays, and the bar is over every page
    /// pushed from Home, above its navigation bar.
    @MainActor func testRaceOnlineQueuesAndTheBarRidesEveryPage() {
        // A state every 20 s: the lock is minutes away.
        let app = launch("joinable-hold", timescale: "0.05")
        joinQueue(app)
        XCTAssertFalse(app.buttons["race-online"].exists, "Race online is still there beside the bar")
        XCTAssertTrue(app.buttons["practice"].exists, "Practice went with Race online")
        XCTAssertTrue(app.buttons["queue-bar-leave"].waitForExistence(timeout: 30), "no Leave on the bar once queued")
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "the stub alert came up on the fakes")

        let pages = [("toolbar-profile", "page-profile", "Profile"), ("toolbar-myboat", "page-myboat", "My boat"),
                     ("toolbar-help", "page-help", "Help"), ("toolbar-settings", "page-settings", "Settings"),
                     ("practice", "page-practiceSetup", "Practice")]
        for (item, page, title) in pages {
            let button = app.buttons[item]
            XCTAssertTrue(button.waitForExistence(timeout: 20), "no \(item) while queued")
            button.tap()
            XCTAssertTrue(element(app, page).waitForExistence(timeout: 20), "\(item) didn't push \(page) while queued")
            let bar = element(app, "queue-bar")
            XCTAssertTrue(bar.exists, "no queue bar over \(page)")
            let navigationBar = app.navigationBars[title]
            XCTAssertTrue(navigationBar.waitForExistence(timeout: 10), "no navigation bar on \(page)")
            XCTAssertLessThanOrEqual(bar.frame.maxY, navigationBar.frame.minY + 1, "the bar isn't above \(page)'s navigation bar")
            XCTAssertTrue(app.buttons["queue-bar-leave"].isHittable, "Leave can't be tapped over \(page)")
            navigationBar.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["practice"].waitForExistence(timeout: 20), "back didn't return home from \(page)")
        }
        XCTAssertTrue(element(app, "queue-bar").exists, "the bar went away on the way back")
    }

    /// Leave on the bar: out of the queue at once, Race online back, nothing said.
    @MainActor func testLeaveFromTheBarGoesIdle() {
        let app = launch("joinable", timescale: "0.1")
        joinQueue(app)
        let leave = app.buttons["queue-bar-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 30), "no Leave on the bar once queued")
        XCTAssertEqual(leave.label, "Leave queue")
        leave.tap()
        XCTAssertTrue(element(app, "queue-bar").waitForNonExistence(timeout: 10), "Leave left the bar up")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 10), "Race online didn't come back")
        XCTAssertTrue(raceOnline.isEnabled, "Race online is closed after leaving the queue")
        XCTAssertFalse(element(app, "home-notice").exists, "leaving by hand posted a notice")
        // The queue is free: Race online joins again.
        joinQueue(app)
    }

    /// A hold (the lock waits for a running race's finishers): the bar says so, keeps the waiting count, and counts no
    /// seconds.
    @MainActor func testHoldShowsWaitingWithoutSeconds() {
        // A state every 10 s: the hold's three states last half a minute.
        let app = launch("joinable-hold", timescale: "0.1")
        joinQueue(app)
        waitForStatus(app, containing: "waiting for finishers", timeout: 25, "the bar doesn't say it is a hold")
        let label = element(app, "queue-bar-status").label
        XCTAssertTrue(label.localizedCaseInsensitiveContains("3 waiting"), "the hold lost the waiting count: \(label)")
        XCTAssertFalse(label.localizedCaseInsensitiveContains("seconds"), "a hold counts seconds: \(label)")
        XCTAssertTrue(app.buttons["queue-bar-leave"].exists, "no Leave during a hold")
    }

    /// The app sent to the background while queued leaves the queue; Home says so on return.
    @MainActor func testBackgroundWhileQueuedPostsTheNotice() {
        let app = launch("joinable-hold", timescale: "0.05")
        joinQueue(app)
        XCTAssertTrue(app.buttons["queue-bar-leave"].waitForExistence(timeout: 30), "never queued")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5),
                      "the app didn't go to the background")
        app.activate()
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 15), "Race online isn't back after the background")
        XCTAssertFalse(element(app, "queue-bar").exists, "still queued after the background")
        let notice = element(app, "home-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "no notice on return")
        XCTAssertTrue(notice.label.contains("You left the queue"), "the notice doesn't say she left the queue: \(notice.label)")
        // The next try clears it.
        joinQueue(app)
        XCTAssertFalse(element(app, "home-notice").exists, "the notice outlived the next Race online")
    }

    /// Fleet lock while Settings is pushed: the page goes, the locked fleet's briefing takes the screen with its
    /// countdown and Leave, and its end leads to the race it briefed (#141), not back to Settings.
    @MainActor func testFleetLockTakesOverSettingsAndShowsTheBriefing() {
        // A state every 4 s: the lock some 15 s after the join, the briefing a minute long.
        let app = launch("joinable", timescale: "0.25")
        joinQueue(app)
        app.buttons["toolbar-settings"].tap()
        XCTAssertTrue(element(app, "page-settings").waitForExistence(timeout: 20), "Settings didn't push while queued")

        let briefing = element(app, "briefing")
        XCTAssertTrue(briefing.waitForExistence(timeout: 40), "fleet lock didn't take over Settings")
        XCTAssertTrue(app.buttons["briefing-leave"].exists, "no Leave on the locked fleet's briefing")
        XCTAssertTrue(element(app, "briefing-countdown").exists, "the locked fleet's briefing doesn't count down")
        XCTAssertFalse(app.buttons["briefing-ready"].exists, "the locked fleet's briefing has Ready")
        XCTAssertFalse(element(app, "queue-bar").exists, "the bar rides the takeover")
        XCTAssertFalse(element(app, "queue-chip").exists, "the chip rides the takeover")

        // Its end: the race, in the same cover, with Settings gone under it.
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 100), "the briefing didn't lead to the race")
        XCTAssertFalse(briefing.exists, "the briefing is still up over the race")
        XCTAssertFalse(element(app, "page-settings").exists, "Settings is still pushed after the takeover")
        XCTAssertTrue(homeIsCovered(app), "the briefing's end led home")
    }

    /// Fleet lock in the middle of a practice race: the chip rode over it, the race is dropped for the briefing, and
    /// nothing of it is kept as Home's Last race.
    @MainActor func testFleetLockDropsAPracticeRaceMidwayWithNoLastRaceRow() {
        // A state every 10 s: the lock some 70 s after the join, time to get a practice race going.
        let app = launch("joinable-hold", timescale: "0.1", ["-seed", "1"])
        joinQueue(app)
        app.buttons["practice"].tap()
        let start = app.buttons["practice-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "no Start race on the practice setup")
        start.tap()
        let ready = app.buttons["briefing-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Start race didn't show the practice briefing")
        XCTAssertTrue(element(app, "queue-chip").waitForExistence(timeout: 10), "no chip over the practice briefing")
        XCTAssertFalse(app.buttons["briefing-leave"].exists, "a practice briefing has the locked fleet's Leave")
        ready.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Ready didn't start the race")
        XCTAssertTrue(element(app, "queue-chip").waitForExistence(timeout: 10), "no chip over the practice race")
        XCTAssertTrue(app.buttons["queue-chip-leave"].exists, "the chip has no x")

        let leave = app.buttons["briefing-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 120), "fleet lock didn't take over the practice race")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 10), "the practice race is still up")
        XCTAssertFalse(app.staticTexts["race-results"].exists, "the dropped race shows results")
        XCTAssertFalse(element(app, "queue-chip").exists, "the chip rides the takeover")

        leave.tap()
        let confirm = app.buttons["briefing-leave-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Leave didn't ask")
        confirm.tap()
        XCTAssertTrue(app.buttons["practice"].waitForExistence(timeout: 15), "leaving the briefing didn't lead home")
        XCTAssertFalse(app.buttons["last-race"].exists, "a race dropped midway left a Last race row")
        XCTAssertFalse(element(app, "page-practiceSetup").exists, "the practice setup is still pushed after the takeover")
    }

    /// The briefing's Leave asks first: Stay keeps the seat, Leave goes home, where Race online opens again within a
    /// few seconds and nothing is said.
    @MainActor func testBriefingLeaveConfirmsThenGoesHome() {
        // A state every 4 s: the lock some 15 s after the join, the briefing a minute long.
        let app = launch("joinable", timescale: "0.25")
        joinQueue(app)
        let leave = app.buttons["briefing-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 60), "no takeover")
        leave.tap()
        let stay = app.buttons["briefing-leave-stay"]
        XCTAssertTrue(stay.waitForExistence(timeout: 10), "Leave didn't ask")
        XCTAssertTrue(app.staticTexts["Leave the race?"].exists && app.staticTexts["A bot takes your seat."].exists)
        stay.tap()
        XCTAssertTrue(stay.waitForNonExistence(timeout: 10), "Stay left the question up")
        XCTAssertTrue(element(app, "briefing").exists, "Stay left the briefing")

        leave.tap()
        let confirm = app.buttons["briefing-leave-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Leave didn't ask the second time")
        confirm.tap()
        XCTAssertTrue(element(app, "briefing").waitForNonExistence(timeout: 10), "Leave left the briefing up")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 15), "leaving didn't lead home")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: raceOnline)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 15), .completed, "Race online stayed closed after leaving the race")
        XCTAssertFalse(element(app, "home-notice").exists, "leaving the race by hand posted a notice")
    }

    /// A cooldown and a suspension close Race online under their lines (#161's wording), with no bar.
    @MainActor func testCooldownAndSuspensionDisableRaceOnlineWithTheirLines() {
        for (scenario, line) in [("cooldown", "Cooling off "), ("suspended", "Racing paused until ")] {
            let app = launch(scenario, timescale: "1")
            let raceOnline = app.buttons["race-online"]
            XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "\(scenario): no Race online")
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isEnabled == false AND label CONTAINS %@", line), object: raceOnline)
            XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 15), .completed,
                           "\(scenario): Race online isn't closed under \"\(line)\": \(raceOnline.label)")
            XCTAssertFalse(element(app, "queue-bar").exists, "\(scenario): a queue bar")
            XCTAssertTrue(app.buttons["practice"].isEnabled, "\(scenario): Practice is closed too")
        }
    }
}
