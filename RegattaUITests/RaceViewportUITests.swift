import XCTest

/// The race view's size in the window follows `RaceViewportPolicy.letterboxedPortrait` (#107, G5).
final class RaceViewportUITests: RaceUITestCase {
    override func tearDown() {
        super.tearDown()
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
    }

    /// In a full-screen portrait window the race fills the window.
    @MainActor func testPortraitRaceFillsTheWindow() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchRace()
        let window = app.windows.firstMatch.frame
        let race = raceRect(in: app)

        attachScreenshot(named: "race-viewport-portrait")
        XCTAssertEqual(race.width, window.width, accuracy: 1)
        XCTAssertEqual(race.height, window.height, accuracy: 1)
    }

    /// On iPad in landscape the race keeps its portrait shape, centred and letterboxed with water.
    @MainActor func testLandscapeIPadLetterboxesThePortraitRace() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPhone runs portrait only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchRace()
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "the app didn't launch in landscape")
        let race = raceRect(in: app)

        attachScreenshot(named: "race-viewport-ipad-landscape")
        XCTAssertEqual(race.height, window.height, accuracy: 1)
        XCTAssertEqual(race.width / race.height, window.height / window.width, accuracy: 0.01)
        XCTAssertEqual(race.midX, window.midX, accuracy: 1)
        let clock = app.staticTexts["race-clock"].frame
        XCTAssertTrue(race.contains(clock), "the HUD clock \(clock) is outside the race rect \(race)")
    }

    @MainActor private func raceRect(in app: XCUIApplication) -> CGRect {
        let viewport = app.otherElements["race-viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 60), "no race viewport after -autostart")
        return viewport.frame
    }
}
