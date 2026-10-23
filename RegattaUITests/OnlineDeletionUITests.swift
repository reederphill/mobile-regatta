import XCTest

/// Delete my online data end to end (#166): dev player 9166 signs in, accepts the terms and races a queue race to its
/// close (a seat for the server to anonymise, an online Last race, a race counted on My boat, and analytics through
/// the gate), then Settings → Delete my online data → Delete. Home has no Last race and asks her to sign in, My boat
/// counts 0 races, and a relaunch leaves her signed out: the app doesn't sign her straight back in (O1), which would
/// make a fresh profile row with her Game Center id.
///
/// `scripts/e2e.sh` runs it in its own phase, `delete` (a 4 s queue and a 12 s race, as the race phase), then reads
/// Postgres: no text column names `T:dev-9166` or `G:dev-9166` but `data_deletions.game_player_id`, at least one
/// `race_players` seat is a `deleted:` id, and the device's analytics events grew during the phase. It skips outside
/// that phase, and without a server (`REGATTA_ONLINE_HOST`). That bought designs stay is the unit test's
/// (`OnlineDataDeleterTests.successClearsOnlineCachesKeepsPurchases`): paid designs are hidden until #169. CI only, like
/// every UI test.
final class OnlineDeletionUITests: XCTestCase {
    static let deletePhase = "delete"
    /// Hers alone: `T:dev-9166` / `G:dev-9166`, which the script's scan looks for.
    static let player = 9166

    private func host() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment[OnlineRaceUITests.hostVariable], !host.isEmpty else {
            throw XCTSkip("No server: \(OnlineRaceUITests.hostVariable) isn't set. scripts/e2e.sh starts one and runs this test.")
        }
        let running = environment[OnlineAccountUITests.phaseVariable].flatMap { $0.isEmpty ? nil : $0 }
        guard running == Self.deletePhase else {
            throw XCTSkip("Not this phase of scripts/e2e.sh: \(running ?? "the first") is running, this test is for \(Self.deletePhase).")
        }
        return host
    }

    @MainActor private func launch(host: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-onlineHost", host, "-devIdentity", "\(Self.player)"] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Home, with Race online open: on screen, not under the race cover.
    @MainActor private func waitForHome(_ app: XCUIApplication, _ message: String) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "\(message): no Race online")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: raceOnline)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 30), .completed, "\(message): Race online is \(raceOnline.label)")
    }

    /// My boat's locked earned designs' "n / N races", read from their tiles.
    @MainActor private func earnedProgress(_ app: XCUIApplication) -> [String] {
        let tiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'myboat-design-' AND label CONTAINS ' races'"))
        return tiles.allElementsBoundByIndex.map(\.label)
    }

    @MainActor private func openMyBoat(_ app: XCUIApplication) {
        let item = app.buttons["toolbar-myboat"]
        XCTAssertTrue(item.waitForExistence(timeout: 20), "no My boat button")
        item.tap()
        XCTAssertTrue(element(app, "page-myboat").waitForExistence(timeout: 20), "My boat didn't open")
    }

    @MainActor private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        waitForHome(app, "back from a page")
    }

    @MainActor func testDeletionClearsTheDeviceAndKeepsHerSignedOut() throws {
        let host = try host()
        // Share usage data on, as it is by default: the analytics through the gate are part of what the script checks.
        var app = launch(host: host, ["-resetSettings"])
        waitForHome(app, "at launch")

        // Race online: the terms (a retry of this test finds her held and signs her in again first), the queue, the
        // briefing, the race, its close 12 s after the gun, and Home.
        app.buttons["race-online"].tap()
        let agree = app.buttons["terms-agree"]
        if agree.waitForExistence(timeout: 20) { agree.tap() }
        XCTAssertTrue(element(app, "queue-bar").waitForExistence(timeout: 20), "Race online didn't join the queue")
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 30), "the fleet never locked")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 40), "no race after the briefing")
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "no results at the close")
        let home = app.buttons["results-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "no Home on the results")
        home.tap()
        waitForHome(app, "after the close")
        XCTAssertTrue(app.buttons["last-race"].waitForExistence(timeout: 20), "the closed race isn't Home's Last race")

        // Settings → Delete my online data: the plan, the dialog, Delete, the notice.
        let settings = app.buttons["toolbar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings button")
        settings.tap()
        XCTAssertTrue(element(app, "page-settings").waitForExistence(timeout: 20), "Settings didn't open")
        let delete = app.buttons["settings-deleteOnlineData"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete my online data")
        for _ in 0..<8 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "no confirmation dialog: the server gave no plan")
        confirm.tap()
        let notice = app.alerts["Your online data is deleted."]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "no deletion notice: \(app.alerts.firstMatch.label)")
        notice.buttons["OK"].tap()
        back(app)

        // Home: no Last race, and she is asked to sign in. My boat: 0 races.
        XCTAssertTrue(app.buttons["last-race"].waitForNonExistence(timeout: 10), "the online Last race outlived the deletion")
        XCTAssertTrue(app.buttons["lobby-sign-in"].waitForExistence(timeout: 20), "the lobby area doesn't ask her to sign in")
        openMyBoat(app)
        var progress = earnedProgress(app)
        XCTAssertFalse(progress.isEmpty, "no earned design's race count on My boat")
        XCTAssertTrue(progress.allSatisfy { $0.contains(", 0 / ") }, "My boat still counts her races: \(progress)")
        back(app)

        // A relaunch (My boat kept): ten seconds on Home, and she is still signed out. A session that reopened would
        // sign her in again, and the script's scan would find a players row.
        app = launch(host: host, ["-keepMyBoat"])
        waitForHome(app, "after the relaunch")
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "ten seconds on Home")], timeout: 10)
        XCTAssertTrue(app.buttons["lobby-sign-in"].exists, "the relaunch signed her back in")
        XCTAssertFalse(app.buttons["lobby-terms"].exists, "the relaunch opened a session: the terms are asked")
        XCTAssertFalse(app.buttons["last-race"].exists, "a Last race after the relaunch")
        openMyBoat(app)
        progress = earnedProgress(app)
        XCTAssertTrue(!progress.isEmpty && progress.allSatisfy { $0.contains(", 0 / ") }, "My boat's count after the relaunch: \(progress)")
    }
}
