import XCTest

/// A UI test of a race launched with arguments. Every test ends with the app terminated, so the next
/// test's launch never has to stop an app still racing (a long race left running made the simulator
/// fail to terminate or launch the app in CI).
///
/// CI stops any test at 5 min (`-maximum-test-execution-time-allowance 300` in ci.yml and ios27.yml), and a
/// test stopped there fails without its own message. So a test's waits, this launch's included, add up to
/// at most 3.5 min, leaving room for the launch itself (up to 30 s on the iOS 27 simulator), set-up and
/// tear-down.
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
    /// the race clock. `launch()` returns once the app is idle, and the clock is up within about a second of that.
    @MainActor @discardableResult func launchRace(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-autostart", "-seed", "1"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["race-clock"].waitForExistence(timeout: 30), "no race clock after -autostart")
        return app
    }
}
