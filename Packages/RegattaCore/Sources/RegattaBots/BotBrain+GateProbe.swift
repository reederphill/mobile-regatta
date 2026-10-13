import Foundation
import RegattaCore

// PROTOTYPE (#510, never merged): the leeward gate redesign's elements, each behind a letter in `REGATTA_BOT_VARIANT`,
// so one binary sails the baseline (no letters) and every variant.
//  P: pick the gate mark she rounds by `pickRange` above the line and sail for its inside; inside `straightRange` of
//     that point she sails straight for it on her own gybe (no gybe).
//  C: no corridor gybe inside `PlaningTable.gateRange` of her point through the gate (REGATTA_GATE_C_RANGE metres).
//  R: below the line and not through it, she sails back above it round the nearer end, latched until 10 m above.
//  X: off the gate, a turn by hand onto the beat goes the shorter way (through the wind, with the speed for it).
public enum BotVariant {
    public static let flags: Set<Character> = Set(ProcessInfo.processInfo.environment["REGATTA_BOT_VARIANT"] ?? "")
    public static func on(_ c: Character) -> Bool { flags.contains(c) }
    static func number(_ name: String, _ fallback: Double) -> Double {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
    }
    /// P: metres above the gate's line from which she has picked her mark.
    static let pickRange = number("REGATTA_GATE_PICK", 40)
    /// P: metres from her point inside the mark within which she sails straight for it, no gybe.
    static let straightRange = number("REGATTA_GATE_STRAIGHT", 30)
    /// P: what a gybe is worth in metres when she picks.
    static let gybeMetres = number("REGATTA_GATE_GYBE_M", 20)
    /// P: metres more than the mark's radius, her beam and the clearance her point lies inside the mark.
    static let inset = number("REGATTA_GATE_INSET", 2.5)
    /// P: metres below the line her point lies.
    static let depth = number("REGATTA_GATE_DEPTH", 2)
    /// C: metres from her point through the gate inside which the corridor gybes her no more.
    static let corridorRange = number("REGATTA_GATE_C_RANGE", PlaningTable.gateRange)
    /// A per-decision trace of the gate leg on stderr.
    static let traces = ProcessInfo.processInfo.environment["REGATTA_GATE_TRACE"] != nil
}

extension BotBrain {
    /// The gate of the leg she is racing, or nil.
    static func gate(of b: SeatView.OwnBoat, _ view: SeatView) -> (left: CourseLayout.Mark, right: CourseLayout.Mark, centre: Vec2)? {
        let c = view.course
        guard b.status == .racing, c.legs.indices.contains(b.legIndex), case .round(let index) = c.legs[b.legIndex],
              case .gate(let left, let right) = c.elements[index] else { return nil }
        return (left, right, c.targetPosition(for: c.legs[b.legIndex]))
    }

    /// P: her point through the gate, inside `mark`.
    static func gateEntry(_ mark: CourseLayout.Mark, centre: Vec2, _ view: SeatView) -> Vec2 {
        let inside = mark.radius + view.boatClass.hull.beam + markClearance + BotVariant.inset
        return mark.position + (centre - mark.position).normalized * inside - view.course.upwind * BotVariant.depth
    }

