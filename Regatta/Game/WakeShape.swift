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

/// What the planing cue (#492: the yellow speed tile, the stern-corner wakes) counts as a boat on the plane: the sim's
/// flag, but for the plane the race seats her on. `Race.init` puts every boat on the start row reaching at speed, so
/// the rule has her planing from her first tick until she has headed up for the line: a plane nobody sailed onto,
/// which the cue leaves out for `seatedSeconds` from the seating (`TickFrame.isJustSeated`). A boat still reaching
/// on the plane after that shows it, eased in as any other. The cue's alone: the race, and her wake's planing look
/// (#462), read the flag.
nonisolated enum PlaningCue {
    /// How long after the fleet is seated the cue shows no plane, race seconds: a fleet heads up off the row within
    /// about 2.5 s.
    static let seatedSeconds = 3.0

    static func shows(_ boat: Boat, justSeated: Bool) -> Bool { boat.isPlaning && !justSeated }
}

/// A boat's plane margin as it is drawn (#492): the sim's rule read by `BoatClass.PlaningTuning.planeMargin` from what
/// the rule itself reads (`BoatDynamics.advance`: her wind angle, her speed and the wind her polar sees), over the
/// style's ranges. 0 off the plane, and for a class that never planes. Of her flag: `PlaningCue.shows` is the
/// caller's to ask.
nonisolated enum PlaneMargin {
    static func of(_ boat: Boat, boatClass: BoatClass, style: BoatStyle) -> Double {
        guard let planing = boatClass.planing else { return 0 }
        return planing.planeMargin(isPlaning: boat.isPlaning, twa: boat.twa, speed: boat.speed,
                                   tws: boat.polarWindSpeed(in: boatClass), polar: boatClass.polar, ranges: ranges(style))
    }

    /// The style's ranges: its defaults are core's standard ones.
    static func ranges(_ style: BoatStyle) -> BoatClass.PlaningTuning.MarginRanges {
        BoatClass.PlaningTuning.MarginRanges(fullSpeedShare: style.planeMarginFullSpeedShare,
                                             apparentRange: metresPerSecond(knots: max(style.planeMarginApparentKnots, 0)),
                                             angleBand: deg2rad(max(style.planeMarginAngleBandDegrees, 0)))
    }
}

/// The two stern-corner wakes of a planing boat (#492): how much of their longest is drawn, 0...1. Their length is her
/// plane margin, so they shorten as she nears falling off the plane and are gone when she is off. Pure: drawn only,
/// nothing here reaches the race (ADR 0002).
///
/// On the plane they are never shorter than `BoatStyle.cornerWakeMinShare` of their longest, so the last stretch
/// before a fall still reads; they come and go as her wake's planing look does (a `PlaningEase.level`, of the plane
/// the cue counts), not with the flag, so a fall draws them in over about a second; and they follow her margin at
/// `BoatStyle.cornerWakeEaseRate`, so no frame moves them more than `1 - exp(-dt * rate)`. Off the plane the margin
/// she last had on it is kept, so a fall draws them in from where they were and a boat held on the edge of the plane,
/// her flag flickering, trails them steady.
nonisolated struct CornerWakes: Equatable, Sendable {
    /// The share of their longest drawn, 0...1.
    private(set) var share: Double
    /// Her plane margin when she last planed.
    private(set) var margin: Double

    /// As she is, with nothing to ease from (her first frame, a frozen frame): `level` of the way on the plane.
    init(margin: Double, isPlaning: Bool, level: Double, style: BoatStyle) {
        self.margin = isPlaning ? margin.clamped(to: 0...1) : 0
        share = Self.target(margin: self.margin, level: level, style: style)
    }

    /// The share to settle at: between the shortest and the longest by her margin, times how far on the plane she is
    /// drawn.
    static func target(margin: Double, level: Double, style: BoatStyle) -> Double {
        let shortest = style.cornerWakeMinShare.clamped(to: 0...1)
        return level.clamped(to: 0...1) * (shortest + (1 - shortest) * margin.clamped(to: 0...1))
    }

    /// `dt` race seconds on: towards `margin` while she planes, and the margin she last had while she doesn't.
    mutating func advance(margin: Double, isPlaning: Bool, level: Double, dt: Double, style: BoatStyle) {
        if isPlaning { self.margin = margin.clamped(to: 0...1) }
        let target = Self.target(margin: self.margin, level: level, style: style)
        let k = style.cornerWakeEaseRate > 0 ? 1 - exp(-max(dt, 0) * style.cornerWakeEaseRate) : 1
        share += (target - share) * k
    }

    /// The race seconds of her track they are drawn over, of a middle wake `wakeSeconds` long.
    func seconds(wakeSeconds: Double, style: BoatStyle) -> Double {
        max(wakeSeconds, 0) * style.cornerWakeLengthShare.clamped(to: 0...1) * share
    }

    /// Their alpha: the style's, fading with them below their shortest as she comes off the plane or gets on, so they
    /// never pop in or out at a stub's length.
    func alpha(style: BoatStyle) -> Double {
        let shortest = max(style.cornerWakeMinShare.clamped(to: 0...1), 0.1)
        return style.cornerWakeAlpha.clamped(to: 0...1) * min(1, share / shortest)
    }
}
