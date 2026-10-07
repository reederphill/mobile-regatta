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
    /// Then waits up to 5 s for its value to change: XCTest can call the app idle before the switch reports its new
    /// value (a CI run read the old one the instant after the tap, where the wait for idle usually takes ~1.3 s), so
    /// a read straight after the tap could see the old value. A tap that didn't flip it still fails the caller's check.
    @MainActor private func flip(_ toggle: XCUIElement) {
        let before = value(toggle) ?? ""
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: toggle)
        _ = XCTWaiter.wait(for: [changed], timeout: 5)
    }

    /// Ladder lines flipped on the Settings page is still flipped after the app is killed and launched again. A
    /// `defer` sets the toggles back, so the next test starts from the defaults even when an assertion here fails
    /// (#314).
    @MainActor func testTogglesPersistAcrossRelaunch() {
        var app = openSettings()
        // `firstMatch`: in case a SwiftUI toggle exposes an inner switch carrying the same identifier.
        var ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle")
        let before = value(ladder)
        defer { restoreCueToggles() }
        flip(ladder)
        XCTAssertNotEqual(value(ladder), before, "the toggle didn't flip")
        let flipped = value(ladder)

        app.terminate()
        app = openSettings()
        ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle after relaunch")
        XCTAssertEqual(value(ladder), flipped, "Ladder lines wasn't kept across the relaunch")
    }

    /// Laylines off and ladder lines on in Settings reach the race: the scene hides the laylines and draws the
    /// ladder lines (`race-cues`, `CueProbe`). A `defer` sets both back, so the next test starts from the defaults
    /// even when an assertion here fails.
    @MainActor func testLaylineAndLadderTogglesChangeVisibility() {
        var app = openSettings()
        let laylines = app.switches["settings-laylines"].firstMatch
        let ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(laylines.waitForExistence(timeout: 20), "no Laylines toggle")
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle")
        XCTAssertEqual(value(laylines), "1", "laylines aren't on by default")
        XCTAssertEqual(value(ladder), "0", "ladder lines aren't off by default")
        defer { restoreCueToggles() }
        flip(laylines)
        flip(ladder)
        XCTAssertEqual(value(laylines), "0", "the Laylines toggle didn't flip")
        XCTAssertEqual(value(ladder), "1", "the Ladder lines toggle didn't flip")
        app.terminate()

        app = launchRace()
        let cues = app.staticTexts["race-cues"].firstMatch
        XCTAssertTrue(cues.waitForExistence(timeout: 20), "no cue probe")
        let (seen, last) = watch(cues, until: Date().addingTimeInterval(20)) {
            ($0.value as? String)?.hasPrefix("laylines=0 ladder=1") == true
        }
        XCTAssertTrue(seen, "the race drew \(String(describing: last?.value)), not laylines off and ladder lines on")
        app.terminate()
    }

    /// Sets the Laylines toggle back on and the Ladder lines toggle back off, whichever way they were left.
    @MainActor private func restoreCueToggles() {
        let app = openSettings()
        let laylines = app.switches["settings-laylines"].firstMatch
        let ladder = app.switches["settings-ladderLines"].firstMatch
        guard laylines.waitForExistence(timeout: 20), ladder.waitForExistence(timeout: 20) else {
            return XCTFail("no cue toggles to restore")
        }
        if value(laylines) != "1" { flip(laylines) }
        if value(ladder) != "0" { flip(ladder) }
        XCTAssertEqual(value(laylines), "1", "the Laylines toggle didn't flip back")
        XCTAssertEqual(value(ladder), "0", "the Ladder lines toggle didn't flip back")
    }

    /// The live leaderboard (#268) is on by default: up on the HUD once the gun has gone. Turned off in Settings, a
    /// race after the gun has no board. The test turns it back on, so the next test starts from the defaults. The
    /// waits add up to under 3.5 min (`RaceUITestCase`): each race's start sequence runs at 8× (about 8-15 s).
    /// The first launch clears the device's settings (`-resetSettings`) and so does a launch at tear-down, whether or
    /// not the test got that far: a try that failed with the board turned off no longer fails the retry's first check.
    @MainActor func testLiveLeaderboardToggleHidesBoard() {
        addTeardownBlock {
            // XCTest runs tear-down blocks on the main thread, as it does `tearDown`.
            MainActor.assumeIsolated {
                let app = XCUIApplication()
                if app.state != .notRunning { app.terminate() }
                app.launchArguments = ["-uitesting", "-resetSettings"]
                app.launch()
                app.terminate()
            }
        }
        var app = launchRace(["-timescale", "8", "-resetSettings"])
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
