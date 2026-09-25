import XCTest

/// The online client (#68) sails a dev instant race on a real race server to its close. `scripts/e2e.sh`
/// starts the server and passes its address as `REGATTA_ONLINE_HOST` (`TEST_RUNNER_REGATTA_ONLINE_HOST`);
/// without one there is nothing to race, and the test skips, saying so.
final class OnlineRaceUITests: RaceUITestCase {
    /// The server's address, `host:port`, when a run has one.
    static let hostVariable = "REGATTA_ONLINE_HOST"

    /// A 5 s sequence and the race closed 20 s after the gun (the server's race-length override), with
    /// bots filling the fleet: the results come up about 25 s after the join.
    @MainActor func testOnlineDevRaceReachesTheClose() throws {
        guard let host = ProcessInfo.processInfo.environment[Self.hostVariable], !host.isEmpty else {
            throw XCTSkip("No race server: \(Self.hostVariable) isn't set. scripts/e2e.sh starts one and runs this test.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-online", "-onlineHost", host, "-startSeconds", "5", "-raceSeconds", "20"]
        app.launch()
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 60),
                      "never joined: \(app.staticTexts["online-failed"].exists ? app.staticTexts["online-failed"].label : "no error shown")")
        let results = app.staticTexts["race-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 120), "the race never closed")
        attachScreenshot(named: "online-race-close")
    }
}
