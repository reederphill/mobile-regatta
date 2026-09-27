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

    /// Looks at `element` every `interval` until a look satisfies `seen` or `deadline` passes, and returns whether
    /// one did and the last snapshot a look got (nil if none did).
    ///
    /// A look is one `snapshot()`, so it reads the element's label and value together, where reading `label` and
    /// then `value` resolves the element once each. An app racing at a fast `-timescale` is slow to answer (a query
    /// took 0.3-10 s in CI, and one timed out after 43 s), and a look that times out, or finds nothing, throws, so
    /// the next one tries again. `exists`, and so `waitForExistence`, records a timed-out query as a failure, which
    /// ends the test (`continueAfterFailure`), and it asks about once a second while the app races. Each look is
    /// logged with what it saw. A look under way at `deadline` still finishes, which can take one query timeout.
    @MainActor func watch(_ element: XCUIElement, every interval: TimeInterval = 2, until deadline: Date,
                          for seen: (any XCUIElementSnapshot) -> Bool) -> (seen: Bool, last: (any XCUIElementSnapshot)?) {
        var last: (any XCUIElementSnapshot)?
        while true {
            do {
                let snapshot = try element.snapshot()
                last = snapshot
                let value = snapshot.value.map { "\($0)" } ?? "none"
                XCTContext.runActivity(named: "Saw \(element): \"\(snapshot.label)\", value \(value)") { _ in }
                if seen(snapshot) { return (true, snapshot) }
            } catch {
                XCTContext.runActivity(named: "Saw no \(element): \(error.localizedDescription)") { _ in }
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return (false, last) }
            Thread.sleep(forTimeInterval: min(interval, remaining))
        }
    }
}
