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
}
