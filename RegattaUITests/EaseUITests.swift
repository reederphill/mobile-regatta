import XCTest

/// Holding Ease lets the sheets go and the boat slows (#99, #112). skiff@4's ease floors at 30 % of the polar speed
/// with a 2 s time constant (about 46 % after 3 s), so the bar is under 60 % of the start speed after the hold, and
/// lower than after a 1 s hold. `press(forDuration:)` returns only after the release, with the boat already speeding
/// up again, so the held speeds are the ones the app saw the moment Ease was let go (`race-ease-release`).
final class EaseUITests: RaceUITestCase {
    /// Waits: launch 30 s, settle 5 s, three speed looks of up to 30 s each, and 4 s of holds: 129 s.
    @MainActor func testHoldingEaseSlowsTheBoat() throws {
        // Real time (the fixture default, pinned here), so a 3 s hold is 3 s of sailing.
        let app = launchRace(["-timescale", "1"])
        let ease = app.descendants(matching: .any)["race-ease"]
        XCTAssertTrue(ease.waitForExistence(timeout: 10), "no Ease button")
        let probe = app.descendants(matching: .any)["race-boat-speed"]
        let release = app.descendants(matching: .any)["race-ease-release"]
        // Up to speed on the autohelm before the gun.
        Thread.sleep(forTimeInterval: 5)
        let start = try speed(probe, labelled: "Boat speed")
        XCTAssertGreaterThan(start, 1, "the boat isn't sailing before the ease")

        ease.press(forDuration: 1)
        let oneSecondIn = try speed(release, labelled: "Ease released 1")
        ease.press(forDuration: 3)
        let afterHold = try speed(release, labelled: "Ease released 2")

        attachScreenshot(named: "ease")
        XCTContext.runActivity(named: "Speed \(start) kn, at a 1 s hold's release \(oneSecondIn) kn, at a 3 s hold's \(afterHold) kn") { _ in }
        XCTAssertLessThan(afterHold, start * 0.6, "Ease held 3 s: \(afterHold) kn from \(start) kn")
        XCTAssertLessThan(afterHold, oneSecondIn, "a 3 s hold slowed the boat no more than a 1 s hold")
    }

    /// The knots `probe` shows, from the first look at it with `label` (the release probe's label counts releases).
    @MainActor private func speed(_ probe: XCUIElement, labelled label: String) throws -> Double {
        let look = watch(probe, every: 0.5, until: .now.addingTimeInterval(30)) { $0.label == label }
        XCTAssertTrue(look.seen, "\(probe) never read \"\(label)\"")
        let snapshot = try XCTUnwrap(look.last, "no \(probe)")
        let text = snapshot.value as? String ?? ""
        return try XCTUnwrap(Double(text), "\(probe) \(text) is not a number")
    }
}
