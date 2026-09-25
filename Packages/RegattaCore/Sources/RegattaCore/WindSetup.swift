import Foundation

/// What a venue says about one conditions entry it allows (#10, #12): the authored mean direction and
/// trend direction the race's `WindSetup` is drawn around.
///
/// A stub until venue files carry pairings (#72) and #77 replaces it with the venue file's pairing,
/// which adds the geographic-shift grid and the start-line anchor.
public struct VenuePairing: Hashable, Sendable {
    /// The authored direction of a persistent shift, for conditions that have one.
    public enum Trend: Hashable, Sendable {
        case left
        case right
        /// The race seed chooses (#10).
        case either
    }

    /// Authored compass direction the wind blows from, radians. The race seed varies it by up to
    /// `WindSetup.meanDirectionSpread` either way.
    public let meanDirection: Double
    /// Ignored for conditions with no trend.
    public let trend: Trend

    public init(meanDirection: Double, trend: Trend) {
        self.meanDirection = meanDirection
        self.trend = trend
    }

    /// Stand-in pairing until venues exist: wind from the north, square to today's `Course.standard`
    /// (axis 0), with the trend chosen by the seed.
    public static let stub = VenuePairing(meanDirection: 0, trend: .either)
}

/// The water a course's boats may sail in: a rectangle square to the course axis.
/// A placeholder shape until course derivation (#80) lays it out and wires it into `WindSetup`.
public struct RaceArea: Hashable, Sendable {
    /// Metres.
    public let centre: Vec2
    /// Compass bearing up the course, radians.
    public let axis: Double
    /// Metres from the centre to each side, across the axis.
    public let halfWidth: Double
    /// Metres from the centre to each end, along the axis.
    public let halfLength: Double

    public init(centre: Vec2, axis: Double, halfWidth: Double, halfLength: Double) {
        self.centre = centre
        self.axis = axis
        self.halfWidth = halfWidth
        self.halfLength = halfLength
    }

    /// A placeholder area around `course` until course derivation (#80) lays out the real one: square to
    /// its axis, from 150 m behind the start line (the start sequence) to 100 m past the windward mark,
    /// and half the beat plus 75 m either side of the axis (a beat's laylines, and room to overstand).
    /// For `Course.standard`'s 450 m beat: 700 m long, 600 m wide. Only the course's public layout goes
    /// into it, so it reveals nothing of the keyed wind (ADR 0001).
    public static func placeholder(around course: Course) -> RaceArea {
        let beat = course.marks.filter { $0.kind == .windward }
            .map { ($0.position - course.lineCenter).dot(course.upwind) }.max() ?? 0
        let behind = 150.0, beyond = 100.0
        return RaceArea(
            centre: course.lineCenter + course.upwind * ((beat + beyond - behind) / 2),
            axis: course.axis,
            halfWidth: beat / 2 + 75,
            halfLength: (beat + beyond + behind) / 2
        )
    }
}

/// Everything about a race's wind that is known before the gun: the conditions, the venue pairing, and
/// what the public race seed draws from them (#10). Every client can derive it, so it is shown in
/// the briefing (`forecast`) and may feed the course (#80). The secret moment-to-moment wind (shift,
/// trend size and timing, build, puffs) comes from the wind seed's key chain instead (ADR 0001, #75).
///
/// Drawn from the race seed on its own SplitMix64 stream (`seedStream`), so drawing it never moves any
/// other race-seed draw, and never touches the wind seed.
public struct WindSetup: Hashable, Sendable {
    /// Stream tag for `SplitMix64(seed:stream:)`: ASCII "windsetp".
    public static let seedStream: UInt64 = 0x7769_6E64_7365_7470
    /// How far the race seed may turn the mean direction from the pairing's authored one, either way (#10).
    public static let meanDirectionSpread = deg2rad(10)

    /// Direction of a persistent shift, looking upwind: right is clockwise (the wind veers), left is
    /// anticlockwise (it backs).
    public enum TrendDirection: Hashable, Sendable {
        case left
        case right

        /// +1 for right (clockwise, positive bearings), −1 for left.
        public var sign: Double { self == .right ? 1 : -1 }
    }

    /// The conditions file the race is sailed in, and its content.
    public let conditionsRef: FileRef
    public let conditions: Conditions
    public let pairing: VenuePairing
    /// Compass direction the wind blows from, radians in [−π, π): the pairing's authored direction
    /// turned by up to `meanDirectionSpread` either way. The course is laid square to it (#12).
    public let meanDirection: Double
    /// Base wind strength for the race, m/s, uniform in `conditions.strength`.
    public let baseStrength: Double
    /// The persistent shift's direction, or nil if the conditions have no trend. Public (#10);
    /// its size and timing are not.
    public let trend: TrendDirection?
    /// The race area, once course derivation lays it out (#80); nil until then.
    public private(set) var raceArea: RaceArea?

