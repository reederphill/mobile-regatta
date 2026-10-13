import Foundation
import RegattaCore

// `regatta-botsuite --diagnose`'s roundings (#511): how many metres more than the ideal path a boat sails to round a
// mark, as #464's probe scored them. It reads a boat's position, wind, leg and rounding stage tick by tick, as the
// rest of `RaceObserver` does, and no bot. This file is what one race gives: one `RoundingObservation` a rounding a
// boat completed. `DiagnoseReport.swift` pools them into the `roundings` table.

/// The marks of the course a boat rounds: the windward mark, the offset mark after it and the leeward gate.
public enum RoundingMark: String, CaseIterable, Codable, Hashable, Sendable {
    case windward, offset, gate
}

/// One rounding of one mark by one boat, against the ideal path. A rounding is hers from its entry (her first tick
/// racing on the leg to the mark, not yet round it, within `entryRange` of it and still to come to it:
/// `windwardBelow` below the windward mark, `gateAbove` above the gate's centre) over her crossing (the tick the
/// race first counts her past the mark, `Boat.roundingStage`) to the leg's end, and `exitSeconds` on. One she did
/// not sail to the leg's end is not counted.
///
/// The three extras are metres sailed over the ideal:
/// - the approach, entry to crossing, against the ideal path from the entry to a point `targetOffset` off the mark
///   on the side she passes it (the gate: `gateInset` inside the end the ideal reaches sooner);
/// - the rounding, crossing to the leg's end, against the straight line between the two;
/// - the exit, the `exitSeconds` after, against the ideal path of the next leg from where she was to where she got.
///
/// The ideal path of a beat or a run is the tacking or gybing cone: inside the laylines of the point, the distance
/// sailed at the polar's best angle; outside them, and on a reach, the straight line. So a boat that sails straight
/// at a mark inside the cone, pinching or by the lee, scores a negative extra. That is real and not clamped.
///
/// A boat's roundings overlap: the exit from the windward mark is the approach to the offset mark. Their extras
/// don't add up to a race's.
///
/// At the gate the rounding's straight line starts where she crossed the gate's line, so a boat that crosses at the
/// centre and then sails along the line to a mark is not charged for it. `entryToEnd` (#519) is the gate's measure
/// that does not depend on where she crossed. `belowTheLine` (#519) is the gate's measure with no ideal in it.
public struct RoundingObservation: Hashable, Sendable {
    public var mark: RoundingMark
    public var approachExtra: Double
    public var roundExtra: Double
    public var exitExtra: Double
    /// Before her crossing she was past the mark (`pastMark`) on the side she doesn't round it: the windward and the
    /// offset mark, both left to port. Never at the gate.
    public var wrongSide: Bool
    /// The ticks before her crossing she was more than `belowLine` below the gate's line. 0 at a mark.
    public var overshootTicks: Int
    /// The gate, entry to the leg's end as one span against one ideal (#519). Nil at a mark.
    public var entryToEnd: EntryToEnd?
    /// The gate, her time and depth beyond it (#519). Nil at a mark.
    public var belowTheLine: BelowTheLine?

    /// How long and how deep a boat was below the gate's line. She is below it on a tick she is more than `belowLine`
    /// below its level, the overshoot count's test: the distance along the line's normal, anywhere along the line's
    /// extension, so outside a mark as between them.
    ///
    /// The span is from her first tick below it on the gate's leg to her last one, to the end of the rounding's exit
    /// (`exitSeconds` after the leg's end): the ticks she was back above it in between are in it. So an overshoot's
    /// circling under the line outside a mark counts from its first tick, before she crosses the line at all.
    ///
    /// The race ends the gate's leg below the line: on the tick she crosses, outwards, the ray straight down the wind
    /// from the mark she rounds (`CourseLayout.roundingStages`). So the span runs on into the next leg, until she has
    /// climbed back to the line's level outside the mark.
    ///
    /// No ideal path is in it, so a rounding sailed as well as a boat can is a few seconds, not 0: read it as one tree
    /// against another. It is blind to the approach, which `entryToEnd` scores.
    public struct BelowTheLine: Hashable, Sendable {
        /// First tick below to last tick below, both counted. Seconds; 0 if she never was.
        public var seconds: Double
        /// The part of `seconds` before the leg's end.
        public var secondsOnLeg: Double
        /// The most she was below the line's level. Metres; 0 if she never was.
        public var deepest: Double
        /// She was below it on the exit's last tick (or her last one racing, if that came sooner): `seconds` is capped
        /// there.
        public var stillBelow: Bool

