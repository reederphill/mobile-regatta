import XCTest

/// A practice race assembled on the new core (#81): the default setup's files, the derived course.
final class RaceAssemblyUITests: RaceUITestCase {
    /// A bot sails your boat (`-demo`) at 8×, so your status line shows the gun (racing on leg 1) and then
    /// the first rounding (leg 2). About 30 s at 8×; the wait allows a slow CI runner.
    @MainActor func testPracticeRaceOnTheNewCoreReachesTheGunAndAFirstRounding() throws {
        let app = launchRace(["-demo", "-timescale", "8"])
        let status = app.staticTexts["race-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "no race status line")
        func waitForLabel(containing text: String, timeout: TimeInterval) -> Bool {
            let predicate = NSPredicate(format: "label CONTAINS %@", text)
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status)],
                                    timeout: timeout) == .completed
        }
        XCTAssertTrue(waitForLabel(containing: "leg 1/", timeout: 120), "never started racing after the gun: \(status.label)")
        XCTAssertTrue(waitForLabel(containing: "leg 2/", timeout: 300), "never rounded the first mark: \(status.label)")
        attachScreenshot(named: "race-first-rounding")
    }
}
