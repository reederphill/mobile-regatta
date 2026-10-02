import XCTest

/// The briefing (#130): practice waits for Ready, online counts down 15 s and advances itself. The online one is
/// launched with `-briefing online`, which opens it on `-seed` with no server.
final class BriefingUITests: RaceUITestCase {
    /// Home → Practice → Start race shows the briefing with Ready and no countdown; Ready starts the race.
    @MainActor func testPracticeReadyVariant() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-seed", "1"]
        app.launch()
        let practice = app.buttons["practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 30), "no Practice on the home screen")
        practice.tap()
        let start = app.buttons["practice-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "no Start race on the practice setup")
        start.tap()

        let briefing = app.descendants(matching: .any)["briefing"].firstMatch
        XCTAssertTrue(briefing.waitForExistence(timeout: 20), "Start race didn't show the briefing")
        let ready = app.buttons["briefing-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10), "no Ready on a practice briefing")
        XCTAssertFalse(app.descendants(matching: .any)["briefing-countdown"].firstMatch.exists,
                       "a practice briefing counts down")
        // It waits: no race appears without Ready.
        XCTAssertFalse(app.otherElements["race-viewport"].waitForExistence(timeout: 3), "the race started before Ready")
        XCTAssertTrue(ready.exists, "the practice briefing didn't wait for Ready")

        ready.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Ready didn't start the race")
        XCTAssertFalse(briefing.exists, "the briefing stayed after Ready")
    }

    /// The online briefing has no Ready and advances itself at 15 s. Its clock runs at `-timescale 15`, so the 15 s
    /// take about one real second; `BriefingModelTests` pins the exact boundary on a fake clock.
    @MainActor func testOnlineAutoAdvancesAt15s() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-seed", "1", "-briefing", "online", "-timescale", "15"]
        let launched = Date()
        app.launch()
        XCTAssertFalse(app.buttons["briefing-ready"].exists, "an online briefing has Ready")
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30),
                      "the online briefing didn't advance to the race")
        XCTAssertFalse(app.descendants(matching: .any)["briefing"].firstMatch.exists, "the briefing stayed")
        XCTAssertLessThan(Date().timeIntervalSince(launched), 60, "the countdown didn't run at -timescale")
    }

    /// At real time the online briefing stays up long enough to read its countdown: no Ready, no callouts.
    @MainActor func testOnlineCountdownShows() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-seed", "1", "-briefing", "online"]
        app.launch()
        let countdown = app.descendants(matching: .any)["briefing-countdown"].firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 10), "no countdown on an online briefing")
        XCTAssertFalse(app.buttons["briefing-ready"].exists, "an online briefing has Ready")
        XCTAssertFalse(app.descendants(matching: .any)["briefing-tide-callout"].firstMatch.exists, "online callouts")
    }
}
