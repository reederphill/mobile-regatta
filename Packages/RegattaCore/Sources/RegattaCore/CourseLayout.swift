/// A windward–leeward course with an offset mark and a leeward gate, laid out from the race's files and
/// public seed (#12, #80): the one course type. Pure data; `derive` computes it from the files at load,
/// never storing a size in them (ADR 0004).
///
/// Laid square to the seeded mean wind direction and centred on the venue pairing's start-line centre.
/// Boats start upwind to the windward mark W, reach to the offset mark O, run down through the leeward
/// gate, and repeat; the last lap runs from O to the finish. The start and finish lines are separate
/// objects, the same segment for this course type.
///
/// Not sailed yet: the race sails `Course.standard` until race assembly wires this in (#81).
public struct CourseLayout: Sendable, Equatable {
    /// A mark: a buoy, or an end of the start or finish line.
    public struct Mark: Sendable, Equatable {
        public let name: String
        /// Metres.
        public let position: Vec2
        /// Metres.
        public let radius: Double
    }

    /// A line between a pin (port end looking upwind) and a committee boat (starboard end).
    public struct Line: Sendable, Equatable {
        public let pin: Mark
        public let committee: Mark

        public var centre: Vec2 { (pin.position + committee.position) / 2 }
        public var segment: Segment { Segment(pin.position, committee.position) }
        public var length: Double { (committee.position - pin.position).length }

        /// Signed distance from the line (or its extensions). Positive = course side (upwind).
        public func side(_ p: Vec2) -> Double {
            (committee.position - pin.position).normalized.cross(p - pin.position)
        }
    }

    /// Something the course is sailed around, in order.
    public enum Element: Sendable, Equatable {
        /// A single mark, left to `side`.
        case mark(Mark, side: RoundingSide)
        /// Two marks a boat passes between, from the previous mark's side, then rounds either (rule 28).
        /// `left` and `right` are looking downwind: `left` is rounded to port, `right` to starboard.
        case gate(left: Mark, right: Mark)

        public var marks: [Mark] {
            switch self {
            case .mark(let mark, _): [mark]
            case .gate(let left, let right): [left, right]
            }
        }
    }

    public enum Leg: Sendable, Equatable {
        /// Round `elements[index]`.
        case round(Int)
        /// Cross the finish line from the course side.
        case finish
    }

    /// Where a boat is on the course: the leg she is sailing, and how many of its rounding stages she
    /// has crossed (`roundingStages(of:)`).
    public struct Progress: Sendable, Equatable {
        public var legIndex: Int
        public var stage: Int
        public var finished: Bool

        public init(legIndex: Int = 0, stage: Int = 0, finished: Bool = false) {
            self.legIndex = legIndex
            self.stage = stage
            self.finished = finished
        }
    }

    /// Indices into `elements` of this course type's marks.
    public static let windwardIndex = 0
    public static let offsetIndex = 1
    public static let gateIndex = 2
    /// How far each rounding ray reaches from its mark, metres.
    public static let rayLength = 250.0
    public static let markRadius = 1.2
    public static let pinRadius = 1.0
    public static let committeeRadius = 2.5

    /// Compass bearing from the start line up to the windward mark: the seeded mean wind direction.
    public let axis: Double
    /// Metres from the line centre up the axis to the windward mark.
    public let beat: Double
    public let startLine: Line
    public let finishLine: Line
    /// W, O, gate (`windwardIndex`, `offsetIndex`, `gateIndex`).
    public let elements: [Element]
    /// Rounding order, from `RaceSetup.laps`: W → O → gate per lap but the last, which ends W → O → finish.
    public let legs: [Leg]
    /// Boundary: boats sail inside it.
    public let raceArea: RaceArea
    /// Boundary behaviour: the fraction of her speed along the edge a boat keeps on meeting it (#82).
    public let edgeSpeedRetention: Double
    /// Where boats are placed at the start of the sequence (#35).
    public let placement: RulesConfig.StartRow
    /// Rule 18 zone radius, metres.
    public let zoneRadius: Double

    public var upwind: Vec2 { .heading(axis) }
    public var right: Vec2 { upwind.rightPerp }

