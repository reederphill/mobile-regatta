import XCTest

/// A practice race assembled on the new core (#81): the default setup's files, the derived course.
final class RaceAssemblyUITests: RaceUITestCase {
    /// A bot sails your boat (`-demo`) at 8×, so your status line shows the gun (racing on leg 1) and then
    /// the first rounding (a later leg). Leg 2 is the short reach from the windward mark to the offset mark,
    /// a second or two of real time at 8×, so a look can miss it: any leg past 1 shows the rounding.
    ///
    /// The race this launch sails (`SeedTable.firstRounding`, eight skiffs) is picked by condition
    /// (`scripts/pick-ui-seeds.sh`): your bot starts within 2 s of the gun and rounds the windward mark within 140 s
    /// of it, with no rule call against her. On fleet-rules@8 (the opening, #477) seed 18 does: she starts 0.1 s after
    /// the gun and rounds 138 s after it, measured headless. Over seeds 1-60 the same bot's first rounding is 166 s
    /// after the gun at the median, 202 s at p90 and 229 s at most; the most is seed 1, the seed this test launched
    /// until #477: she takes two windward-leeward calls in the opening and one while tacking 24 s after the gun, and
    /// serves the last two turns after it, so she starts 7 s late, is 8th from 16 s and rounds 229 s after it. CI's simulator doesn't keep up with 8×: on #477's two runs the gun
    /// showed 35-48 s after the budget began and the race then ran at 1.25-1.4× (2.7-4.7× on the 11 runs after #231).
    ///
    /// Each look at the status line is one snapshot every 2 s (`watch`): its label shows the leg and its value how
    /// far the race has run, so a failure says whether the race was slow or never rounded. A look that times out
    /// is tried again. Waiting for a label-matching query to exist asked about once a second while the app raced,
    /// and one query that timed out failed the test (#243). The status line, the gun and the rounding share one
    /// 180 s budget, so a quick start leaves the rounding more: after the slowest gun seen it has 132 s, which
    /// covers 165 s of racing at 1.25×, and #477's runs reached 157-170 s after the gun. With the launch the waits
    /// add up to 3.5 min, under the 5 min CI gives a test (`RaceUITestCase`).
    @MainActor func testPracticeRaceOnTheNewCoreReachesTheGunAndAFirstRounding() throws {
        let app = launchRace(["-demo", "-seed", "\(SeedTable.firstRounding)", "-timescale", "8"])
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
