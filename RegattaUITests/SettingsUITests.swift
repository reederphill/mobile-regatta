import XCTest

/// Settings (#110): the device settings are kept across launches.
final class SettingsUITests: RaceUITestCase {
    /// Launches to home (`-uitesting`) and pushes Settings. `reset` clears the device's settings at that launch
    /// (`-resetSettings`), so the page opens on the defaults whatever an earlier test, or an earlier try of this one,
    /// left behind.
    @MainActor private func openSettings(reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = reset ? ["-uitesting", "-resetSettings"] : ["-uitesting"]
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
    /// a read straight after the tap could see the old value.
    ///
    /// The simulator can also drop the tap altogether: in a CI run (#473) one of eleven taps left the switch as it
    /// was for the whole 5 s, and the app was idle again 1.6 s after it where a tap that flips takes ~2.9 s. So a
    /// switch still unchanged after the wait is tapped once more. A switch that two taps didn't flip still fails the
    /// caller's check.
    @MainActor private func flip(_ toggle: XCUIElement) {
        let before = value(toggle) ?? ""
        for attempt in 1...2 {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: toggle)
            if XCTWaiter.wait(for: [changed], timeout: 5) == .completed { return }
            XCTContext.runActivity(named: "Tap \(attempt) didn't flip \(toggle)") { _ in }
        }
    }

    /// Clears the device's settings when the test ends, passed or failed, with a launch (`-resetSettings`) and no
    /// taps on the page: the next test, or this one's retry, starts from the defaults. Setting the toggles back by
    /// tapping them left Laylines off when a tap was dropped, and the retry then failed its first check (#473).
    @MainActor private func resetSettingsAtTearDown() {
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
    }

    /// Ladder lines flipped on the Settings page is still flipped after the app is killed and launched again. The
    /// first launch clears the device's settings and so does a launch at tear-down, so the next test starts from the
    /// defaults even when an assertion here fails (#314).
    @MainActor func testTogglesPersistAcrossRelaunch() {
        resetSettingsAtTearDown()
        var app = openSettings(reset: true)
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
    }

    /// Laylines off and ladder lines on in Settings reach the race: the scene hides the laylines and draws the
    /// ladder lines (`race-cues`, `CueProbe`). The first launch clears the device's settings and so does a launch at
    /// tear-down, so this test and the next start from the defaults even when an assertion here fails.
    @MainActor func testLaylineAndLadderTogglesChangeVisibility() {
        resetSettingsAtTearDown()
        var app = openSettings(reset: true)
        let laylines = app.switches["settings-laylines"].firstMatch
        let ladder = app.switches["settings-ladderLines"].firstMatch
        XCTAssertTrue(laylines.waitForExistence(timeout: 20), "no Laylines toggle")
        XCTAssertTrue(ladder.waitForExistence(timeout: 20), "no Ladder lines toggle")
        XCTAssertEqual(value(laylines), "1", "laylines aren't on by default")
        XCTAssertEqual(value(ladder), "0", "ladder lines aren't off by default")
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

    /// The live leaderboard (#268) is on by default: up on the HUD once the gun has gone. Turned off in Settings, a
    /// race after the gun has no board. The test turns it back on, so the next test starts from the defaults. The
    /// waits add up to under 3.5 min (`RaceUITestCase`): each race has a 5 s start sequence (`-startSeconds 5`) at
    /// real time, so the app is never behind on its ticks while the test asks about the board. At `-timescale 8` a
    /// slow CI runner took 46 s and 66 s to reach the gun and answered each query about the board in 30 s (#473: the
    /// test ran into its 5 min allowance in tear-down, and the terminate there failed).
    /// The first launch clears the device's settings (`-resetSettings`) and so does a launch at tear-down, whether or
    /// not the test got that far: a try that failed with the board turned off no longer fails the retry's first check.
    @MainActor func testLiveLeaderboardToggleHidesBoard() {
        resetSettingsAtTearDown()
        var app = launchRace(["-startSeconds", "5", "-resetSettings"])
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

        app = launchRace(["-startSeconds", "5"])
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
