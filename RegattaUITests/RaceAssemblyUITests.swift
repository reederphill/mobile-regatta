import XCTest

/// A practice race assembled on the new core (#81): the default setup's files, the derived course.
final class RaceAssemblyUITests: RaceUITestCase {
    /// A bot sails your boat (`-demo`) at 8×, so your status line shows the gun (racing on leg 1) and then
    /// the first rounding (a later leg). Leg 2 is the short reach from the windward mark to the offset mark,
    /// a second or two of real time at 8×, so a look can miss it: any leg past 1 shows the rounding.
    ///
    /// The race this launch sails (seed 1, eight skiffs), measured headless with the same setup (#231): your bot
    /// starts 2 s after the gun and rounds the windward mark 208 s after it. Over seeds 1-60 the same bot's first
    /// rounding is 189 s after the gun at the median, 266 s at p90 and 327 s at most. CI's simulator doesn't keep
    /// up with 8×: on the 11 runs after #231 the gun showed 8-19 s after the race clock and the rounding 44-76 s
    /// after the gun (2.7-4.7×).
    ///
    /// Each look at the status line is one snapshot every 2 s (`watch`): its label shows the leg and its value how
    /// far the race has run, so a failure says whether the race was slow or never rounded. A look that times out
    /// is tried again. Waiting for a label-matching query to exist asked about once a second while the app raced,
    /// and one query that timed out failed the test (#243). The status line, the gun and the rounding share one
    /// 180 s budget, so a quick start leaves the rounding more: after the slowest gun seen it has 160 s, which
    /// covers 208 s of racing at 1.3×. With the launch the waits add up to 3.5 min, under the 5 min CI gives a
    /// test (`RaceUITestCase`).
    @MainActor func testPracticeRaceOnTheNewCoreReachesTheGunAndAFirstRounding() throws {
        let app = launchRace(["-demo", "-timescale", "8"])
        // A uitesting-only probe (`RaceStatusProbe`, #114): the HUD shows no status line.
        let status = app.descendants(matching: .any)["race-status"].firstMatch
        let deadline = Date.now.addingTimeInterval(180)
        let gun = watch(status, until: deadline) { Self.leg(of: $0) != nil }
        XCTAssertTrue(gun.seen, "never started racing after the gun: \(Self.describe(gun.last))")
        let rounding = watch(status, until: deadline) { (Self.leg(of: $0) ?? 0) > 1 }
        XCTAssertTrue(rounding.seen, "never rounded the first mark: \(Self.describe(rounding.last))")
        attachScreenshot(named: "race-first-rounding")
    }

    /// The leg your status line shows while you race (`leg 2/6`), or nil before the gun and when you aren't racing.
    @MainActor private static func leg(of status: any XCUIElementSnapshot) -> Int? {
        status.label.firstMatch(of: /leg (\d+)\//).flatMap { Int($0.1) }
    }

    /// The status line a failure reports, with how far the race had run: `5th of 8 · leg 1/6, 185 s after the gun`.
    @MainActor private static func describe(_ status: (any XCUIElementSnapshot)?) -> String {
        guard let status else { return "no race status line" }
        return "\(status.label), \(status.value.map { "\($0)" } ?? "?") s after the gun"
    }
}
