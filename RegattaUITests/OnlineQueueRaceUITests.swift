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
/// - `pair`: the queue locks 30 s after the first join, a queue race closes 30 s after the gun (time to leave it
///   after the gun on a slow simulator), and the script queues a headless second person
///   (`regatta-loadclient --queue-player 7001`) beside the app, once the test has arranged a race on the server to
///   say the app is about to join (the script watches `/health` for it).
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
        // Past the gates: the lobby's own panels (before #164 a session's lobby can't be reached, so "Can't reach the
        // lobby"), never Sign in or the terms.
        let pastTheGates = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["lobby-feed", "lobby-unreachable", "lobby-loading"]))
        XCTAssertTrue(pastTheGates.firstMatch.waitForExistence(timeout: 30), "no session for a player with the terms accepted")
    }

    /// Race online, into the queue: the bar, not the stand-in alert.
    @MainActor private func joinTheQueue(_ app: XCUIApplication) {
        waitForTheSession(app)
        app.buttons["race-online"].tap()
        XCTAssertTrue(element(app, "queue-bar").waitForExistence(timeout: 20), "Race online didn't join the queue")
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "the stand-in alert came up with a server to race on")
    }

    /// Home on screen, with Race online open again. Home stays in the window under the race cover, where a query
    /// still finds its buttons (`RaceUITestCase.homeIsCovered`), so the button has to be hittable too.
    @MainActor private func waitForRaceOnlineOpen(_ app: XCUIApplication, timeout: TimeInterval = 30, _ message: String) {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: timeout), "\(message): no Race online")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: raceOnline)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: timeout), .completed,
                       "\(message): Race online is \(raceOnline.label), \(raceOnline.isHittable ? "on screen" : "covered")")
    }

    /// The briefing's fleet rows whose label has `name` in it. A row is one element (`briefing-fleet-<seat>`) labelled
    /// with its boat, the word "Bot" for a bot, the name, the rating and the sail number; her own row's name is "You".
    @MainActor private func fleetRows(_ app: XCUIApplication, named name: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'briefing-fleet-' AND label CONTAINS %@", name))
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
        // Her own row says "You", as a person: her name is for the others' screens.
        let mine = fleetRows(app, named: "You").firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "her own boat isn't in the briefing's fleet")
        XCTAssertFalse(mine.label.contains("Bot"), "her own boat is listed as a bot: \(mine.label)")
        let briefed = sailNumber(in: mine.label)
        XCTAssertNotNil(briefed, "no sail number in her briefing row: \(mine.label)")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 40), "the briefing didn't lead to the race")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "no race clock on the water: the race link never joined")
        // The sequence is 60 s, the race 12 s.
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "no results at the close")
        // #163: the server's closed report reached the sheet. The live frame's sheet has no rating caption; the closed
        // report of a race with no other human at the gun reads unrated.
        let rating = app.staticTexts["results-rating"]
        XCTAssertTrue(rating.waitForExistence(timeout: 30), "no rating caption: the server's report never reached the sheet")
        let unrated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No other humans at the gun, unrated"),
                                                object: rating)
        XCTAssertEqual(XCTWaiter().wait(for: [unrated], timeout: 30), .completed, "not the closed report's caption: \(rating.label)")
        XCTAssertEqual(sailingRows(app), 0, "a closed race's rows still say Sailing")
        // #163, the owner's livery bug: her results row wears the briefing's sail number.
        if let briefed {
            XCTAssertTrue(myResultsRow(app, sailNumber: briefed).exists, "her results row isn't the briefing's sail number \(briefed)")
        }
        let home = app.buttons["results-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "no Home on the online results")
        home.tap()
        waitForRaceOnlineOpen(app, "after the close")
        XCTAssertTrue(app.buttons["last-race"].waitForExistence(timeout: 20), "the closed race isn't Home's Last race")
        XCTAssertFalse(app.buttons["race-rejoin"].exists, "a closed race offers a rejoin")
        XCTAssertFalse(element(app, "home-notice").exists, "a notice after a race that closed: \(element(app, "home-notice").label)")
    }

    /// #163, the ticket's second acceptance: Home's Last race reopens the race's results until her next race ends. A
    /// relaunch (which empties the device's Last race under `-uitesting`) reads it from the server; while she waits in
    /// the queue it is still race 1; once race 2 closes, it is race 2. `last-race`'s value is the race's id under UI
    /// tests.
    @MainActor func testLastRaceReopensUntilTheNextRaceEnds() async throws {
        let host = try host(inPhase: Self.racePhase)
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        var app = launch(host: host, player: player)
        sailAQueueRaceToItsClose(app, "race 1")
        let lastRace = app.buttons["last-race"]
        XCTAssertTrue(lastRace.waitForExistence(timeout: 20), "race 1 isn't Home's Last race")
        let first = try XCTUnwrap(raceID(of: lastRace), "no race id on the Last race row")
        lastRace.tap()
        let close = app.buttons["results-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the Last race row didn't reopen the results")
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(identifier: "results-row").count, 0, "the reopened results have no rows")
        XCTAssertEqual(sailingRows(app), 0, "the reopened results aren't final")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "Close left the results up")

        // A relaunch: the device's Last race is gone, so the row is the server's.
        app = launch(host: host, player: player)
        waitForTheSession(app)
        let fetched = app.buttons["last-race"]
        XCTAssertTrue(fetched.waitForExistence(timeout: 30), "a relaunch has no Last race: the server's wasn't fetched")
        XCTAssertEqual(raceID(of: fetched), first, "the relaunch's Last race isn't race 1")

        // Queued for race 2: race 1 is still her last race.
        joinTheQueue(app)
        XCTAssertEqual(raceID(of: app.buttons["last-race"]), first, "queued for race 2, the Last race isn't race 1")
        sailAQueueRaceToItsClose(app, "race 2", joined: true)
        let second = app.buttons["last-race"]
        XCTAssertTrue(second.waitForExistence(timeout: 20), "race 2 isn't Home's Last race")
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", first), object: second)
        XCTAssertEqual(XCTWaiter().wait(for: [replaced], timeout: 20), .completed, "race 2's close didn't replace race 1")
    }

    /// Race online (unless `joined`), the briefing, the race, its close 12 s after the gun, and Home from the results.
    @MainActor private func sailAQueueRaceToItsClose(_ app: XCUIApplication, _ race: String, joined: Bool = false) {
        if !joined { joinTheQueue(app) }
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 30), "\(race): the fleet never locked")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 40), "\(race): no race after the briefing")
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 120), "\(race): no results at the close")
        let home = app.buttons["results-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "\(race): no Home on the results")
        home.tap()
        waitForRaceOnlineOpen(app, "\(race): after the close")
    }

    /// The race id Home's Last race row carries under UI tests (#163).
    @MainActor private func raceID(of row: XCUIElement) -> String? {
        guard row.exists, let value = row.value as? String, !value.isEmpty else { return nil }
        return value
    }

    /// How many boats on the results read "Sailing": still racing, so the rows aren't final.
    @MainActor private func sailingRows(_ app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Sailing")).count
    }

    /// Her results row ("You") wearing sail number `number`.
    @MainActor private func myResultsRow(_ app: XCUIApplication, sailNumber number: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "results-row")
            .containing(NSPredicate(format: "label == %@", "You"))
            .containing(NSPredicate(format: "label == %@", "Sail number \(number)"))
            .firstMatch
    }

    /// The sail number in a briefing fleet row's label ("…, 4509"): its last number.
    private func sailNumber(in label: String) -> Int? {
        label.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
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
        // The briefing's card keeps its own identifiers (`LeaveConfirm.Place.briefing`); the race's are `race-leave-…`.
        let confirm = app.buttons["briefing-leave-confirm"]
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
        waitForTheSession(app)
        // The word to the script that the app is on Home and about to join: a race of somebody else's on the server,
        // which /health counts. The second person joins the queue within a few seconds of it.
        try await arrange(host: host, player: newPlayer(), service: "RaceSessionService", situation: "inProgress")
        joinTheQueue(app)
        // The lock is 30 s after whichever of the two joined first.
        XCTAssertTrue(app.buttons["briefing-leave"].waitForExistence(timeout: 60), "the fleet never locked: no takeover")
        // Both rows from one snapshot of the briefing: it is up for seconds, and on a loaded simulator a query per row
        // can outlast it (main 39785610313: the second row's query took 4 s, hers began after the race had replaced
        // the briefing and took 74 s over the race's tree).
        let rows = try briefingFleetLabels(app)
        let second = rows.first { $0.contains("Dev \(Self.secondPlayer)") }
        XCTAssertNotNil(second, "the second person isn't in the briefing's fleet: \(rows)")
        XCTAssertFalse(second?.contains("Bot") ?? false, "the second person is listed as a bot: \(second ?? "")")
        let mine = rows.first { $0.contains("You") }
        XCTAssertNotNil(mine, "her own boat isn't in the briefing's fleet: \(rows)")
        XCTAssertFalse(mine?.contains("Bot") ?? false, "her own boat is listed as a bot: \(mine ?? "")")
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 60), "no race clock on the water")

        // #163, the ticket's "rating push arrives while queued": past the gun she leaves the race (RET, rated: two
        // humans were at the gun), and queues again. The close, 30 s after the gun, pushes her rating change, and
        // Home's Last race shows it while the queue bar is up.
        try await waitForTheGun(app)
        let menu = app.buttons["race-pause"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no menu button on the race")
        menu.tap()
        let leave = app.buttons["pause-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "no Leave race in the race menu")
        leave.tap()
        let confirm = app.buttons["race-leave-confirm-leave"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Leave race didn't ask")
        confirm.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForNonExistence(timeout: 15), "Leave left the race up")
        waitForRaceOnlineOpen(app, "after leaving after the gun")
        joinTheQueue(app)
        // The badge first ("Rating plus/minus …" in the row's label), then its sign.
        let row = app.buttons["last-race"]
        let rated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Rating "), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [rated], timeout: 60), .completed,
                       "no rating badge on the Last race row while queued: \(row.exists ? row.label : "no row")")
        XCTAssertTrue(element(app, "queue-bar").exists, "the badge landed after the queue bar went")
        // Retired against Dev 7001, who sailed on: she lost rating.
        XCTAssertTrue(row.label.contains("Rating minus"), "the retired race's badge isn't a loss: \(row.label)")
    }

    /// The race clock (its value is the race tick) 2 s past the gun or more: a leave now is a retirement.
    @MainActor private func waitForTheGun(_ app: XCUIApplication) async throws {
        let clock = app.staticTexts["race-clock"]
        let until = Date().addingTimeInterval(90)
        var tick: Int?
        repeat {
            tick = (clock.value as? String).flatMap { Int($0) }
            if let tick, tick >= 2 * 30 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < until
        XCTFail("the gun never came: the race clock reads \(tick.map(String.init) ?? "nothing")")
    }

    /// The labels of the briefing's fleet rows (`briefing-fleet-<seat>`), read from one snapshot of the app, retried
    /// for up to 10 s until the fleet is listed.
    @MainActor private func briefingFleetLabels(_ app: XCUIApplication) throws -> [String] {
        let until = Date().addingTimeInterval(10)
        var labels: [String] = []
        repeat {
            labels = []
            var stack: [any XCUIElementSnapshot] = [try app.snapshot()]
            while let node = stack.popLast() {
                if node.identifier.hasPrefix("briefing-fleet-") { labels.append(node.label) }
                stack.append(contentsOf: node.children)
            }
        } while labels.isEmpty && Date() < until
        return labels
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
