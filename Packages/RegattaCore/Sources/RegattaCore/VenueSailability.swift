import Foundation

/// The offline sailability check (#11, #14, #83): whether a close-hauled boat can make way up every pairing's beat
/// in a 25 % lull at the current's strongest. Run by the tests over every bundled venue; never by a race. Pure.
///
/// For each pairing, on each course `VenueCheck.layouts` lays (every rotation of the mean, the largest fleet and the
/// longest beat), the wind is the conditions' weakest strength less `lull`, turned and scaled by the pairing's
/// geographic grid where it is sampled. Points are sampled every `sampleSpacingMetres` over the race area from the
/// start line up to the windward mark, off the land. At each, for every tide state at the gun the venue allows (in
/// `tideStepDegrees` steps; one state for a venue without current), the current (`CurrentField`, eddies included) is
/// taken off the ground wind to give the sailing wind (as `BoatWinds.resolve`), the boat sails the class polar's best
/// upwind angle on each tack, and her progress is her velocity over the ground (through the water plus the current)
/// along the course axis, on the better tack. The pairing passes when, on every course and at every tide state:
///
/// 1. somewhere across the beat, progress is at least `minimumProgressKnots`;
/// 2. nowhere is it negative: a close-hauled boat is never swept backwards.
public enum VenueSailability {
    /// The lull: the wind is the conditions' weakest strength less this fraction (#14).
    public static let lull = 0.25
    /// Knots of progress over the ground up the course a boat must make somewhere across the beat (#14).
    public static let minimumProgressKnots = 1.0
    /// Degrees between the tide states swept over the venue's allowed range at the gun: fine enough to catch the
    /// current's peak, which the channel and shallows reach at different phases (#316; 15° until then).
    public static let tideStepDegrees = 5.0
    /// Metres between sample points, along and across the course.
    public static let sampleSpacingMetres = 20.0

    /// One pairing's result.
    public struct Result: Sendable, Equatable, CustomStringConvertible {
        public let pairing: DataFileKey
        /// Knots: over every course and tide state, the least of the best progress anywhere across the beat.
        public let bestProgressKnots: Double
        /// Knots: the least progress on the better tack anywhere, on any course, at any tide state.
        public let worstProgressKnots: Double
        /// Why the pairing couldn't be checked (its conditions file wasn't found), or nil.
        public let problem: String?

        public var passes: Bool {
            problem == nil && bestProgressKnots >= minimumProgressKnots && worstProgressKnots >= 0
        }

        public var description: String {
            if let problem { return "\(pairing.id)@\(pairing.version): \(problem)" }
            return "\(pairing.id)@\(pairing.version): "
                + String(format: "best %.2f kn, worst %.2f kn", bestProgressKnots, worstProgressKnots)
        }
    }

    /// The tide states at the gun swept for `venue`, radians: one (0) without current, else the allowed range in
    /// `tideStepDegrees` steps, both ends included (once, for the whole cycle).
    static func tideStates(_ venue: Venue) -> [Double] {
        guard let range = venue.current?.allowedTideStatesAtGun else { return [0] }
        let step = deg2rad(tideStepDegrees)
        let count = max(1, Int((range.width / step).rounded(.up)))
        let last = range.isWholeCycle ? count - 1 : count
        return (0...last).map { range.from + range.width * Double($0) / Double(count) }
    }

    /// One result per pairing of `venue`, in pairing order.
    public static func check(
        _ venue: Venue,
        boatClass: BoatClass = RaceFiles.defaults.boatClass.content,
        rules: RulesConfig = RaceFiles.defaults.rulesConfiguration.content,
        conditions: (DataFileKey) throws -> ConditionsFile = { try ConditionsFile.bundled(id: $0.id, version: $0.version) }
    ) -> [Result] {
        venue.pairings.map { pairing in
            guard let file = try? conditions(pairing.conditions) else {
                return Result(pairing: pairing.conditions, bestProgressKnots: 0, worstProgressKnots: 0,
                              problem: "conditions file not found")
            }
            let wind = file.content.strength.lowerBound * (1 - lull)
            var best = Double.infinity
            var worst = Double.infinity
            for (_, layout) in VenueCheck.layouts(venue: venue, pairing: pairing, conditions: file, boatClass: boatClass, rules: rules) {
                let points = samplePoints(layout)
                for tide in tideStates(venue) {
                    let field = CurrentField(current: venue.current, tideStateAtGun: tide)
                    var bestHere = -Double.infinity
                    for p in points {
                        let progress = progress(at: p, layout: layout, pairing: pairing, wind: wind, field: field,
                                                polar: boatClass.polar)
                        bestHere = max(bestHere, progress)
                        worst = min(worst, progress)
                    }
                    best = min(best, bestHere)
                }
            }
            return Result(pairing: pairing.conditions, bestProgressKnots: knots(metresPerSecond: best),
                          worstProgressKnots: knots(metresPerSecond: worst), problem: nil)
        }
    }

    /// Points every `sampleSpacingMetres` from the start line to the windward mark, across the race area, off land.
    static func samplePoints(_ layout: CourseLayout) -> [Vec2] {
        let anchor = layout.startLine.centre
        let halfWidth = layout.raceArea.halfWidth
        let along = Int((layout.beat / sampleSpacingMetres).rounded(.down))
        let across = Int((halfWidth / sampleSpacingMetres).rounded(.down))
        var points: [Vec2] = []
        for i in 0...along {
            for j in -across...across {
                let p = anchor + layout.upwind * (Double(i) * sampleSpacingMetres) + layout.right * (Double(j) * sampleSpacingMetres)
                if layout.isInRaceArea(p) { points.append(p) }
            }
        }
        return points
    }

    /// Metres per second a close-hauled boat at `p` makes up the course over the ground, on the better tack, in a
    /// ground wind of `wind` m/s from the course's axis, shifted by the pairing's geography, and `field`'s current
    /// at the gun.
    static func progress(
        at p: Vec2, layout: CourseLayout, pairing: Venue.Pairing, wind: Double, field: CurrentField, polar: PolarTable
    ) -> Double {
        let shift = pairing.geographicGrid.sample(p)
        let ground = Wind(direction: wrapAngle(layout.axis + shift.directionDelta), speed: wind * shift.speedFactor)
        let current = field.sample(p, tick: 0)
        let sailing = BoatWinds.resolve(ground: ground, current: current, velocityThroughWater: .zero).sailing
        let optimum = polar.bestUpwind(tws: sailing.speed)
        return [1.0, -1.0].map { tack in
            let throughWater = Vec2.heading(sailing.direction + tack * optimum.twa) * optimum.speed
            return (throughWater + current).dot(layout.upwind)
        }.max()!
    }
}
