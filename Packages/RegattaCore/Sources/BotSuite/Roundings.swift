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
    /// PROTOTYPE (#510): entry to the leg's end, her seconds and metres; the ideal approach's seconds and metres (to her
    /// point inside the gate's sooner end, or off the mark); the metres up the course she made in the exit's seconds.
    public var legSeconds = 0.0
    public var legMetres = 0.0
    public var idealSeconds = 0.0
    public var idealMetres = 0.0
    public var exitUpwind = 0.0
    /// Metres up the course from the mark's (the gate's centre's) height at the leg's end.
    public var doneAbove = 0.0

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
                overshootTicks: Int = 0) {
        self.mark = mark
        self.approachExtra = approachExtra
        self.roundExtra = roundExtra
        self.exitExtra = exitExtra
        self.wrongSide = wrongSide
        self.overshootTicks = overshootTicks
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
        /// The gate: its left mark, the unit vector along its line to the right one, and the line's normal up the course.
        case gate(left: Vec2, along: Vec2, normal: Vec2)
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
        var idealSeconds = 0.0
        var idealMetres = 0.0
    }

    /// A rounding sailed to its leg's end, its exit still running.
    private struct Exit {
        var observation: RoundingObservation
        var done: RoundingSample
        var mode: Mode
        var path = 0.0
        var ticks = 0
        var last: Vec2
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
                return Leg(mark: .gate, centre: centre, shape: .gate(left: left.position, along: along, normal: normal),
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
                if let entry = rounding.entry {
                    seen.legSeconds = Double(sample.tick - entry.tick) / Double(Race.tickRate)
                    seen.legMetres = rounding.approachPath + rounding.roundPath + step
                    seen.idealSeconds = rounding.idealSeconds
                    seen.idealMetres = rounding.idealMetres
                    seen.doneAbove = (sample.position - from.centre).dot(upwind)
                }
                exits.append(Exit(observation: seen, done: sample, mode: from.exitMode, last: sample.position))
            }
            leg = sample.leg
            open = legs.indices.contains(leg) && legs[leg] != nil ? Open() : nil
        }
        guard var rounding = open, legs.indices.contains(leg), let geometry = legs[leg] else { return }
        defer { open = rounding }
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
            let ideal = ideals.dropFirst().reduce(ideals[0]) { $1.seconds < $0.seconds ? $1 : $0 }
            rounding.approachExtra = rounding.approachPath - ideal.metres
            rounding.idealSeconds = ideal.seconds
            rounding.idealMetres = ideal.metres
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
        case .gate(let left, _, let normal):
            if normal.dot(sample.position - left) < -RoundingObservation.belowLine { rounding.overshootTicks += 1 }
        }
    }

    private func closed(_ exit: Exit) -> RoundingObservation {
        var seen = exit.observation
        let ideal = Self.ideal(from: exit.done.position, to: exit.last, wind: exit.done.windDirection, tws: exit.done.tws,
                               mode: exit.mode, polar: polar)
        seen.exitExtra = exit.path - ideal.metres
        seen.exitUpwind = (exit.last - exit.done.position).dot(upwind)
        return seen
    }

    /// The roundings she sailed to their leg's end, in order; an exit still running counts what it has seen.
    func observations() -> [RoundingObservation] {
        scored + exits.map(closed)
    }
}
