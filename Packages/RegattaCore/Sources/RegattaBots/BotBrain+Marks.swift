import RegattaCore

// PROBE (#464): the #385 prototype's windward final approach and gate aims, behind `BotVariant` F and G. Never merged.

extension BotBrain {
    /// Metres from the windward mark inside which she sails its final approach by the layline alone, not the corridor.
    static let finalApproachRange = 60.0
    /// Metres from the windward mark inside which she no longer tacks for it: too close to turn by.
    static let finalTackRange = 14.0
    /// Metres more than the mark's clearance by which a starboard board must pass it for her to come onto it.
    static let layBoardMargin = 1.5
    /// Metres under that clearance a starboard board may sink before she gives it up: a small header leaves it be.
    static let dropBoardMargin = 1.0
    /// Metres past the fetch point's offset by which she overstands the mark before she bears away and reaches in.
    static let overstandReach = 4.0

    /// Her aim on the windward mark's final approach, or nil when it isn't hers to steer (#385 prototype).
    mutating func windwardFinalAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim? {
        let course = view.course
        guard b.status == .racing, course.legs.indices.contains(b.legIndex),
              course.legs[b.legIndex] == .round(CourseLayout.windwardIndex), b.roundingStage == 0 else { return nil }
        let mark = course.elements[CourseLayout.windwardIndex].marks[0]
        let distance = (mark.position - b.position).length
        guard distance < Self.finalApproachRange, distance > Self.finalTackRange else { return nil }
        // Only below the mark: above it the beat's own recovery applies.
        guard (b.position - mark.position).dot(course.upwind) < 0 else { return nil }

        let wind = b.windDirection
        let closeHauled = Vec2.heading(wind - grooveAngle(.upwind, b, view))
        let room = mark.radius + view.boatClass.hull.beam + Self.markClearance + Self.layMargin
        let misjudged = (laylineOverstand(b) - Self.overstand) * distance
        let wanted = room + Self.layBoardMargin + misjudged

        func clearance(from position: Vec2) -> Double? {
            let toMark = mark.position - position
            return toMark.dot(closeHauled) > 0 ? -toMark.dot(closeHauled.rightPerp) : nil
        }

        isNearHerMark = true
        probe.waypoint = "W-final"
        if b.tack == .starboard {
            guard let passes = clearance(from: b.position) else { return nil }
            if passes >= room - Self.dropBoardMargin + misjudged {
                probe.branch = passes > wanted + Self.overstandReach + 6 ? "final-reach" : "final-hold-S"
                return passes > wanted + Self.overstandReach + 6 ? nil : upwindAim(b, view, tack: .starboard)
            }
            probe.branch = "final-tack-away"
            setTack(.port, view)
            return upwindAim(b, view, tack: .port)
        }
        let exit = b.position + Vec2.heading(wind) * (max(b.speed, 1) * Self.tackAdvanceSeconds)
        if let passes = clearance(from: exit), passes >= wanted {
            probe.branch = "final-tack-on"
            setTack(.starboard, view)
            return upwindAim(b, view, tack: .starboard)
        }
        probe.branch = "final-hold-P"
        setTack(.port, view)
        return upwindAim(b, view, tack: .port)
    }

    // MARK: - The leeward gate (#385 prototype, VARIANT G)

    static func gateInset(of mark: CourseLayout.Mark, _ view: SeatView) -> Double {
        mark.radius + view.boatClass.hull.beam + Self.markClearance + 2.5
    }

    static let gateCrossingDepth = 3.0

    func gateCrossing(_ left: CourseLayout.Mark, _ right: CourseLayout.Mark, _ b: SeatView.OwnBoat, _ view: SeatView) -> Vec2 {
        let line = right.position - left.position
        let width = line.length
        let inset = Self.gateInset(of: left, view)
        let heading = Aim.groove(.downwind, tack: b.tack, angle: grooveAngle(.downwind, b, view)).heading(wind: b.windDirection)
        let course = Vec2.heading(heading)
        let across = course.cross(line)
        let landing: Double
        if abs(across) > 1e-6, (left.position - b.position).cross(line) / across > 0 {
            landing = (left.position - b.position).cross(course) / across
        } else {
            landing = 0.5
        }
        let end = (inset / width).clamped(to: 0...0.5)
        let along = landing.clamped(to: end...(1 - end))
        return left.position + line * along - view.course.upwind * Self.gateCrossingDepth
    }

    static let gateGybeMetres = 22.0

    static func roundsLeftGateMark(_ left: CourseLayout.Mark, _ right: CourseLayout.Mark, from b: SeatView.OwnBoat) -> Bool {
        let toLeft = (left.position - b.position).length + (b.tack == .port ? 0 : gateGybeMetres)
        let toRight = (right.position - b.position).length + (b.tack == .starboard ? 0 : gateGybeMetres)
        return toLeft <= toRight
    }

    static func gateRounding(_ mark: CourseLayout.Mark, other: CourseLayout.Mark, upwind: Vec2, from position: Vec2) -> Vec2 {
        let outward = (mark.position - other.position).normalized
        let below = (mark.position - position).dot(upwind)
        return below < gateRoundingDepth ? mark.position - upwind * 8 - outward * 2 : mark.position - upwind * 2 + outward * 7
    }

    static let gateRoundingDepth = 6.0
}
