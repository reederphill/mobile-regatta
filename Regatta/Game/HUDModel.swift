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
        var degrees = Int(rad2deg(direction).rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return "\(Int(knots.rounded())) kn, from \(degrees)°"
    }

    /// Where compass bearing `compass` (radians) points on screen, clockwise from screen up, with `viewHeading` (the
    /// scene's, #113) at the top: what an arrow drawn pointing up turns by, in course-up and boat-up alike (#13). The
    /// HUD reads the heading every frame, so the arrow turns with the view, not after it.
    static func screenAngle(ofCompass compass: Double, viewHeading: Double) -> Double {
        wrapAngle(compass - viewHeading)
    }
}
