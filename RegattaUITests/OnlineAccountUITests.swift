import XCTest

/// The online account end to end (#161): the app signs in to a real server as a dev player (`-devIdentity`, in place
/// of Game Center), accepts the terms, comes back without being asked again, is asked again when the server's terms
/// move on, and shows a suspension and the cooldown the server puts her in (`POST /dev/situation`). Past the gate is
/// the real queue (#162): its bar, which each test leaves again so no fleet locks under the next launch.
///
/// `scripts/e2e.sh` starts the server on Postgres and passes its address as `REGATTA_ONLINE_HOST`; without one the
/// tests skip, saying so. Its second phase restarts the server with `TERMS_VERSION=2` on the same database and sets
/// `REGATTA_E2E_PHASE=terms-bump`: only `testServerRestartedWithANewTermsVersionAsksAgain` runs then, for the player
/// `testRelaunchResumesWithoutAskingTermsAgain` left accepted in the first. The other players are new each run, so a
/// retried test starts clean.
final class OnlineAccountUITests: XCTestCase {
    /// Which phase of `scripts/e2e.sh` this is: unset in the first, `terms-bump` in the second.
    static let phaseVariable = "REGATTA_E2E_PHASE"
    static let termsBumpPhase = "terms-bump"
    /// The dev player who accepts the terms in the first phase and meets the new version in the second.
    static let returningPlayer = 16102

    /// Past the gate: the queue's bar (#162), never the stand-in alert of a build with no server. Leaves the queue again.
    @MainActor private func expectTheQueue(_ app: XCUIApplication, _ message: String) {
        let bar = app.descendants(matching: .any)["queue-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), message)
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "the stand-in alert came up with a server to race on")
        let leave = app.buttons["queue-bar-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "the queue's bar has no Leave")
        leave.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "Leave left the queue's bar up")
    }

    /// The server's address, for the phase the test is for; skips otherwise.
    private func host(inPhase phase: String? = nil) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment[OnlineRaceUITests.hostVariable], !host.isEmpty else {
            throw XCTSkip("No server: \(OnlineRaceUITests.hostVariable) isn't set. scripts/e2e.sh starts one and runs this test.")
        }
        let running = environment[Self.phaseVariable].flatMap { $0.isEmpty ? nil : $0 }
        guard running == phase else {
            throw XCTSkip("Not this phase of scripts/e2e.sh: \(running ?? "the first") is running, this test is for \(phase ?? "the first").")
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

    /// Puts the dev player in a contract situation on the server (`POST /dev/situation`).
    private func arrange(host: String, player: Int, service: String, situation: String) async throws {
        let url = try XCTUnwrap(URL(string: "http://\(host)/dev/situation?service=\(service)&situation=\(situation)"
            + "&teamPlayerID=T:dev-\(player)&gamePlayerID=G:dev-\(player)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, "\(service).\(situation): \(String(decoding: body, as: UTF8.self))")
    }

    /// Waits for `element` to match `format`, a predicate over its attributes.
    @MainActor private func wait(on element: XCUIElement, _ format: String, with arguments: [Any] = [], timeout: TimeInterval = 30,
                                 _ message: String) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [matched], timeout: timeout), .completed, "\(message): \(element.label)")
    }

