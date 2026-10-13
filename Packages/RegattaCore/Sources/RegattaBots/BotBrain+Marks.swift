import RegattaCore

// The windward mark's final approach (#508, from #385's prototype as measured in #464, variant F). Inside
// `tacticalRange` the beat tacks her only on a layline of her waypoint or its corridor's edge, and that waypoint is
// right of the mark: nothing tacked a starboard boat away that could no longer lay the mark itself (by hand she foots
// 3 to 10° under her groove, so that is common), and `avoidMarks` took her past it on the wrong side, 128 m a time.
// Here she sails the last 60 m by her own close-hauled board instead: does it clear the mark, or not.
//
// #464's sweep (80 races, 8 bots, about 1260 windward roundings): the median windward rounding's loss 4.4 m to 0.5 m,
// wrong-side passes 48 to 5, mark touches 49 to 23, calls as offender flat (57 to 55). The cautious bot sails it too:
// her suite's fouls over 32 fleets were 2 without it and 1 with it.

extension BotBrain {
    /// Metres from the windward mark inside which she sails its final approach by her close-hauled board alone, not
    /// the corridor: `tacticalRange`, where the beat stops tacking her but on a layline (#464 F).
    static let finalApproachRange = 60.0
    /// Metres from the windward mark inside which she no longer tacks for it: too close to turn by, a hand tack begun
    /// there ends on the mark (#464 F).
    static let finalTackRange = 14.0
    /// Metres more than the mark's room by which a starboard board must pass it for her to come onto it from port:
    /// what she foots under her groove out of a hand tack (#464 F).
    static let layBoardMargin = 1.5
    /// Metres under the mark's room a starboard board may sink before she gives it up: a small header leaves it be,
    /// about 1.5° of one at 40 m, rather than tack her away and back (#464 F).
    static let dropBoardMargin = 1.0
    /// Metres past the fetch point by which her starboard board overstands the mark before the final approach hands
    /// her back to the beat's own aim, which bears her away and reaches in (#464 F).
    static let overstandReach = 4.0
    /// Metres right of the windward mark its fetch point lies (`waypoint`): the board that passes the mark by this
    /// much and its margins more is sailing above the fetch point.
    static let windwardFetchOffset = 6.0
    /// Seconds, at her speed, a tack carries her on along the wind before she is sailing the new board: the port
    /// boat's starboard board is reckoned from there, not from where she puts the helm down (#464 F).
    static let tackAdvanceSeconds = 1.5

    /// Her aim on the windward mark's final approach, or nil when it isn't hers to sail by: not below the mark between
    /// `finalTackRange` and `finalApproachRange` of it and yet to round it, or on starboard past it or well overstood
    /// (the beat's own aim reaches her in). On starboard she holds while her close-hauled board clears the mark by its
    /// room, `dropBoardMargin` of slack under it, and tacks away to port when it no longer does; on port she tacks
    /// onto starboard once the board from where the tack leaves her clears the mark by `layBoardMargin` more than its
    /// room, and holds port until then. A boat that misjudges her laylines (`laylineOverstand`) misjudges this too.
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

        /// Metres the starboard close-hauled board from `position` leaves the mark to port, or nil with the mark
        /// already abeam or astern of it.
        func clearance(from position: Vec2) -> Double? {
            let toMark = mark.position - position
            return toMark.dot(closeHauled) > 0 ? -toMark.dot(closeHauled.rightPerp) : nil
        }

        /// What `navigate` notes of a boat this close to a mark that is no gate.
        func sailsHerMark() {
            isNearHerMark = true
            isAtHerGate = false
        }

        if b.tack == .starboard {
            guard let passes = clearance(from: b.position) else { return nil }
            guard passes <= wanted + Self.overstandReach + Self.windwardFetchOffset else { return nil }
            sailsHerMark()
            // Her plan follows her board either way: a tack away that was refused and is no longer wanted is dropped.
            let lays = passes >= room - Self.dropBoardMargin + misjudged
            setTack(lays ? .starboard : .port, view)
            return upwindAim(b, view, tack: lays ? .starboard : .port)
        }
        sailsHerMark()
        let exit = b.position + Vec2.heading(wind) * (max(b.speed, 1) * Self.tackAdvanceSeconds)
        let lays = clearance(from: exit).map { $0 >= wanted } ?? false
        setTack(lays ? .starboard : .port, view)
        return upwindAim(b, view, tack: lays ? .starboard : .port)
    }

    // A turn refused near her mark (#509, #464's findings, proposal 4). The plan wants the other tack and `canTap`
    // says not yet (a tap just done, a boat or a mark in the turn's way, no room to gybe, too slow to tack): she sails
    // the plan's angle on her own tack meanwhile. For a groove that is her own groove, the closest she sails to a mark
    // to windward or dead to leeward. For a reach it is the worst course she has: a reach of 70° on the wrong side
    // of the wind opens the mark at about twice her speed, where her own groove would still close it. #464's traces:
    // 143 of the 276 roundings in the tail were refused turns, one planing away from her mark at 6.9 m/s to 61 m.

    /// What she holds on her own tack while a turn onto `aim` is refused, or nil for the plan's angle mirrored onto her
    /// tack as before: racing within `PlaningTable.markRange` of a mark or gate she rounds (`isNearMarkOfHerLeg`),
    /// `aim` a reach on the other tack (no groove), the end of her own tack's range of courses (her upwind groove to
    /// her downwind one) that points nearest the reach's heading: through the wind to her upwind groove, or through
    /// dead downwind to her downwind one. It only chooses what she sails while she waits; who keeps clear, and of
    /// which mark, is decided before it (`evasion`) and after it (`holding`) as for any aim.
    ///
    /// The downwind end is a downwind aim like `navigate`'s near her mark, and sailed as one (`downwindAim`): on the
    /// plane no deeper than keeps her on it (`floorAim`). Slow just round a mark and held on the bare groove she fell
    /// off the plane (#509's bot matrix: 0.23 falls a boat a race within 15 s of a rounding became 0.47).
    func refusedTurnAim(_ aim: Aim, _ b: SeatView.OwnBoat, _ view: SeatView) -> Aim? {
        guard aim.tack != b.tack, aim.groove == nil, isNearMarkOfHerLeg(b, view) else { return nil }
        let up = grooveAngle(.upwind, b, view)
        let down = grooveAngle(.downwind, b, view)
        // The turn from each end of her range to the reach on the other side of the wind.
        let throughTheWind = aim.angle + up
        let throughDeadDownwind = (.pi - aim.angle) + (.pi - down)
        guard throughTheWind > throughDeadDownwind else {
            return Aim(angle: up, tack: b.tack, tolerance: aim.tolerance, ease: aim.ease)
        }
        // What she holds, not her plan: the plan's own notes (`replane`, `planingAimed`) stay the plan's.
        var holding = self
        return holding.downwindAim(b, view, aim: Aim(angle: down, tack: b.tack, tolerance: aim.tolerance, ease: aim.ease),
                                   nearMark: true)
    }
}