    /// Lays out the course for a race.
    ///
    /// - `windSetup`: the race's public wind setup, drawn from its race seed around the venue's pairing
    ///   for its conditions (#77): the axis is its seeded mean direction, the anchor its pairing's
    ///   start-line centre, and the beat is sized in its base strength.
    /// - `fleetSize`, `boatClass`: the line is `rules.raceFormat.startLine` for that many hulls.
    /// - `laps`: `RaceSetup.laps`, at least 1.
    ///
    /// Same inputs, identical course.
    public static func derive(
        windSetup: WindSetup, fleetSize: Int, laps: Int, boatClass: BoatClass, rules: RulesConfig
    ) -> CourseLayout {
        precondition(laps >= 1, "a race sails at least one lap")
        let format = rules.raceFormat
        let hull = boatClass.hull.length
        let axis = windSetup.meanDirection
        let up = Vec2.heading(axis)
        let right = up.rightPerp
        let anchor = windSetup.pairing.startLineCentre

        let beat = Self.beat(laps: laps, tws: windSetup.baseStrength, boatClass: boatClass, rules: rules)
        let lineLength = format.startLine.length(fleetSize: fleetSize, hullLength: hull)
        let line = Line(
            pin: Mark(name: "pin", position: anchor - right * (lineLength / 2), radius: pinRadius),
            committee: Mark(name: "committee boat", position: anchor + right * (lineLength / 2), radius: committeeRadius)
        )

        let windward = anchor + up * beat
        let offset = windward - right * format.offsetMark.toPort.metres(hullLength: hull)
        let gateCentre = anchor + up * (beat / format.leewardGate.aboveLineBeatDivisor)
        let halfGate = format.leewardGate.width.metres(hullLength: hull) / 2
        // Looking downwind, left is the upwind right.
        let elements: [Element] = [
            .mark(Mark(name: "windward mark", position: windward, radius: markRadius), side: .port),
            .mark(Mark(name: "offset mark", position: offset, radius: markRadius), side: .port),
            .gate(left: Mark(name: "gate left", position: gateCentre + right * halfGate, radius: markRadius),
                  right: Mark(name: "gate right", position: gateCentre - right * halfGate, radius: markRadius)),
        ]

        var legs: [Leg] = []
        for lap in 1...laps {
            legs += [.round(windwardIndex), .round(offsetIndex)]
            legs.append(lap < laps ? .round(gateIndex) : .finish)
        }

        let area = format.raceArea
        let below = area.belowLineLineLengths * lineLength
        let above = beat * (1 + area.aboveWindwardBeatFraction)
        let raceArea = RaceArea(
            centre: anchor + up * ((above - below) / 2),
            axis: axis,
            halfWidth: area.acrossAxisBeatFraction * beat,
            halfLength: (above + below) / 2
        )

        return CourseLayout(
            axis: axis, beat: beat, startLine: line, finishLine: line, elements: elements, legs: legs,
            raceArea: raceArea, edgeSpeedRetention: format.edgeSpeedRetention, placement: format.startRow,
            zoneRadius: rules.zoneRadius(hullLength: hull)
        )
    }

    /// The beat, metres: sized so the leader sails the race in `rules.raceFormat.beatSizing.leaderSeconds`
    /// in `tws` (m/s, the race's base strength), scaled by its calibration factor and capped at its
    /// maximum (#8, #14).
    ///
    /// The model: the leader sails each leg at the class polar's best, in steady wind, with no manoeuvres:
    /// upwind legs at best upwind VMG, downwind legs at best downwind VMG, and the reach from W to O at
    /// polar speed at 90° true wind angle. Per lap but the last she sails the beat up to W (the first from
    /// the line, later ones from the gate, `1 − 1/divisor` of the beat), the reach, and down from O to the
    /// gate; the last lap runs from O to the line instead. So with `n` laps she sails
    /// `k = 1 + (n − 1)(1 − 1/divisor)` beats each way plus `n` reaches, and the beat solves
    /// `beat × k × (1/vmgUp + 1/vmgDown) + n × offset / reachSpeed = leaderSeconds`. Manoeuvres, shifts and
    /// traffic make a real leader slower; the calibration factor (a placeholder, #105) is where the bot
    /// suite corrects for them.
    public static func beat(laps: Int, tws: Double, boatClass: BoatClass, rules: RulesConfig) -> Double {
        let format = rules.raceFormat
        let sizing = format.beatSizing
        let polar = boatClass.polar
        let upwindVMG = polar.bestUpwind(tws: tws).vmg
        let downwindVMG = polar.bestDownwind(tws: tws).vmg
        let reachSpeed = polar.speed(twa: .pi / 2, tws: tws)
        let reach = format.offsetMark.toPort.metres(hullLength: boatClass.hull.length)
        let n = Double(laps)
        let beatsEachWay = 1 + (n - 1) * (1 - 1 / format.leewardGate.aboveLineBeatDivisor)
        let secondsPerBeatMetre = beatsEachWay * (1 / upwindVMG + 1 / downwindVMG)
        let beat = (sizing.leaderSeconds - n * reach / reachSpeed) / secondsPerBeatMetre
        return min(beat * sizing.calibrationFactor, sizing.maxMetres)
    }

