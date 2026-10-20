import XCTest

/// Ease lets the sheets go and the boat slows (#99, #112). Ease is a gesture (#453: both halves held, or the tiller
/// pulled down), which XCUITest can't make (no two-finger hold; a drag lets go at its end), so this sails VoiceOver's
/// `race-ease` toggle: a tap puts Ease on, the next lets it go. The opening seats her eased (fleet-rules@8, #477), so
/// the first tap lets that go (release 1) and she sheets in. Before the gun skiff's ease floors at 50 % of the polar
/// speed with a 2 s time constant (about 61 % after 3 s), so the bar is under 70 % of the start speed after a 3 s ease,
/// and lower than after a 1 s one. The speeds are the ones the app saw the moment Ease was let go (`race-ease-release`).
final class EaseUITests: RaceUITestCase {
    /// Waits: launch 30 s, settle 5 s, four speed looks of up to 30 s each, and 4 s of easing: 159 s.
    @MainActor func testEasingSlowsTheBoat() throws {
        // Real time (the fixture default, pinned here), so a 3 s ease is 3 s of sailing.
        let app = launchRace(["-timescale", "1"])
        let ease = app.descendants(matching: .any)["race-ease"]
        XCTAssertTrue(ease.waitForExistence(timeout: 10), "no VoiceOver Ease element")
        let probe = app.descendants(matching: .any)["race-boat-speed"]
        let release = app.descendants(matching: .any)["race-ease-release"]
        // Out of the seated ease, then up to speed on the autohelm before the gun.
        ease.tap()
        _ = try speed(release, labelled: "Ease released 1")
        Thread.sleep(forTimeInterval: 5)
        let start = try speed(probe, labelled: "Boat speed")
        XCTAssertGreaterThan(start, 1, "the boat isn't sailing before the ease")

        ease.tap()
        Thread.sleep(forTimeInterval: 1)
        ease.tap()
        let oneSecondIn = try speed(release, labelled: "Ease released 2")
        ease.tap()
        Thread.sleep(forTimeInterval: 3)
        ease.tap()
        let afterHold = try speed(release, labelled: "Ease released 3")

        attachScreenshot(named: "ease")
        XCTContext.runActivity(named: "Speed \(start) kn, at a 1 s ease's release \(oneSecondIn) kn, at a 3 s ease's \(afterHold) kn") { _ in }
        XCTAssertLessThan(afterHold, start * 0.7, "Ease on 3 s: \(afterHold) kn from \(start) kn")
        XCTAssertLessThan(afterHold, oneSecondIn, "a 3 s ease slowed the boat no more than a 1 s ease")
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
