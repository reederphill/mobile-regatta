import XCTest

/// The real queue and the race it leads to, end to end (#162): the app as a dev player (`-devIdentity`) against a real
/// server, from Race online through the queue's bar, fleet lock, the briefing, the race and its close; Leave in the
/// briefing; Rejoin race after a drop; Leave race after the gun; the livery the server keeps; a second person in the
/// fleet; and a server killed under a race.
///
/// `scripts/e2e.sh` runs these in phases, each a server of its own settings on the same Postgres, and names the phase
/// in `REGATTA_E2E_PHASE`; a test skips outside its phase, and without a server (`REGATTA_ONLINE_HOST`):
/// - `race`: the queue locks 4 s after the join, a queue race closes 12 s after the gun, and a race everyone dropped
///   out of waits two minutes for someone to come back.
/// - `pair`: the queue locks 30 s after the first join, and the script queues a headless second person
///   (`regatta-loadclient --queue-player 7001`) beside the app.
/// - `kill`: the script kills the server while the app is in a race, and starts it again on the same port.
///
/// One simulator runs one app, so "two people" here is the app and a headless client; two apps in one race is the
/// local demo (`scripts/demo-online.sh`). CI only, like every UI test.
final class OnlineQueueRaceUITests: XCTestCase {
    static let racePhase = "race"
    static let pairPhase = "pair"
    static let killPhase = "kill"
    /// The headless second person of the pair phase: "Dev 7001".
    static let secondPlayer = 7001

    private func host(inPhase phase: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment[OnlineRaceUITests.hostVariable], !host.isEmpty else {
            throw XCTSkip("No server: \(OnlineRaceUITests.hostVariable) isn't set. scripts/e2e.sh starts one and runs this test.")
        }
        let running = environment[OnlineAccountUITests.phaseVariable].flatMap { $0.isEmpty ? nil : $0 }
        guard running == phase else {
            throw XCTSkip("Not this phase of scripts/e2e.sh: \(running ?? "the first") is running, this test is for \(phase).")
        }
        return host
    }

    /// A dev player nobody has been before.
    private func newPlayer() -> Int { Int.random(in: 200_000...999_999_999) }

    @MainActor private func launch(host: String, player: Int, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-onlineHost", host, "-devIdentity", "\(player)"] + extra
        app.launch()
        return app
    }

    /// Puts the dev player in a contract situation on the server (`POST /dev/situation`); every one used here accepts
    /// her terms.
    private func arrange(host: String, player: Int, service: String, situation: String) async throws {
        let url = try XCTUnwrap(URL(string: "http://\(host)/dev/situation?service=\(service)&situation=\(situation)"
            + "&teamPlayerID=T:dev-\(player)&gamePlayerID=G:dev-\(player)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, "\(service).\(situation): \(String(decoding: body, as: UTF8.self))")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Home with the session open and the terms accepted: the lobby area asks for nothing.
    @MainActor private func waitForTheSession(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 30), "no Race online")
        XCTAssertTrue(app.staticTexts["Lobby"].waitForExistence(timeout: 30), "no session for a player with the terms accepted")
    }

    /// Race online, into the queue: the bar, not the stand-in alert.
    @MainActor private func joinTheQueue(_ app: XCUIApplication) {
        waitForTheSession(app)
        app.buttons["race-online"].tap()
        XCTAssertTrue(element(app, "queue-bar").waitForExistence(timeout: 20), "Race online didn't join the queue")
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "the stand-in alert came up with a server to race on")
    }