        public init(seconds: Double, secondsOnLeg: Double? = nil, deepest: Double, stillBelow: Bool = false) {
            self.seconds = seconds
            self.secondsOnLeg = secondsOnLeg ?? seconds
            self.deepest = deepest
            self.stillBelow = stillBelow
        }
    }

    /// What a boat sailed from her entry to the leg's end at the gate, and the ideal for the same span.
    ///
    /// The ideal is two parts. The approach: the ideal path (the gybing cone) from her entry to the point `gateInset`
    /// inside the better gate mark, the one that path reaches sooner from her entry (the left one of two as soon),
    /// as the approach's extra has it. Then the straight line from that point to the leg's end at that mark, at the
    /// polar's speed for its angle to the wind. The leg's end is where she ended the leg if she rounded the better
    /// mark (the nearer one to where she ended it); if she rounded the other one, the same point mirrored across the
    /// gate onto the better mark, so the worse mark's longer way is hers. The wind is her entry's for both parts.
    ///
    /// The ideal turns on the spot at the point inside the mark, so a rounding sailed as well as a boat can is a few
    /// metres and seconds over 0.
    public struct EntryToEnd: Hashable, Sendable {
        /// Her path, entry to the leg's end, and the time it took her. Metres, seconds.
        public var metres: Double
        public var seconds: Double
        public var idealMetres: Double
        public var idealSeconds: Double

        public var extraMetres: Double { metres - idealMetres }
        public var extraSeconds: Double { seconds - idealSeconds }

        public init(metres: Double, seconds: Double, idealMetres: Double, idealSeconds: Double) {
            self.metres = metres
            self.seconds = seconds
            self.idealMetres = idealMetres
            self.idealSeconds = idealSeconds
        }
    }

    /// Metres over the ideal, the whole rounding.
    public var extraMetres: Double { approachExtra + roundExtra + exitExtra }
    /// She spent `overshootSeconds` or more below the gate's line before she crossed it, penalty turns or none.
    public var overshoots: Bool { overshootTicks >= Self.overshootSeconds * Race.tickRate }

    /// A rounding begins within this of the mark, or of the gate's centre. Metres.
    public static let entryRange = 80.0
    /// The exit: this long after the leg's end. Seconds.
    public static let exitSeconds = 15
    /// A rounding of the windward mark begins more than this below it, down the course's axis. Metres.
    public static let windwardBelow = 5.0
    /// A rounding of the gate begins more than this above its centre. Metres.
    public static let gateAbove = 3.0
    /// The approach's ideal ends this far off a mark, on the side she passes it. Metres.
    public static let targetOffset = 3.0
    /// The approach's ideal ends this far inside a gate mark, along the gate's line. Metres.
    public static let gateInset = 4.0
    /// She is past a mark from this far short of it, along her approach. Metres.
    public static let pastMark = 0.5
    /// She is below the gate's line from this far below it. Metres.
    public static let belowLine = 1.0
    /// This long below the gate's line before crossing it is an overshoot. Seconds.
    public static let overshootSeconds = 3
    /// The table's shares: a rounding this many metres over the ideal, or more.
    public static let wideMetres = [30.0, 50.0]

    public init(mark: RoundingMark, approachExtra: Double, roundExtra: Double, exitExtra: Double, wrongSide: Bool = false,
                overshootTicks: Int = 0, entryToEnd: EntryToEnd? = nil, belowTheLine: BelowTheLine? = nil) {
        self.mark = mark
        self.approachExtra = approachExtra
        self.roundExtra = roundExtra
        self.exitExtra = exitExtra
        self.wrongSide = wrongSide
        self.overshootTicks = overshootTicks
        self.entryToEnd = entryToEnd
        self.belowTheLine = belowTheLine
    }
}

/// A boat on one tick she was racing, as the scorer reads her.
struct RoundingSample {
    var tick: Int
    var position: Vec2
    /// The direction her wind blows from, radians, and its speed for her polar, m/s.
    var windDirection: Double
    var tws: Double
    var leg: Int
    /// `Boat.roundingStage`: 0 until the race counts her past the leg's mark.
    var stage: Int
}

