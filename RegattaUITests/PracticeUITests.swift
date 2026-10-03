import XCTest

/// The practice race flow (#131): setup → briefing (Ready) → race → pause menu → home; the app sent to the background
/// mid-race comes back paused; a scheme switched in the pause menu is the device's; and a full sixteen-boat race.
///
/// UI tests keep the practice setup in a suite of their own, emptied at each launch (`AppModel.practiceDefaults`), so
/// every test starts from a fresh install's setup: Hollin Bay, Random, Mixed, 10 boats.
final class PracticeUITests: RaceUITestCase {
    /// Launches to home and pushes Practice: its setup page.
    @MainActor private func openSetup(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-seed", "1"] + extra
        app.launch()
        let practice = app.buttons["practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 30), "no Practice on the home screen")
        practice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page-practiceSetup"].firstMatch.waitForExistence(timeout: 20),
                      "Practice didn't push its setup")
        return app
    }

    /// Start race, then the briefing's Ready: the race.
    @MainActor private func startFromSetup(_ app: XCUIApplication) {
        let start = app.buttons["practice-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no Start race on the practice setup")
        start.tap()
        let ready = app.buttons["briefing-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Start race didn't show the briefing's Ready")
        ready.tap()
        XCTAssertTrue(app.otherElements["race-viewport"].waitForExistence(timeout: 30), "Ready didn't start the race")
    }

    /// The setup's fleet stepper, by its own identifier; its value is the fleet ("10 boats").
    @MainActor private func fleetStepper(_ app: XCUIApplication) -> XCUIElement {
        app.steppers["practice-fleet"].firstMatch
    }

    /// Taps the pause button and waits for the pause menu.
    @MainActor private func pause(_ app: XCUIApplication) {
        let pause = app.buttons["race-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "no pause button")
        pause.tap()
        XCTAssertTrue(app.buttons["pause-resume"].waitForExistence(timeout: 10), "the pause menu didn't open")
    }

    /// Home → Practice → Start race → briefing → Ready → race → pause: the menu has its rows (#25) → Leave race goes
    /// home, with no warning.
    @MainActor func testSetupReadyRacePauseLeaveReturnsHome() {
        let app = openSetup()
        for id in ["practice-venue", "practice-conditions", "practice-tier", "practice-fleet"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].firstMatch.exists, "no \(id) on the practice setup")
        }
        XCTAssertEqual(fleetStepper(app).value as? String, "10 boats", "the fleet isn't 10 by default")
        startFromSetup(app)

        pause(app)
        for id in ["pause-steering", "pause-camera", "pause-laylines", "pause-ladderLines", "pause-help", "pause-restart",
                   "pause-leave"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].firstMatch.exists, "no \(id) in the pause menu")
        }
        app.buttons["pause-leave"].tap()
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 10), "Leave race didn't return home")
        XCTAssertTrue(app.descendants(matching: .any)["race-cover"].firstMatch.waitForNonExistence(timeout: 10),
                      "the race cover stayed up")
        XCTAssertFalse(app.descendants(matching: .any)["page-practiceSetup"].firstMatch.exists,
                       "Leave race left the setup page pushed")
    }

    /// Sending the app to the background mid-race pauses it (#25, `SceneState.phase`): the pause menu is up on return.
    @MainActor func testBackgroundForegroundShowsPauseMenu() {
        let app = launchRace()
        XCTAssertFalse(app.buttons["pause-resume"].exists, "the race started paused")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5),
                      "the app didn't go to the background")
        app.activate()
        XCTAssertTrue(app.buttons["pause-resume"].waitForExistence(timeout: 15), "no pause menu on return")
        app.buttons["pause-resume"].tap()
        XCTAssertTrue(app.buttons["pause-resume"].waitForNonExistence(timeout: 10), "Resume didn't close the pause menu")
    }

    /// The steering scheme switched in the pause menu is the device's (#25, #112): Settings shows it after the app is
    /// killed and launched again. No `-scheme`, which overrides the race's scheme but not the device's. The first
    /// launch clears the device's settings (`-resetSettings`) and so does a launch at tear-down, whether or not the
    /// test got that far, so no other test starts on Tiller.
    @MainActor func testSchemeSwitchInPauseMenuPersistsAcrossRelaunch() {
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
        var app = launchRace(["-resetSettings"])
        pause(app)
        let steering = app.segmentedControls["pause-steering"].firstMatch
        XCTAssertTrue(steering.waitForExistence(timeout: 10), "no steering picker in the pause menu")
        XCTAssertTrue(steering.buttons["Halves"].isSelected, "steering isn't Halves by default")
        steering.buttons["Tiller"].tap()
        XCTAssertTrue(steering.buttons["Tiller"].isSelected, "Tiller wasn't selected")

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
        let settings = app.buttons["toolbar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "no Settings button")
        settings.tap()
        let row = app.segmentedControls["settings-steering"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no steering row in Settings")
        XCTAssertTrue(row.buttons["Tiller"].isSelected, "the pause menu's Tiller wasn't kept across the relaunch")
    }

    /// A sixteen-boat practice race (fifteen bots, the setup's largest fleet) runs to its results with every boat in
    /// them. One lap (`-laps 1`) at `-timescale 32`, as `RaceFinishUITests` sails, so it fits the 5 min CI gives a test.
    @MainActor func testFifteenBotRaceRunsFullLength() throws {
        let app = openSetup(["-laps", "1", "-timescale", "32"])
        let stepper = fleetStepper(app)
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "no fleet stepper")
        let increment = stepper.buttons["Increment"].exists
            ? stepper.buttons["Increment"] : stepper.buttons.element(boundBy: stepper.buttons.count - 1)
        for _ in 0..<6 { increment.tap() }
        XCTAssertEqual(stepper.value as? String, "16 boats", "the fleet didn't reach 16")
        startFromSetup(app)

        let results = app.staticTexts["race-results"]
        let finish = watch(results, until: .now.addingTimeInterval(200)) { _ in true }
        XCTAssertTrue(finish.seen, "the sixteen-boat race never reached its results")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "results-row").count, 16,
                       "the results don't hold all sixteen boats")
        attachScreenshot(named: "practice-sixteen-boats")
    }
}