    /// Race online, with the session open and the terms still due: the lobby area asks for them.
    @MainActor private func raceOnlineWithTermsDue(_ app: XCUIApplication) -> XCUIElement {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "no Race online")
        XCTAssertTrue(app.buttons["lobby-terms"].waitForExistence(timeout: 30), "no session: the lobby area never asked for the terms")
        return raceOnline
    }

    /// A new dev player: the session opens, Race online asks for the terms, I agree records them on the server and
    /// goes on to the queue.
    @MainActor func testDevIdentityAcceptsTermsAndOpensTheSession() throws {
        let app = launch(host: try host(), player: newPlayer())
        raceOnlineWithTermsDue(app).tap()
        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 20), "no terms sheet for a new player")
        XCTAssertEqual(app.staticTexts["terms-version"].label, "Version 1")
        agree.tap()
        expectTheQueue(app, "I agree didn't go on to the queue")
        XCTAssertTrue(app.buttons["lobby-terms"].waitForNonExistence(timeout: 10), "the terms are still due after I agree")
        XCTAssertFalse(app.buttons["lobby-sign-in"].exists, "the session closed after I agree")
    }

    /// The returning player accepts if she hasn't yet, then the app is relaunched: it resumes her session, and Race
    /// online goes straight on with no terms sheet.
    @MainActor func testRelaunchResumesWithoutAskingTermsAgain() throws {
        let host = try host()
        var app = launch(host: host, player: Self.returningPlayer)
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 30), "no Race online")
        app.buttons["race-online"].tap()
        // A first run asks; a retry of this test, or a second run on the same database, finds them accepted.
        if app.buttons["terms-agree"].waitForExistence(timeout: 10) { app.buttons["terms-agree"].tap() }
        expectTheQueue(app, "never got past the gate")

        app = launch(host: host, player: Self.returningPlayer)
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 30), "no Race online after the relaunch")
        app.buttons["race-online"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["queue-bar"].firstMatch.waitForExistence(timeout: 20), "the relaunch didn't get past the gate")
        XCTAssertFalse(app.buttons["terms-agree"].exists, "the terms were asked again after a relaunch")
        expectTheQueue(app, "the relaunch didn't get past the gate")
        XCTAssertFalse(app.buttons["lobby-terms"].exists, "the lobby area asks for terms already accepted")
    }

    /// The second phase: the server came back with terms version 2. A build with the old text asks for an update and
    /// shows no sheet; one with the new text asks again, and I agree goes on.
    @MainActor func testServerRestartedWithANewTermsVersionAsksAgain() throws {
        let host = try host(inPhase: Self.termsBumpPhase)
        var app = launch(host: host, player: Self.returningPlayer)
        let behind = app.buttons["race-online"]
        XCTAssertTrue(behind.waitForExistence(timeout: 30), "no Race online")
        wait(on: behind, "isEnabled == false AND label CONTAINS %@", with: ["Update to race online"],
             "a build with the old terms isn't asked to update")
        XCTAssertFalse(app.buttons["terms-agree"].exists, "a sheet for terms the build doesn't carry")

        app = launch(host: host, player: Self.returningPlayer, ["-termsVersion", "2"])
        raceOnlineWithTermsDue(app).tap()
        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 20), "the new version didn't ask again")
        XCTAssertEqual(app.staticTexts["terms-version"].label, "Version 2")
        agree.tap()
        expectTheQueue(app, "I agree to the new version didn't go on to the queue")
    }

    /// A player the server has suspended (the dev situation's suspension has no end: "Racing closed"; one with an end
    /// reads "Racing paused until" its day): Race online is closed, and a practice race still starts.
    @MainActor func testSuspendedPlayerSeesRacingPausedAndPracticeStillStarts() async throws {
        let host = try host()
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "suspended")
        let app = launch(host: host, player: player)
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "no Race online")
        wait(on: raceOnline, "isEnabled == false AND (label CONTAINS 'Racing closed' OR label CONTAINS 'Racing paused until ')",
             "a suspended player's Race online isn't closed")

        app.buttons["practice"].tap()
        let start = app.buttons["practice-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "Practice didn't open for a suspended player")
        start.tap()
        XCTAssertTrue(app.buttons["briefing-ready"].waitForExistence(timeout: 30), "a suspended player's practice race didn't start")
    }

    /// The server puts a signed-in player in the cooldown (the dev situation's lasts a few seconds): Race online closes
    /// with the countdown, and opens again when the server says it is over.
    @MainActor func testCooldownShowsTheCountdown() async throws {
        let host = try host()
        let player = newPlayer()
        try await arrange(host: host, player: player, service: "QueueService", situation: "joinable")
        let app = launch(host: host, player: player)
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 30), "no Race online")
        // The session is open, the terms accepted: the lobby area asks for nothing.
        // Past the gates: the lobby's own panels (before #164 a session's lobby can't be reached, so "Can't reach the
        // lobby"), never Sign in or the terms.
        let pastTheGates = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["lobby-feed", "lobby-unreachable"]))
        XCTAssertTrue(pastTheGates.firstMatch.waitForExistence(timeout: 30), "no session for a player with the terms accepted")

        try await arrange(host: host, player: player, service: "QueueService", situation: "cooldown")
        wait(on: raceOnline, "isEnabled == false AND label CONTAINS 'Cooling off '", timeout: 10, "no countdown in the cooldown")
        wait(on: raceOnline, "isEnabled == true AND NOT (label CONTAINS 'Cooling off')", "Race online didn't open again after the cooldown")
    }
}