/// Scores one boat's roundings as she sails: `record` each tick she is racing, in order, then `observations`. It
/// keeps no track: a running path length for each part of a rounding, and the samples at its entry, crossing and end.
struct RoundingScorer {
    /// How a leg is sailed, for its ideal path: tacking up the wind, straight, or gybing down it.
    enum Mode { case up, reach, down }

    /// What a leg's mark is to the scorer.
    private enum Shape {
        /// A mark left to port: where it is and the way she comes to it.
        case mark(position: Vec2, approach: Vec2)
        /// The gate: its marks, the unit vector along its line from the left one to the right one, and the line's normal
        /// up the course.
        case gate(left: Vec2, right: Vec2, along: Vec2, normal: Vec2)
    }

    /// One leg to a mark: fixed for the race.
    private struct Leg {
        var mark: RoundingMark
        var centre: Vec2
        var shape: Shape
        /// Where the approach's ideal may end: a mark's one point, the gate's two (the left end first).
        var targets: [Vec2]
        var mode: Mode
        /// The next leg's.
        var exitMode: Mode

        /// The gate's line: a point of it and its normal up the course.
        var line: (origin: Vec2, normal: Vec2)? {
            guard case .gate(let left, _, _, let normal) = shape else { return nil }
            return (left, normal)
        }
    }

    /// A boat's ticks below the gate's line, as they come: `RoundingObservation.BelowTheLine`.
    private struct Below {
        var first: Int?
        var last = 0
        var deepest = 0.0
        /// On the last tick seen.
        var isBelow = false

        mutating func see(_ sample: RoundingSample, line: (origin: Vec2, normal: Vec2)) {
            let depth = -line.normal.dot(sample.position - line.origin)
            isBelow = depth > RoundingObservation.belowLine
            guard isBelow else { return }
            if first == nil { first = sample.tick }
            last = sample.tick
            deepest = max(deepest, depth)
        }

        /// As seen so far, for a leg that ended on tick `done`.
        func observation(done: Int) -> RoundingObservation.BelowTheLine {
            guard let first else { return RoundingObservation.BelowTheLine(seconds: 0, deepest: 0) }
            let rate = Double(Race.tickRate)
            return RoundingObservation.BelowTheLine(seconds: Double(last - first + 1) / rate,
                                                    secondsOnLeg: Double(max(0, min(last + 1, done) - first)) / rate,
                                                    deepest: deepest, stillBelow: isBelow)
        }
    }

    /// The rounding of the leg she is on.
    private struct Open {
        var entry: RoundingSample?
        var cross: RoundingSample?
        /// The race counted her past the mark before she came into range: no rounding to score.
        var void = false
        var approachPath = 0.0
        var approachExtra = 0.0
        var roundPath = 0.0
        var wrongSide = false
        var overshootTicks = 0
        var below = Below()
        /// The approach's ideal, and which of the leg's `targets` it ends at. Set at her crossing.
        var ideal = (metres: 0.0, seconds: 0.0)
        var target = 0
    }

    /// A rounding sailed to its leg's end, its exit still running.
    private struct Exit {
        var observation: RoundingObservation
        var done: RoundingSample
        var mode: Mode
        var path = 0.0
        var ticks = 0
        var last: Vec2
        /// The gate's line and her ticks below it, the exit's with the leg's. Nil at a mark.
        var line: (origin: Vec2, normal: Vec2)?
        var below = Below()
    }

    private let legs: [Leg?]
    private let upwind: Vec2
    private let polar: PolarTable
    private var leg = -1
    private var open: Open?
    private var exits: [Exit] = []
    private var scored: [RoundingObservation] = []
    private var last: Vec2?

