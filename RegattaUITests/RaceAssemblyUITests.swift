import XCTest

/// A practice race assembled on the new core (#81): the default setup's files, the derived course.
final class RaceAssemblyUITests: RaceUITestCase {
    /// A bot sails your boat (`-demo`) at 8×, so your status line shows the gun (racing on leg 1) and then
    /// the first rounding (a later leg). Leg 2 is the short reach from the windward mark to the offset mark,
    /// a second or two of real time at 8×, so a poll can miss it: any leg past 1 shows the rounding.
    ///
    /// The waits come from the race this launch sails (seed 1, eight skiffs), measured headless with the
    /// same setup (#231): your bot starts 2 s after the gun and rounds the windward mark 208 s after it.
    /// Over seeds 1-60 the same bot's first rounding is 189 s after the gun at the median, 266 s at p90 and
    /// 327 s at most. CI's simulator doesn't keep up with 8×: it races at about 3× (2.9-3.5× from the gun
    /// to the rounding on the runs measured), and the gun shows about 13 s after the status line. So the
    /// status line gets 10 s (it shows with the race clock), the gun 50 s, and the rounding 120 s, which
    /// covers 336 s of racing at 2.8×, past the slowest seed's. An 80 s wait for the rounding covered 224 s
    /// at that rate: it held only while the race drew a quick first beat. With the launch the waits add
    /// up to 3.5 min, under the 5 min CI gives a test (`RaceUITestCase`).
    @MainActor func testPracticeRaceOnTheNewCoreReachesTheGunAndAFirstRounding() throws {
        let app = launchRace(["-demo", "-timescale", "8"])
        let status = app.staticTexts["race-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "no race status line")
        // The label is matched in the query, so each poll is one existence check. A predicate expectation on
        // `status.label` resolved the element and read it on every poll, and on the iOS 27 simulator one such
        // read of the app racing at 8× blocked for 20 minutes, far past the wait's timeout.
        func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
            let predicate = NSPredicate(format: "identifier == %@ AND label MATCHES %@", "race-status", pattern)
            return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
        }
        XCTAssertTrue(waitForLabel(matching: ".*leg 1/.*", timeout: 50), "never started racing after the gun: \(status.label)")
        XCTAssertTrue(waitForLabel(matching: ".*leg ([2-9]|[1-9][0-9])/.*", timeout: 120),
                      "never rounded the first mark: \(status.label)")
        attachScreenshot(named: "race-first-rounding")
    }
}
