import XCTest

/// Settings (#110): the device settings are kept across launches.
final class SettingsUITests: RaceUITestCase {
    /// Launches to home (`-uitesting`) and pushes Settings.
    @MainActor private func openSettings() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home"].firstMatch.waitForExistence(timeout: 30), "no home screen")
        let settings = app.buttons["toolbar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings button")
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page-settings"].firstMatch.waitForExistence(timeout: 20), "Settings didn't open")
        return app
    }

    /// The switch's value, "0" or "1".
    @MainActor private func value(_ toggle: XCUIElement) -> String? { toggle.value as? String }

    /// Taps the switch itself, at the row's trailing end: a tap on a SwiftUI toggle's label doesn't always flip it.
    @MainActor private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Ladder lines flipped on the Settings page is still flipped after the app is killed and launched again; the
    /// test flips it back, so the next test starts from the defaults.
    @MainActor func testTogglesPersistAcrossRelaunch() {
        var app = openSettings()
        // `firstMatch`: in case a SwiftUI toggle exposes an inner switch carrying the same identifier.
        var ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle")
        let before = value(ladder)
        flip(ladder)
        XCTAssertNotEqual(value(ladder), before, "the toggle didn't flip")
        let flipped = value(ladder)

        app.terminate()
        app = openSettings()
        ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle after relaunch")
        XCTAssertEqual(value(ladder), flipped, "Ladder lines wasn't kept across the relaunch")

        flip(ladder)
        XCTAssertEqual(value(ladder), before, "the toggle didn't flip back")
    }

    /// The live leaderboard (#268) is on by default: up on the HUD once the gun has gone. Turned off in Settings, a
    /// race after the gun has no board. The test turns it back on, so the next test starts from the defaults. The
    /// waits add up to under 3.5 min (`RaceUITestCase`): each race's start sequence runs at 8× (about 8-15 s).
    @MainActor func testLiveLeaderboardToggleHidesBoard() {
        var app = launchRace(["-timescale", "8"])
        XCTAssertTrue(waitForGun(app), "the race never reached the gun")
        let board = app.descendants(matching: .any)["race-leaderboard"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 15), "no live leaderboard after the gun with the setting on")
        app.terminate()

        app = openSettings()
        var toggle = app.switches["settings-liveLeaderboard"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no Live leaderboard toggle")
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(value(toggle), "1", "Live leaderboard isn't on by default")
        flip(toggle)
        XCTAssertEqual(value(toggle), "0", "the toggle didn't flip off")
        app.terminate()

        app = launchRace(["-timescale", "8"])
        XCTAssertTrue(waitForGun(app), "the race never reached the gun")
        XCTAssertFalse(app.descendants(matching: .any)["race-leaderboard"].firstMatch.waitForExistence(timeout: 5),
                       "the live leaderboard shows with the setting off")
        app.terminate()

        app = openSettings()
        toggle = app.switches["settings-liveLeaderboard"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no Live leaderboard toggle")
        if !toggle.isHittable { app.swipeUp() }
        flip(toggle)
        XCTAssertEqual(value(toggle), "1", "the toggle didn't flip back on")
    }

    /// Waits up to 60 s for the race clock to pass the gun, read from the uitesting status probe's value (whole
    /// seconds from the gun).
    @MainActor private func waitForGun(_ app: XCUIApplication) -> Bool {
        let status = app.descendants(matching: .any)["race-status"].firstMatch
        return watch(status, until: Date.now.addingTimeInterval(60)) { snapshot in
            ((snapshot.value as? String).flatMap { Int($0) } ?? -1) >= 0
        }.seen
    }
}