    /// Home, with Race online open again.
    @MainActor private func waitForRaceOnlineOpen(_ app: XCUIApplication, timeout: TimeInterval = 30, _ message: String) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: timeout), "\(message): no Race online")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: raceOnline)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: timeout), .completed, "\(message): Race online is \(raceOnline.label)")
    }

    /// A race of hers in progress on the server, her seat dropped, and the app launched into it: Home offers Rejoin race,
    /// and the tap goes to the water.
    @MainActor private func rejoinAnArrangedRace(host: String) async throws -> XCUIApplication {
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "RaceSessionService", situation: "inProgress")
        let app = launch(host: host, player: player)
        let rejoin = app.buttons["race-rejoin"]
        XCTAssertTrue(rejoin.waitForExistence(timeout: 40), "a cold launch into a race she dropped out of offers no Rejoin race")
        rejoin.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Rejoin race didn't go to the water")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "no race clock after the rejoin")
        return app
    }

    // MARK: The race phase

    /// A new player (her terms accepted on the server): Race online, the queue's bar, fleet lock, the briefing, the
    /// sequence, the gun, the close 12 s after it with her results, and Home with the race as her last.
    @MainActor func testQueueToFleetLockBriefingRaceAndClose() async throws {
        let host = try host(inPhase: Self.racePhase)
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        let app = launch(host: host, player: player)
        joinTheQueue(app)
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 30), "the fleet never locked: no takeover")
        XCTAssertTrue(app.staticTexts["Dev \(player)"].waitForExistence(timeout: 10), "her own name isn't in the briefing's fleet")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 40), "the briefing didn't lead to the race")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "no race clock on the water: the race link never joined")
        // The sequence is 60 s, the race 12 s.
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "no results at the close")
        let home = app.buttons["results-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "no Home on the online results")
        home.tap()
        waitForRaceOnlineOpen(app, "after the close")
        XCTAssertTrue(app.buttons["last-race"].waitForExistence(timeout: 20), "the closed race isn't Home's Last race")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a closed race offers a rejoin")
        XCTAssertFalse(element(app, "home-notice").exists, "a notice after a race that closed: \(element(app, "home-notice").label)")
    }

    /// Leave in the locked fleet's briefing: Home at once, and no way back into that race.
    @MainActor func testLeaveInTheBriefingGoesHome() async throws {
        let host = try host(inPhase: Self.racePhase)
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        let app = launch(host: host, player: player)
        joinTheQueue(app)
        let leave = app.buttons["briefing-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 30), "the fleet never locked: no takeover")
        leave.tap()
        let confirm = app.buttons["race-leave-confirm-leave"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Leave didn't ask")
        confirm.tap()
        XCTAssertTrue(element(app, "briefing").waitForNonExistence(timeout: 15), "Leave left the briefing up")
        waitForRaceOnlineOpen(app, "after leaving the briefing")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a seat she gave up offers a way back")
        XCTAssertFalse(app.otherElements["race-viewport"].exists)
    }

    /// A race she dropped out of: a cold launch offers Rejoin race, the tap goes to the water, and the app sent to the
    /// background and brought back is on the water again.
    @MainActor func testADropOffersRejoinAndTheTapGoesToTheWater() async throws {
        let app = try await rejoinAnArrangedRace(host: try host(inPhase: Self.racePhase))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        app.activate()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "back from the background, the race is gone")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "back from the background, no race clock")
        XCTAssertFalse(element(app, "home-notice").exists)
    }

    /// Leave race after the gun is final (owner 2026-10-12): Home, and no Rejoin race for the race she left.
    @MainActor func testLeaveRaceAfterTheGunIsFinal() async throws {
        let app = try await rejoinAnArrangedRace(host: try host(inPhase: Self.racePhase))
        let menu = app.buttons["race-pause"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no menu button on an online race")
        menu.tap()
        let leave = app.buttons["pause-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "no Leave race in the race menu")
        leave.tap()
        let confirm = app.buttons["race-leave-confirm-leave"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Leave race didn't ask")
        confirm.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 15), "Leave left the race up")
        waitForRaceOnlineOpen(app, "after leaving after the gun")
        // The server has let the seat go for good: nothing offers it back, now or a little later.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a race she left offers a way back")
        XCTAssertTrue(app.buttons["race-online"].isEnabled)
    }

    /// A sail number saved in My boat is stored on the server, and comes back on a device that never had it (a UI
    /// test's launch starts with My boat's defaults emptied).
    @MainActor func testTheServerCopyOfTheLiveryWinsOnANewDevice() async throws {
        let host = try host(inPhase: Self.racePhase)
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        var app = launch(host: host, player: player)
        waitForTheSession(app)
        openMyBoatNumber(app)
        let field = element(app, "myboat-number")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no sail number field")
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(old.count, 6)) + "4242")
        let action = app.buttons["myboat-action"]
        XCTAssertEqual(action.label, "Save")
        action.tap()
        XCTAssertEqual(action.label, "Saved", "Save didn't save")
        // The save's trip to the server.
        try await Task.sleep(nanoseconds: 3_000_000_000)

        app = launch(host: host, player: player)
        waitForTheSession(app)
        // The server's copy comes down once the session is open.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        openMyBoatNumber(app)
        let stored = element(app, "myboat-number")
        XCTAssertTrue(stored.waitForExistence(timeout: 10), "no sail number field after the relaunch")
        XCTAssertEqual(stored.value as? String, "4242", "the server's livery didn't come down to a device that never had it")
    }

    @MainActor private func openMyBoatNumber(_ app: XCUIApplication) {
        let toolbar = app.buttons["toolbar-myboat"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10), "no My boat in the toolbar")
        toolbar.tap()
        XCTAssertTrue(element(app, "page-myboat").waitForExistence(timeout: 20), "My boat didn't open")
        let segment = app.segmentedControls.buttons["Number"].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no Number part")
        segment.tap()
    }

    // MARK: The pair phase

    /// Two people in one fleet: the app, and the headless player the script queues beside it. The briefing's fleet lists
    /// her by name, as a person.
    @MainActor func testTwoHumansShareOneFleet() async throws {
        let host = try host(inPhase: Self.pairPhase)
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        let app = launch(host: host, player: player)
        joinTheQueue(app)
        // The lock is 30 s after whichever of the two joined first.
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 60), "the fleet never locked: no takeover")
        let name = "Dev \(Self.secondPlayer)"
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "the second person isn't in the briefing's fleet")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'briefing-fleet-' AND label CONTAINS %@", name))
        if rows.count > 0 {
            XCTAssertFalse(rows.firstMatch.label.contains("Bot"), "the second person is listed as a bot: \(rows.firstMatch.label)")
        }
        XCTAssertTrue(app.staticTexts["Dev \(player)"].exists, "her own name isn't in the briefing's fleet")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 60), "no race clock on the water")
    }

    // MARK: The kill phase

    /// The server is killed under her race and comes back without it: Home, with "The race was cancelled".
    @MainActor func testServerKilledMidRaceCancelsToHome() async throws {
        let app = try await rejoinAnArrangedRace(host: try host(inPhase: Self.killPhase))
        let notice = element(app, "home-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 150), "the race outlived its server: no notice on Home")
        XCTAssertTrue(notice.label.contains("The race was cancelled"), "the notice reads \(notice.label)")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 10), "the race is still up")
        waitForRaceOnlineOpen(app, timeout: 60, "after the cancel")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a cancelled race offers a rejoin")
    }
}
