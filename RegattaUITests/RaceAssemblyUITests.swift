import XCTest

/// A practice race assembled on the new core (#81): the default setup's files, the derived course.
final class RaceAssemblyUITests: RaceUITestCase {
    /// A bot sails your boat (`-demo`) at 8×, so your status line shows the gun (racing on leg 1) and then
    /// the first rounding (a later leg). About 30 s at 8×; the wait allows a slow CI runner. Leg 2 is the
    /// short reach from the windward mark to the offset mark, a second or two of real time at 8×, so a
    /// poll can miss it: any leg past 1 shows the rounding.
    @MainActor func testPracticeRaceOnTheNewCoreReachesTheGunAndAFirstRounding() throws {
        let app = launchRace(["-demo", "-timescale", "8"])
        let status = app.staticTexts["race-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "no race status line")
        // The label is matched in the query, so each poll is one existence check. A predicate expectation on
        // `status.label` resolved the element and read it on every poll, and on the iOS 27 simulator one such
        // read of the app racing at 8× blocked for 20 minutes, far past the wait's timeout.
        func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
            let predicate = NSPredicate(format: "identifier == %@ AND label MATCHES %@", "race-status", pattern)
            return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
        }
        XCTAssertTrue(waitForLabel(matching: ".*leg 1/.*", timeout: 120), "never started racing after the gun: \(status.label)")
        XCTAssertTrue(waitForLabel(matching: ".*leg ([2-9]|[1-9][0-9])/.*", timeout: 300),
                      "never rounded the first mark: \(status.label)")
        attachScreenshot(named: "race-first-rounding")
    }
}
