import Foundation
import RegattaCore

/// What the race HUD shows (#114, #15): the clock and its tone, your place, and the ground wind as words. Pure, over
/// a `HUDState`, so the tests read exactly what the view draws.
struct HUDModel {
    /// The clock's colour: white while racing, the cue yellow in the start sequence and while the race counts down
    /// to its close after the first finish (#30 reuses the sequence's clock).
    enum ClockTone: Equatable {
        case white, yellow
    }

    let hud: HUDState

    init(_ hud: HUDState) {
        self.hud = hud
    }

    /// Seconds from now to the close, negative, once a boat has finished (`closeTick`); nil before. The race reads
    /// the close as the earlier of the first finish plus the finish window and the time limit (`Race.closeTick`); the
    /// HUD never works that out itself.
    var closeCountdown: Double? {
        hud.closeTick.map { min(0, Double(hud.tick - $0) / Double(Race.tickRate)) }
    }

    /// The clock: the sequence counting down to the gun, the race counting up, and after the first finish the
    /// countdown to the close in the sequence's style (`-1:58`).
    var clockText: String {
        formatClock(closeCountdown ?? hud.clock)
    }

    var clockTone: ClockTone {
        hud.clock < 0 || hud.closeTick != nil ? .yellow : .white
    }

    /// Your place in the place slot: "4th/10", "OCS" while you're over (never red, #15), "DSQ"; nil before the gun,
    /// when standings mean nothing (its space stays).
    var placeText: String? {
        switch hud.status {
        case .ocs: "OCS"
        case .dsq: "DSQ"
        case .prestart where hud.clock < 0: nil
        case .prestart, .racing, .finished: "\(ordinal(hud.place))/\(hud.fleet)"
        }
    }

    /// The ground wind at your boat in words: "12 kn, from 352°".
    var windText: String {
        Self.windText(knots: hud.windKnots, direction: hud.windDirection)
    }

    static func windText(knots: Double, direction: Double) -> String {
        let (speed, from) = windParts(knots: knots, direction: direction)
        return "\(speed), \(from)"
    }

    /// The wind's words in two parts, "12 kn" and "from 352°", for the readout's two-line form on a narrow screen.
    var windParts: (speed: String, from: String) {
        Self.windParts(knots: hud.windKnots, direction: hud.windDirection)
    }

    static func windParts(knots: Double, direction: Double) -> (speed: String, from: String) {
        var degrees = Int(rad2deg(direction).rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return ("\(Int(knots.rounded())) kn", "from \(degrees)°")
    }

    /// Where compass bearing `compass` (radians) points on screen, clockwise from screen up, with `viewHeading` (the
    /// scene's, #113) at the top: what an arrow drawn pointing up turns by, in course-up and boat-up alike (#13). The
    /// HUD reads the heading every frame, so the arrow turns with the view, not after it.
    static func screenAngle(ofCompass compass: Double, viewHeading: Double) -> Double {
        wrapAngle(compass - viewHeading)
    }

    // MARK: The instruments (#457)

    /// The bottom row's speed and apparent wind show from the start of the race scene, the approach included, and
    /// hide once you're done (finished, DSQ, or a ghost at the close): the HUD speaks of the racing boat only.
    var showsInstruments: Bool {
        hud.status.isRacingOrStarting && !hud.isGhost
    }

    /// Your speed through the water, one decimal, smoothed: "6.4" (over "kn").
    var speedText: String { Self.speedText(knots: hud.shownInstruments.speedKnots) }
    /// The apparent wind's angle off the bow and the side it comes over: "38° port", "38° starboard"; no side word
    /// dead ahead or dead astern.
    var apparentAngleText: String { Self.apparentAngleText(angle: hud.shownInstruments.apparentAngle) }
    /// The apparent wind's speed, whole knots: "21 kn".
    var apparentSpeedText: String { Self.knotsText(hud.shownInstruments.apparentKnots) }

    /// VoiceOver's values (read on demand, never announced): "6.4 knots", "38 degrees port, 21 knots".
    var speedAccessibilityValue: String { "\(speedText) knots" }
    var apparentAccessibilityValue: String {
        let (degrees, side) = Self.apparentAngleParts(angle: hud.shownInstruments.apparentAngle)
        let knots = Int(max(0, hud.shownInstruments.apparentKnots).rounded())
        let angle = "\(degrees) \(degrees == 1 ? "degree" : "degrees")" + (side.map { " \($0)" } ?? "")
        return "\(angle), \(knots) \(knots == 1 ? "knot" : "knots")"
    }

    static func speedText(knots: Double) -> String {
        // Never "-0.0": a boat pushed backwards reads 0.0.
        let tenths = (knots * 10).rounded() / 10
        return String(format: "%.1f", tenths > 0 ? tenths : 0)
    }

    static func knotsText(_ knots: Double) -> String {
        "\(Int(max(0, knots).rounded())) kn"
    }

    static func apparentAngleText(angle: Double) -> String {
        let (degrees, side) = apparentAngleParts(angle: angle)
        return side.map { "\(degrees)° \($0)" } ?? "\(degrees)°"
    }

    /// Whole degrees off the bow, 0...180, and "port" or "starboard"; nil at 0° and 180°.
    static func apparentAngleParts(angle: Double) -> (degrees: Int, side: String?) {
        let wrapped = wrapAngle(angle)
        let degrees = Int(abs(rad2deg(wrapped)).rounded())
        guard degrees > 0, degrees < 180 else { return (degrees, nil) }
        return (degrees, wrapped > 0 ? "starboard" : "port")
    }
}
