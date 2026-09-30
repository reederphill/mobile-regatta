import XCTest

/// Holding Ease lets the sheets go and the boat slows (#99, #112). skiff@4's ease floors at 30 % of the polar speed
/// with a 2 s time constant (about 46 % after 3 s), so the bar is under 60 % of the start speed after the hold, and
/// still falling from where it was 1 s in.
final class EaseUITests: RaceUITestCase {
    /// Waits: launch 30 s, settle 5 s, four speed looks of up to 30 s each, and 4 s of holds: 159 s.
    @MainActor func testHoldingEaseSlowsTheBoat() throws {
        let app = launchRace()
        let ease = app.descendants(matching: .any)["race-ease"]
        XCTAssertTrue(ease.waitForExistence(timeout: 10), "no Ease button")
        let probe = app.descendants(matching: .any)["race-boat-speed"]
        // Up to speed on the autohelm before the gun.
        Thread.sleep(forTimeInterval: 5)
        let start = try speed(probe)
        XCTAssertGreaterThan(start, 1, "the boat isn't sailing before the ease")

        ease.press(forDuration: 1)
        let oneSecondIn = try speed(probe)
        ease.press(forDuration: 3)
        let afterHold = try speed(probe)

        attachScreenshot(named: "ease")
        XCTContext.runActivity(named: "Speed \(start) kn, 1 s in \(oneSecondIn) kn, after the hold \(afterHold) kn") { _ in }
        XCTAssertLessThan(afterHold, start * 0.6, "Ease held 3 s: \(afterHold) kn from \(start) kn")
        XCTAssertLessThan(afterHold, oneSecondIn, "still falling after 1 s of Ease")
    }

    /// Your boat's speed in knots, from the first look at the probe that doesn't throw.
    @MainActor private func speed(_ probe: XCUIElement) throws -> Double {
        let look = watch(probe, every: 0.5, until: .now.addingTimeInterval(30)) { _ in true }
        let snapshot = try XCTUnwrap(look.last, "no boat speed probe")
        let text = snapshot.value as? String ?? snapshot.label
        return try XCTUnwrap(Double(text), "boat speed \(text) is not a number")
    }
}
