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
    /// times her recent average wind (`BoatPose.pressure`), `planing` of the way on the plane: 0 off it, 1 on it,
    /// between them while her wake settles or lifts (`PlaningEase.level`, #462).
    init(speedThroughWater: Double, hullLength: Double, pressure: Double, planing level: Double, style: BoatStyle,
         quality: WakeQuality) {
        let share = style.wakeFullSpeed > 0 ? (speedThroughWater / style.wakeFullSpeed).clamped(to: 0...1) : 1
        // Never below 1: planing never shortens her wake, whatever a saved style says.
        let planing = 1 + (max(style.wakePlaningBoost, 1) - 1) * level.clamped(to: 0...1)
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

    /// `boat`'s wake in `boatClass`, `planing` of the way on the plane; nil: all the way on or off, as she is (a
    /// frozen frame, with nothing to ease from).
    init(_ boat: Boat, boatClass: BoatClass, style: BoatStyle, quality: WakeQuality, planing level: Double? = nil) {
        self.init(speedThroughWater: boat.speedThroughWater, hullLength: boatClass.hull.length,
                  pressure: BoatPose.pressure(boat), planing: level ?? PlaningEase(isPlaning: boat.isPlaning).level,
                  style: style, quality: quality)
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

/// How far on the plane a boat is drawn (#462): her wake's planing look (`BoatStyle.wakePlaningBoost`) comes and goes
/// over `BoatStyle.wakePlaningSeconds` instead of with the flag, so a fall off the plane reads as her settling and
/// getting back on as her lifting, and a boat held on the edge of the plane never flickers. Pure: drawn only, nothing
/// here reaches the race (ADR 0002).
///
/// `progress` runs straight between 0 and 1 at 1 / seconds, turning round wherever it is when the flag flips back;
/// `level`, what is drawn, is its smoothstep, so it leaves and arrives gently and no frame moves it more than
/// `1.5 * dt / seconds`.
nonisolated struct PlaningEase: Equatable, Sendable {
    /// 0 off the plane, 1 on it.
    private(set) var progress: Double

    /// All the way on or off, as she is.
    init(isPlaning: Bool) {
        progress = isPlaning ? 1 : 0
    }

    /// The share of the planing look to draw, 0...1.
    var level: Double { progress * progress * (3 - 2 * progress) }

    /// `dt` race seconds on, towards on or off the plane, the whole way taking `seconds`; at once with none.
    mutating func advance(isPlaning: Bool, dt: Double, seconds: Double) {
        let target: Double = isPlaning ? 1 : 0
        guard seconds > 0 else {
            progress = target
            return
        }
        let step = max(dt, 0) / seconds
        progress = isPlaning ? min(progress + step, target) : max(progress - step, target)
    }
}