    /// The prototype's aim on the leg to the gate before she is through it (R, P), or nil for main's.
    mutating func gateProbeAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim? {
        guard let gate = Self.gate(of: b, view), b.roundingStage == 0 else {
            gateRecovering = false
            return nil
        }
        let up = view.course.upwind
        let above = up.dot(b.position - gate.centre)
        if BotVariant.on("R") {
            if above < -1 { gateRecovering = true } else if above > 10 { gateRecovering = false }
            if gateRecovering {
                let near = (gate.left.position - b.position).length <= (gate.right.position - b.position).length ? gate.left : gate.right
                gateNote = "recover"
                return navigate(b, to: near.position + (near.position - gate.centre).normalized * 8 + up * 20, view)
            }
        }
        guard BotVariant.on("P"), above < BotVariant.pickRange, above > -1 else { return nil }
        let w = b.windDirection
        let down = grooveAngle(.downwind, b, view)
        // What sailing to a mark's point costs her from here, metres: the way there, and a gybe if it is on her other one.
        func cost(_ mark: CourseLayout.Mark) -> (cost: Double, entry: Vec2, gybes: Bool, offWind: Double) {
            let entry = Self.gateEntry(mark, centre: gate.centre, view)
            let to = entry - b.position
            let aim = Aim(heading: to.bearing, b, tolerance: 0)
            let gybes = aim.tack != b.tack
            // Deeper than her groove she gybes down to it: the gybing cone's length.
            let deep = Double.pi - aim.angle
            let length = aim.angle > down ? to.length * cos(deep) / cos(.pi - down) : to.length
            return (length + (gybes ? BotVariant.gybeMetres : 0), entry, gybes, aim.angle)
        }
        let l = cost(gate.left), r = cost(gate.right)
        var picksLeft: Bool
        if let pick = gatePick, pick.leg == b.legIndex {
            picksLeft = pick.left
            // Close in, a pick on her other gybe gives way to one she lays on this one.
            let mine = picksLeft ? l : r, other = picksLeft ? r : l
            if mine.gybes, mine.offWind < .pi - deg2rad(10), !other.gybes, other.offWind > .pi / 2,
               (mine.entry - b.position).length < BotVariant.straightRange { picksLeft.toggle() }
        } else {
            picksLeft = l.cost <= r.cost
        }
        gatePick = (b.legIndex, picksLeft)
        let mine = picksLeft ? l : r
        let to = mine.entry - b.position
        gateNote = picksLeft ? "pick-L" : "pick-R"
        guard to.length < BotVariant.straightRange, mine.offWind > down - deg2rad(2),
              !mine.gybes || mine.offWind >= .pi - deg2rad(10) else {
            return navigate(b, to: mine.entry, view)
        }
        // Straight for it on her own gybe, by the lee no further than a few degrees.
        gateNote += "-straight"
        plannedTack = b.tack
        isNearHerMark = true
        isAtHerGate = true
        let angle = mine.gybes ? .pi - deg2rad(3) : min(mine.offWind, .pi - deg2rad(3))
        return downwindAim(b, view, aim: Aim(angle: angle, tack: b.tack, tolerance: Self.reachTolerance), nearMark: true)
    }

    /// C: whether the corridor to `target`, `distance` metres off, gybes her no more: on her way to the gate, close.
    func gateHoldsCorridor(_ b: SeatView.OwnBoat, _ view: SeatView, distance: Double) -> Bool {
        BotVariant.on("C") && distance < BotVariant.corridorRange && b.roundingStage == 0 && Self.gate(of: b, view) != nil
    }

    /// X: whether she is just off the gate: round its mark, or on the beat from it within 100 m of its centre.
    func isOffHerGate(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        let c = view.course
        guard b.status == .racing, c.legs.indices.contains(b.legIndex) else { return false }
        if Self.gate(of: b, view) != nil { return b.roundingStage > 0 }
        guard b.legIndex > 0, case .round(let index) = c.legs[b.legIndex - 1], case .gate = c.elements[index] else { return false }
        return (c.targetPosition(for: c.legs[b.legIndex - 1]) - b.position).length < 100
    }

    /// The trace of a gate leg, a line a decision, on stderr.
    func gateTrace(_ b: SeatView.OwnBoat, _ view: SeatView, _ aim: Aim, _ what: String) {
        guard BotVariant.traces else { return }
        let c = view.course
        let onGate = Self.gate(of: b, view)
        guard onGate != nil || isOffHerGate(b, view) else { return }
        let centre = onGate?.centre ?? c.targetPosition(for: c.legs[b.legIndex - 1])
        let rel = b.position - centre
        let line = String(format: "GT t=%.1f seat=%d leg=%d st=%d above=%.1f right=%.1f v=%.1f twa=%.0f%@ aim=%.0f%@ %@ %@ near=%d atGate=%d turn=%d pen=%d",
                          view.time, view.seat, b.legIndex, b.roundingStage, rel.dot(c.upwind), rel.dot(c.upwind.rightPerp), b.speed,
                          rad2deg(abs(sailingAngle(b))), b.tack == .port ? "P" : "S", rad2deg(aim.angle), aim.tack == .port ? "P" : "S",
                          gateNote, what, isNearHerMark ? 1 : 0, isAtHerGate ? 1 : 0, handTurn != nil ? 1 : 0, b.penalty != nil ? 1 : 0)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}
