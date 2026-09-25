import XCTest

/// A UI test of a race launched with arguments. Every test ends with the app terminated, so the next
/// test's launch never has to stop an app still racing (a long race left running made the simulator
/// fail to terminate or launch the app in CI).
class RaceUITestCase: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// XCTest runs `tearDown` on the main thread. `XCUIApplication()` is the target app by bundle, so it
    /// reaches whichever instance the test launched.
    override func tearDown() {
        MainActor.assumeIsolated {
            let app = XCUIApplication()
            if app.state != .notRunning { app.terminate() }
        }
        super.tearDown()
    }

    /// Launches a race straight from the menu: `-uitesting -autostart -seed 1`, then `extra`, and waits for
    /// the race clock.
    @MainActor @discardableResult func launchRace(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-autostart", "-seed", "1"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 60), "no race clock after -autostart")
        return app
    }
}
