import Foundation
import RegattaCore

/// The wake's tier (#127's thermal ladder seam): the full wake, or a shorter one with no centre streak. Both stay
/// speed-scaled, so the cue reads the same in either; only its length and its streak go.
nonisolated enum WakeQuality: Sendable {
    case full
    case short
}

/// How a boat's wake is drawn this frame (#15, #220, #121): its alpha is the pressure she feels. (Its V and streak numbers are the shape's, kept for the tuning panel; the wake the
/// scene draws is her stern's track, `BoatEffects.trail`.) Pure: presentation only,
/// nothing here reaches the race (ADR 0002).
///
/// "Speed is the wake" (#15): its length follows her speed through the water and nothing else (her class's hull,
/// planing and the tier aside), never the current that carries her over the ground, her position or her ground
/// speed. So a boat slowed in a wind shadow trails a shorter wake. Pressure (#220) fans and brightens it: a puff
/// widens the V, a lull, shadow or backwind narrows and fades it, even for a class whose shadow is a speed loss
/// (`BoatPose.feltWind`: shadow is turbulence).
nonisolated struct WakeShape: Equatable, Sendable {
    /// How far astern of her stern the V reaches, metres.
    var length: Double
    /// The V's half-angle, radians.
    var halfAngle: Double
    /// The V's alpha, 0 to 1.
    var alpha: Double
    /// The centre streak's length, metres, and alpha (0 in the short tier).
    var streakLength: Double
    var streakAlpha: Double

    static let none = WakeShape(length: 0, halfAngle: 0, alpha: 0, streakLength: 0, streakAlpha: 0)

    init(length: Double, halfAngle: Double, alpha: Double, streakLength: Double, streakAlpha: Double) {
        self.length = length
        self.halfAngle = halfAngle
        self.alpha = alpha
        self.streakLength = streakLength
        self.streakAlpha = streakAlpha
    }

    /// The wake of a boat sailing `speedThroughWater` m/s with a hull `hullLength` metres long, feeling `pressure`
    /// times her recent average wind (`BoatPose.pressure`), planing or not.
    init(speedThroughWater: Double, hullLength: Double, pressure: Double, isPlaning: Bool, style: BoatStyle,
         quality: WakeQuality) {
        let share = style.wakeFullSpeed > 0 ? (speedThroughWater / style.wakeFullSpeed).clamped(to: 0...1) : 1
        // Never below 1: planing never shortens her wake, whatever a saved style says.
        let planing = isPlaning ? max(style.wakePlaningBoost, 1) : 1
        let tier = quality == .short ? max(style.wakeShortShare, 0) : 1
        length = max(hullLength, 0) * max(style.wakeMaxHulls, 0) * share * planing * tier
        // A puff fans the V and a lull narrows it; never folded shut, never splayed flat.
        let fan = (1 + style.wakePressureFan * (pressure - 1)).clamped(to: 0.25...2)
        halfAngle = (deg2rad(style.wakeSpreadDegrees) * (0.5 + 0.5 * share) * fan * planing).clamped(to: 0...(Double.pi / 3))
        // Bad air fades it; more pressure than her average doesn't brighten it past its even-pressure look.
        alpha = (style.wakeAlpha * min(1, fan) * planing).clamped(to: 0...1)
        streakLength = quality == .short ? 0 : length * max(style.wakeStreakShare, 0)
        streakAlpha = quality == .short ? 0 : (alpha * style.wakeStreakAlpha).clamped(to: 0...1)
    }

    /// `boat`'s wake in `boatClass`.
    init(_ boat: Boat, boatClass: BoatClass, style: BoatStyle, quality: WakeQuality) {
        self.init(speedThroughWater: boat.speedThroughWater, hullLength: boatClass.hull.length,
                  pressure: BoatPose.pressure(boat), isPlaning: boat.isPlaning, style: style, quality: quality)
    }

    /// The step from `self` towards `target` after `dt` race seconds at `rate` per second (exponential).
    func eased(towards target: WakeShape, dt: Double, rate: Double) -> WakeShape {
        let k = rate > 0 ? 1 - exp(-max(dt, 0) * rate) : 1
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return WakeShape(length: mix(length, target.length), halfAngle: mix(halfAngle, target.halfAngle),
                         alpha: mix(alpha, target.alpha), streakLength: mix(streakLength, target.streakLength),
                         streakAlpha: mix(streakAlpha, target.streakAlpha))
    }
}
