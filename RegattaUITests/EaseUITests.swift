import Foundation
import XCTest

/// Ease lets the sheets go and the boat slows (#99, #112). Ease is a gesture (#453: both halves held, or the tiller
/// pulled down), which XCUITest can't make (no two-finger hold; a drag lets go at its end), so this sails VoiceOver's
/// `race-ease` toggle: a tap puts Ease on, the next lets it go. The opening seats her eased (fleet-rules@8, #477), so
/// the first tap lets that go (release 1) and she sheets in.
///
/// Everything is measured in race time (#572): a slow simulator sails less race time than a wall-clock wait (a 3 s
/// wait was about 1.5 s of sailing on CI's runner), so the test holds Ease until the app has had it on the race seconds
/// it asks for (`race-ease-held`), and reads her speed and the race seconds held from the release itself
/// (`race-ease-release`, `race-ease-held`).
///
/// The bar comes from the physics. Before the gun an eased boat's target is fleet-rules@8's opening fraction, 0.5, of
/// her sheeted-in target, and skiff@9 slows towards it with its ease time constant, 2 s: after `h` race seconds eased
/// from her target she sails 0.5 + 0.5·e^(−h/2) of it (`easedShare`), 0.80 after 1 s and 0.61 after 3 s. The bar is
/// 0.70 of her start speed after a 3 s ease, as it always was, the 0.09 over the physics for a start a little under her
/// target (10 race seconds of speeding up from the eased half, skiff@9's 4.5 s time constant, leave her within 95 % of
/// it) and the wind's changes; a longer hold lowers the bar by the physics' own drop. From the gun the class's fraction,
/// 0.3, slows her more, so the bar holds there too.
///
/// The bar takes her wind as steady and her air as hers, so the race is `SeedTable.ease`, picked by a headless probe
/// (`regatta-botsuite ease-seed`, #579) for clear air and a steady wind over every runner speed it models. On seed 1
/// she sailed through two bots' ribbons before the gun: a fast runner read her start speed in a wake and the bar fell
/// under the long ease's speed (4.33 kn against 4.14).
final class EaseUITests: RaceUITestCase {
    /// fleet-rules@8's `raceFormat.opening.easeSpeedFraction`: before the gun an ease sails this share of her target.
    static let easedFraction = 0.5
    /// skiff@9's `ease.timeConstantSeconds`: race seconds.
    static let easeTimeConstant = 2.0
    /// Race seconds sheeted in before the start speed is read: skiff@9's `momentum.speedingUpSeconds` is 4.5, so 10
    /// leave her within 1 − 0.5·e^(−10/4.5) = 95 % of her target.
    static let settleSeconds = 10

    /// Her speed after `held` race seconds eased from her sheeted-in target, as a share of it.
    static func easedShare(after held: Double) -> Double {
        easedFraction + (1 - easedFraction) * exp(-held / easeTimeConstant)
    }

    /// Her speed's bar after a `held`-second ease, as a share of her start speed: 0.70 at 3 s, lower by the physics'
    /// drop for a longer hold.
    static func bar(after held: Double) -> Double {
        0.70 - (easedShare(after: 3) - easedShare(after: held))
    }

    /// Waits: launch 30 s, the first release's look 15 s, the clock's 15 s, settle 30 s, the start speed's look 15 s,
    /// and each of the two eases a 20 s hold and two 15 s looks: 205 s.
    @MainActor func testEasingSlowsTheBoat() throws {
        // Real time (the fixture default, pinned here), so a race second is a wall-clock second on a fast runner.
        let app = launchRace(["-seed", "\(SeedTable.ease)", "-timescale", "1"])
        let ease = app.descendants(matching: .any)["race-ease"]
        XCTAssertTrue(ease.waitForExistence(timeout: 10), "no VoiceOver Ease element")
        let status = app.staticTexts["race-status"]
        // Out of the seated ease, then up to speed on the autohelm before the gun.
        ease.tap()
        _ = try number(app, "race-ease-release", labelled: "Ease released 1")
        let sheetedIn = try XCTUnwrap(clock(status), "no race clock on \(status)")
        let settled = watch(status, every: 0.5, until: .now.addingTimeInterval(30)) {
            (Self.clock($0) ?? .min) > sheetedIn + Self.settleSeconds
        }
        XCTAssertTrue(settled.seen, "the race clock didn't run \(Self.settleSeconds) s past \(sheetedIn) s")
        let start = try number(app, "race-boat-speed", labelled: "Boat speed")
        XCTAssertGreaterThan(start, 1, "the boat isn't sailing before the ease")

        let short = try hold(ease, in: app, for: 1, release: 2)
        // At least 2 race seconds longer than the short one, however long that took to let go.
        let long = try hold(ease, in: app, for: max(3, short.held + 2), release: 3)

        attachScreenshot(named: "ease")
        let bar = Self.bar(after: long.held)
        XCTContext.runActivity(named: "Speed \(start) kn; after \(short.held) s eased \(short.knots) kn; after \(long.held) s eased \(long.knots) kn, bar \(bar) of the start") { _ in }
        XCTAssertGreaterThanOrEqual(long.held, 3, "the long ease was let go after \(long.held) race seconds")
        XCTAssertLessThan(long.knots, start * bar,
                          "Ease on \(long.held) race seconds: \(long.knots) kn from \(start) kn, over \(bar) of it")
        XCTAssertLessThan(long.knots, short.knots,
                          "a \(long.held) s ease slowed the boat no more than a \(short.held) s ease")
    }

    /// Puts Ease on, lets it go once the app has had it on `seconds` race seconds, and returns her speed at that
    /// release (the `release`th) and the race seconds it was held.
    @MainActor private func hold(_ ease: XCUIElement, in app: XCUIApplication, for seconds: Double,
                                 release: Int) throws -> (knots: Double, held: Double) {
        let held = app.descendants(matching: .any)["race-ease-held"]
        ease.tap()
        let holding = watch(held, every: 0.25, until: .now.addingTimeInterval(20)) {
            $0.label == "Easing" && (Double($0.value as? String ?? "") ?? 0) >= seconds
        }
        XCTAssertTrue(holding.seen, "Ease was never on \(seconds) race seconds: \(holding.last?.label ?? "no probe"), "
                      + "\(holding.last?.value as? String ?? "no value")")
        ease.tap()
        let knots = try number(app, "race-ease-release", labelled: "Ease released \(release)")
        let heldSeconds = try number(app, "race-ease-held", labelled: "Ease released \(release)")
        return (knots, heldSeconds)
    }

    /// The race clock's whole seconds from the gun (`race-status`'s value), one look.
    @MainActor private func clock(_ status: XCUIElement) -> Int? {
        let look = watch(status, every: 0.5, until: .now.addingTimeInterval(15)) { Self.clock($0) != nil }
        return look.last.flatMap(Self.clock)
    }

    private static func clock(_ snapshot: any XCUIElementSnapshot) -> Int? {
        Int(snapshot.value as? String ?? "")
    }

    /// The number probe `identifier` shows, from the first look at it with `label` (the release probes' labels count
    /// releases).
    @MainActor private func number(_ app: XCUIApplication, _ identifier: String, labelled label: String) throws -> Double {
        let probe = app.descendants(matching: .any)[identifier]
        let look = watch(probe, every: 0.5, until: .now.addingTimeInterval(15)) { $0.label == label }
        XCTAssertTrue(look.seen, "\(probe) never read \"\(label)\"")
        let snapshot = try XCTUnwrap(look.last, "no \(probe)")
        let text = snapshot.value as? String ?? ""
        return try XCTUnwrap(Double(text), "\(probe) \(text) is not a number")
    }
}