    /// The marks that begin, bound or end `leg` for rule 28: the mark or gate it rounds, or the finish
    /// line's ends.
    public func marksOfLeg(_ leg: Leg) -> [Mark] {
        switch leg {
        case .round(let index): elements[index].marks
        case .finish: [finishLine.pin, finishLine.committee]
        }
    }

    /// Every mark on the course, each once: rule 31's obstacles.
    public var obstacles: [Obstacle] {
        (elements.flatMap(\.marks) + [startLine.pin, startLine.committee])
            .map { Obstacle(name: $0.name, position: $0.position, radius: $0.radius) }
    }

    public func targetPosition(for leg: Leg) -> Vec2 {
        switch leg {
        case .round(let index):
            let marks = elements[index].marks
            return marks.reduce(Vec2.zero) { $0 + $1.position } / Double(marks.count)
        case .finish:
            return finishLine.centre
        }
    }

    public func name(of leg: Leg) -> String {
        switch leg {
        case .round(let index):
            switch elements[index] {
            case .mark(let mark, _): mark.name
            case .gate: "leeward gate"
            }
        case .finish: "finish line"
        }
    }

    /// The stages a boat crosses, in order, to complete a rounding leg: in each, crossing any one of its
    /// segments to its left (`crossing(from:to:over:) == 1`) moves her on. A single mark's two stages are
    /// its `roundingRays`, approached from the previous mark (upwind for W, from W for O). A gate's are
    /// the line between its marks, crossed downwind, then either mark's ray straight on downwind, crossed
    /// outwards as she turns round it. Empty for the finish.
    public func roundingStages(of leg: Leg) -> [[Segment]] {
        guard case .round(let index) = leg else { return [] }
        switch elements[index] {
        case .mark(let mark, let side):
            let approach = index == Self.windwardIndex ? upwind : (mark.position - windwardMark.position).normalized
            return roundingRays(around: mark.position, approach: approach, side: side, length: Self.rayLength)
                .map { [$0] }
        case .gate(let left, let right):
            let down = -upwind
            let leftRays = roundingRays(around: left.position, approach: down, side: .port, length: Self.rayLength)
            let rightRays = roundingRays(around: right.position, approach: down, side: .starboard, length: Self.rayLength)
            return [[Segment(left.position, right.position)], [leftRays[1], rightRays[1]]]
        }
    }

    /// Moves `progress` on for a boat sailing from `p0` to `p1`, as the race does each tick: crossing the
    /// current stage advances it, completing a leg's stages starts the next leg, and crossing the
    /// previous stage back undoes it. The finish leg completes on crossing the finish line downwind.
    public func advance(_ progress: inout Progress, from p0: Vec2, to p1: Vec2) {
        guard !progress.finished, progress.legIndex < legs.count else { return }
        let leg = legs[progress.legIndex]
        guard case .round = leg else {
            if crossing(from: p0, to: p1, over: finishLine.segment) == -1 { progress.finished = true }
            return
        }
        let stages = roundingStages(of: leg)
        if stages[progress.stage].contains(where: { crossing(from: p0, to: p1, over: $0) == 1 }) {
            progress.stage += 1
            if progress.stage == stages.count {
                progress.legIndex += 1
                progress.stage = 0
            }
        } else if progress.stage > 0,
                  stages[progress.stage - 1].contains(where: { crossing(from: p0, to: p1, over: $0) == -1 }) {
            progress.stage -= 1
        }
    }

    /// `progress` after sailing `path`, one straight step between each pair of consecutive positions.
    public func progress(along path: [Vec2], from start: Progress) -> Progress {
        var progress = start
        for (p0, p1) in zip(path, path.dropFirst()) { advance(&progress, from: p0, to: p1) }
        return progress
    }

    private var windwardMark: Mark { elements[Self.windwardIndex].marks[0] }
}
