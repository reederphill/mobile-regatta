import Foundation
import RegattaCore

/// Eases a boat's drawn position and heading onto a corrected prediction (#18, ADR 0005): when a server
/// snapshot moves the predicted boat, the simulation takes the new state at once and the drawing follows
/// over about 150 ms. An error larger than one hull length snaps instead.
///
/// Presentation only: it never feeds back into a race. The online driver (#68) keeps one per boat; a
/// practice race is never corrected, so it doesn't use one.
struct VisualCorrection {
    /// Time for an error to ease out: it's down to an eighth by then.
    static let easeDuration = 0.15
    /// Three half-lives make the ease: an error halves in about 50 ms.
    static let halfLife = easeDuration / 3
    /// A position error larger than this snaps rather than eases: one hull length of the boat class.
    let snapDistance: Double

    /// What's drawn minus the prediction.
    private(set) var positionError = Vec2.zero
    private(set) var headingError = 0.0

    /// `snapDistance`: the boat class's hull length (`BoatClass.Hull.length`).
    init(snapDistance: Double) {
        self.snapDistance = snapDistance
    }

    /// The prediction moved from where the boat was drawn, `shown` (with any easing still running), to
    /// `corrected`. The drawing starts from `shown` and eases onto the prediction, or snaps to it if the
    /// jump is more than `snapDistance`.
    mutating func correct(shown: Boat, corrected: Boat) {
        let jump = shown.position - corrected.position
        if jump.length > snapDistance {
            positionError = .zero
            headingError = 0
        } else {
            positionError = jump
            headingError = wrapAngle(shown.heading - corrected.heading)
        }
    }

    /// Eases the error for `dt` seconds of real time.
    mutating func advance(by dt: Double) {
        guard dt > 0 else { return }
        let keep = pow(0.5, dt / VisualCorrection.halfLife)
        positionError *= keep
        headingError *= keep
    }

    /// `boat`, as it's drawn now.
    func applied(to boat: Boat) -> Boat {
        var drawn = boat
        drawn.position += positionError
        drawn.heading = wrapAngle(boat.heading + headingError)
        return drawn
    }
}