    /// Draws the race's wind setup from its public race seed.
    ///
    /// The stream is `SplitMix64(seed: raceSeed.value, stream: WindSetup.seedStream)`, drawn in a fixed
    /// order with one value per slot whether or not it is used: mean direction offset, base strength,
    /// trend coin. New draws go after these, so existing ones never move.
    public init(conditions: ConditionsFile, pairing: VenuePairing, raceSeed: RaceSeed, raceArea: RaceArea? = nil) {
        var rng = SplitMix64(seed: raceSeed.value, stream: Self.seedStream)
        let offset = rng.range(-Self.meanDirectionSpread, Self.meanDirectionSpread)
        let strength = rng.range(conditions.content.strength.lowerBound, conditions.content.strength.upperBound)
        let coin = rng.bool()

        conditionsRef = conditions.ref
        self.conditions = conditions.content
        self.pairing = pairing
        meanDirection = wrapAngle(pairing.meanDirection + offset)
        baseStrength = strength
        if conditions.content.trend == nil {
            trend = nil
        } else {
            switch pairing.trend {
            case .left: trend = .left
            case .right: trend = .right
            case .either: trend = coin ? .right : .left
            }
        }
        self.raceArea = raceArea
    }

    /// This setup with `raceArea` attached, every drawn value unchanged: course derivation (#80) needs
    /// the drawn setup to lay out the area, so it attaches the area afterwards instead of drawing twice.
    public func with(raceArea: RaceArea?) -> WindSetup {
        var copy = self
        copy.raceArea = raceArea
        return copy
    }

    /// The briefing's wind forecast (#15).
    public var forecast: WindForecast { WindForecast(self) }
}

/// The wind forecast shown in the briefing (#15): strength range, mean direction, shift and puff
/// character. Everything in it comes from the public `WindSetup`, so it never reveals what the keyed
/// wind will do (ADR 0001), and never the size or timing of a trend (#10). In display units: knots,
/// degrees and percentages as fractions.
public struct WindForecast: Hashable, Sendable {
    public let conditionsName: String
    /// The conditions' strength range, knots.
    public let strengthRangeKnots: ClosedRange<Double>
    /// This race's base strength, knots.
    public let baseStrengthKnots: Double
    /// Compass direction the wind blows from, degrees in [0, 360).
    public let meanDirectionDegrees: Double
    /// Which way a persistent shift will go, or nil for none.
    public let trend: WindSetup.TrendDirection?
    /// The oscillating shift: peak swing either side of the mean, degrees, and its period, seconds.
    public let shiftAmplitudeDegrees: Double
    public let shiftPeriodSeconds: ClosedRange<Double>
    public let puffs: PuffCharacter

    /// How puffy the conditions are.
    public struct PuffCharacter: Hashable, Sendable {
        /// Fraction of the water under a puff or lull at once.
        public let coverage: Double
        /// A puff's peak gain, as a fraction (0.2 = 20 % stronger).
        public let gain: ClosedRange<Double>
        /// Fraction of spawns that are lulls.
        public let lullShare: Double
        /// A lull's peak loss, as a fraction (0.2 = 20 % weaker).
        public let lullLoss: ClosedRange<Double>
        /// Largest direction change at a puff's edges, degrees.
        public let fanDegrees: Double
    }

    init(_ setup: WindSetup) {
        let c = setup.conditions
        conditionsName = c.name
        strengthRangeKnots = knots(metresPerSecond: c.strength.lowerBound)...knots(metresPerSecond: c.strength.upperBound)
        baseStrengthKnots = knots(metresPerSecond: setup.baseStrength)
        var degrees = rad2deg(setup.meanDirection).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        meanDirectionDegrees = degrees < 360 ? degrees : 0
        trend = setup.trend
        shiftAmplitudeDegrees = rad2deg(c.shift.amplitude)
        shiftPeriodSeconds = c.shift.period
        puffs = PuffCharacter(
            coverage: c.puffs.coverage,
            gain: c.puffs.gain,
            lullShare: c.puffs.lullShare,
            lullLoss: c.puffs.lullLoss,
            fanDegrees: rad2deg(c.puffs.fan)
        )
    }
}
