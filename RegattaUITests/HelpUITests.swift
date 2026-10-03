import XCTest

/// Help (#135): pushed from home's toolbar, and a sheet over a paused race from the pause menu, which is still there
/// once Help is done.
final class HelpUITests: RaceUITestCase {
    @MainActor func testHelpReachableFromHomeAndPause() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home"].firstMatch.waitForExistence(timeout: 30), "no home screen")

        // Home: the toolbar's Help, a topic, back to Help, back home.
        let toolbarHelp = app.buttons["toolbar-help"]
        XCTAssertTrue(toolbarHelp.waitForExistence(timeout: 20), "no Help in the toolbar")
        toolbarHelp.tap()
        let page = app.descendants(matching: .any)["page-help"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "Help didn't push from home")
        let symbols = app.buttons["help-topic-symbols"].firstMatch
        XCTAssertTrue(symbols.waitForExistence(timeout: 10), "no symbols topic in Help")
        symbols.tap()
        XCTAssertTrue(app.descendants(matching: .any)["help-symbols"].firstMatch.waitForExistence(timeout: 20),
                      "the symbols topic didn't push")
        XCTAssertTrue(app.descendants(matching: .any)["legend-vane"].firstMatch.waitForExistence(timeout: 10),
                      "no wind vane in the legend")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForExistence(timeout: 10), "back didn't return to Help")
        app.navigationBars["Help"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["toolbar-help"].waitForExistence(timeout: 10), "back didn't return home")
        app.terminate()

        // A race: pause, Help over it, Done, the pause menu still up.
        let race = launchRace()
        let pause = race.buttons["race-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "no pause button")
        pause.tap()
        let help = race.buttons["pause-help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help in the pause menu")
        help.tap()
        XCTAssertTrue(race.descendants(matching: .any)["page-help"].firstMatch.waitForExistence(timeout: 10),
                      "Help didn't open from the pause menu")
        race.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(race.descendants(matching: .any)["page-help"].firstMatch.waitForNonExistence(timeout: 10),
                      "Done didn't close Help")
        XCTAssertTrue(race.buttons["pause-resume"].exists, "the pause menu didn't stay up under Help")
    }
}