    init(course: CourseLayout, polar: PolarTable) {
        self.polar = polar
        upwind = course.upwind
        let windward = course.elements[CourseLayout.windwardIndex].marks[0].position
        func mode(of leg: Int) -> Mode {
            guard leg < course.legs.count, case .round(let index) = course.legs[leg] else { return .down }
            return index == CourseLayout.windwardIndex ? .up : index == CourseLayout.offsetIndex ? .reach : .down
        }
        legs = course.legs.indices.map { leg in
            guard case .round(let index) = course.legs[leg] else { return nil }
            let centre = course.targetPosition(for: course.legs[leg])
            switch course.elements[index] {
            case .mark(let mark, _):
                let isWindward = index == CourseLayout.windwardIndex
                let approach = isWindward ? course.upwind : (mark.position - windward).normalized
                return Leg(mark: isWindward ? .windward : .offset, centre: centre,
                           shape: .mark(position: mark.position, approach: approach),
                           targets: [mark.position + approach.rightPerp * RoundingObservation.targetOffset],
                           mode: mode(of: leg), exitMode: mode(of: leg + 1))
            case .gate(let left, let right):
                let along = (right.position - left.position).normalized
                var normal = along.rightPerp
                if normal.dot(course.upwind) < 0 { normal = -normal }
                return Leg(mark: .gate, centre: centre, shape: .gate(left: left.position, right: right.position, along: along, normal: normal),
                           targets: [left.position + along * RoundingObservation.gateInset,
                                     right.position - along * RoundingObservation.gateInset],
                           mode: .down, exitMode: mode(of: leg + 1))
            }
        }
    }

    /// The ideal path from `p` to `t` on a leg sailed `mode`, in a wind from `wind` (radians) of `tws` m/s: its metres,
    /// and its seconds at the polar's speed. Up and down the wind it is the tacking or gybing cone where `t` lies inside
    /// `p`'s laylines, which is longer than the straight line; the straight line anywhere else.
    static func ideal(from p: Vec2, to t: Vec2, wind: Double, tws: Double, mode: Mode, polar: PolarTable) -> (metres: Double, seconds: Double) {
        let d = t - p
        let straight = d.length
        guard straight > 0.01 else { return (0, 0) }
        let upwind = Vec2.heading(wind)
        let twa = abs(wrapAngle(d.bearing - wind))
        switch mode {
        case .up:
            let up = d.dot(upwind), lateral = abs(d.dot(upwind.rightPerp))
            let best = polar.bestUpwind(tws: tws)
            if up > 0, lateral <= up * tan(best.twa) {
                let metres = up / cos(best.twa)
                return (metres, metres / max(best.speed, 0.1))
            }
            return (straight, straight / max(polar.speed(twa: max(twa, best.twa), tws: tws), 0.1))
        case .down:
            let down = -d.dot(upwind), lateral = abs(d.dot(upwind.rightPerp))
            let best = polar.bestDownwind(tws: tws)
            let half = .pi - best.twa
            if down > 0, lateral <= down * tan(half) {
                let metres = down / cos(half)
                return (metres, metres / max(best.speed, 0.1))
            }
            return (straight, straight / max(polar.speed(twa: min(twa, best.twa), tws: tws), 0.1))
        case .reach:
            return (straight, straight / max(polar.speed(twa: twa, tws: tws), 0.1))
        }
    }

    /// Her next tick racing.
    mutating func record(_ sample: RoundingSample) {
        let step = last.map { (sample.position - $0).length } ?? 0
        last = sample.position
        if !exits.isEmpty {
            for index in exits.indices {
                exits[index].path += step
                exits[index].ticks += 1
                exits[index].last = sample.position
                if let line = exits[index].line { exits[index].below.see(sample, line: line) }
            }
            // Every exit is as long, so the oldest ends first.
            while let first = exits.first, first.ticks >= RoundingObservation.exitSeconds * Race.tickRate {
                scored.append(closed(first))
                exits.removeFirst()
            }
        }
        if sample.leg != leg {
            // Onto a later leg: the rounding she crossed is sailed, and its exit begins here.
            if sample.leg > leg, let rounding = open, let cross = rounding.cross, let from = legs[leg] {
                let chord = (sample.position - cross.position).length
                var seen = RoundingObservation(mark: from.mark, approachExtra: rounding.approachExtra,
                                               roundExtra: rounding.roundPath + step - chord, exitExtra: 0,
                                               wrongSide: rounding.wrongSide, overshootTicks: rounding.overshootTicks)
                seen.entryToEnd = entryToEnd(of: rounding, on: from, done: sample, step: step)
                var exit = Exit(observation: seen, done: sample, mode: from.exitMode, last: sample.position, line: from.line,
                                below: rounding.below)
                if let line = from.line { exit.below.see(sample, line: line) }
                exits.append(exit)
            }
            leg = sample.leg
            open = legs.indices.contains(leg) && legs[leg] != nil ? Open() : nil
        }
        guard var rounding = open, legs.indices.contains(leg), let geometry = legs[leg] else { return }
        defer { open = rounding }
        if let line = geometry.line { rounding.below.see(sample, line: line) }
        guard rounding.cross == nil else {
            rounding.roundPath += step
            return
        }
        guard !rounding.void else { return }
        if rounding.entry != nil { rounding.approachPath += step }
        if sample.stage >= 1 {
            guard let entry = rounding.entry else {
                rounding.void = true
                return
            }
            // The gate's end is the one the ideal reaches sooner from her entry, the left one of two as soon.
            let ideals = geometry.targets.map {
                Self.ideal(from: entry.position, to: $0, wind: entry.windDirection, tws: entry.tws, mode: geometry.mode, polar: polar)
            }
            rounding.target = ideals.indices.dropFirst().reduce(0) { ideals[$1].seconds < ideals[$0].seconds ? $1 : $0 }
            rounding.ideal = ideals[rounding.target]
            rounding.approachExtra = rounding.approachPath - rounding.ideal.metres
            rounding.cross = sample
            return
        }
        if rounding.entry == nil {
            guard (sample.position - geometry.centre).length < RoundingObservation.entryRange else { return }
            let above = (sample.position - geometry.centre).dot(upwind)
            switch geometry.mark {
            case .windward: guard above < -RoundingObservation.windwardBelow else { return }
            case .offset: break
            case .gate: guard above > RoundingObservation.gateAbove else { return }
            }
            rounding.entry = sample
        }
        // From her entry until her crossing: past the mark on its wrong side, below the gate's line.
        switch geometry.shape {
        case .mark(let position, let approach):
            let from = sample.position - position
            if from.dot(approach) >= -RoundingObservation.pastMark, from.dot(approach.rightPerp) < 0 { rounding.wrongSide = true }
        case .gate(let left, _, _, let normal):
            if normal.dot(sample.position - left) < -RoundingObservation.belowLine { rounding.overshootTicks += 1 }
        }
    }

    /// A gate rounding from her entry to `done`, her first tick on the next leg, `step` metres from her last on this
    /// one: `RoundingObservation.EntryToEnd`. Nil at a mark.
    private func entryToEnd(of rounding: Open, on leg: Leg, done: RoundingSample, step: Double) -> RoundingObservation.EntryToEnd? {
        guard case .gate(let left, let right, let along, _) = leg.shape, let entry = rounding.entry else { return nil }
        let marks = [left, right]
        // She rounded the mark on her side of the gate's middle. The leg's end at the better mark is hers there,
        // or hers mirrored across the gate.
        let rounded = (done.position - (left + right) / 2).dot(along) < 0 ? 0 : 1
        var end = done.position - marks[rounded]
        if rounded != rounding.target { end = end - along * (2 * end.dot(along)) }
        let turn = Self.ideal(from: leg.targets[rounding.target], to: marks[rounding.target] + end, wind: entry.windDirection,
                              tws: entry.tws, mode: .reach, polar: polar)
        return RoundingObservation.EntryToEnd(metres: rounding.approachPath + rounding.roundPath + step,
                                              seconds: Double(done.tick - entry.tick) / Double(Race.tickRate),
                                              idealMetres: rounding.ideal.metres + turn.metres,
                                              idealSeconds: rounding.ideal.seconds + turn.seconds)
    }

    private func closed(_ exit: Exit) -> RoundingObservation {
        var seen = exit.observation
        let ideal = Self.ideal(from: exit.done.position, to: exit.last, wind: exit.done.windDirection, tws: exit.done.tws,
                               mode: exit.mode, polar: polar)
        seen.exitExtra = exit.path - ideal.metres
        if exit.line != nil { seen.belowTheLine = exit.below.observation(done: exit.done.tick) }
        return seen
    }

    /// The roundings she sailed to their leg's end, in order; an exit still running counts what it has seen.
    func observations() -> [RoundingObservation] {
        scored + exits.map(closed)
    }
}
