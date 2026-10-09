import RegattaCore

// Rule 17 (#346, #343): a bot that became overlapped to leeward from clear astern within two lengths sails no higher
// than her proper course, by construction, so she never breaches it (rule 17 is not in `BotWeaknesses.misjudgeScope`).
// She learns she is held to it only from her seat's proper-course notice (`OwnBoat.properCourse`): never the umpire's
// records. The notice carries the umpire's own proper course (`ProperCourse`, in the wind at her this tick) and the
// rules file's tolerance, so her limit can't drift from the call.
//
// - While the notice is told her, her aim is held no closer to the wind than the tolerance's edge plus a margin, with
//   the autohelm's slack inside it (`properCourseLimited`): a pinch, a heat-up, a reach aim at a waypoint above the
//   mark, or a header carrying her held angle above the bearing bears away to it. Nothing else of her conduct moves:
//   as the right-of-way boat she still holds her course (#228) and never hunts; the limit only ever bears her away
//   from the windward boat, so it never turns towards one.
// - Before the overlap, on a reach or a run: clear astern of a boat on her tack within `properCourseLookahead`, she
//   already sails no higher than her proper course (`properCourseAnticipated`). The notice comes only on the tick the
//   overlap is made, and a boat that makes it already above her proper course, close enough that the windward boat
//   can't keep clear at once, is called on that tick before she can bear away (#337 round 4: seed 2, mixed 16, seat 7,
//   reaching up from astern 15 degrees above her proper course). Not on a beat, where she sails her groove, the proper
//   course itself, and a pinch below the beat's tolerance.
// - Her aim alone: the evasions that steer after it (`evasion`, the cautious bot's `guarded`) are outside it.
// - A bot-only limit: nothing clamps a player's helm (#343: no helm clamp).
extension BotBrain {
    /// Radians she keeps inside the tolerance's edge while held to her proper course (#346, untuned): she sails just
    /// below the line, not on it.
    static let properCourseMargin = deg2rad(2)
    /// The most the autohelm may let her held angle sit above her limited aim before she steers again, radians: the
    /// default `Aim.tolerance`, so a reach's wider slack can't carry her past the edge.
    static let properCourseSlack = deg2rad(1.5)

    /// `aim`, held within her proper course while her seat is told she is restricted under rule 17
    /// (`OwnBoat.properCourse`): unchanged when she is not, or when the least angle the autohelm may hold her at
    /// (`aim.angle - aim.tolerance`) is already the tolerance's edge plus `properCourseMargin` or further off the
    /// wind. Otherwise the same tack and ease at the edge plus the margin plus her slack (never closer to the wind
    /// than `aim` was), its slack at most `properCourseSlack`, held as an angle rather than a groove when its angle
    /// moves. Whatever `aim.tack`: an aim on the other tack not yet tapped still sails her own at that angle.
    static func properCourseLimited(_ aim: Aim, _ b: SeatView.OwnBoat) -> Aim {
        guard let notice = b.properCourse else { return aim }
        return properCourseLimited(aim, edge: notice.edgeSailingAngle)
    }

    /// Centre to centre, hull lengths: how close behind a boat on her tack she already sails within her proper course
    /// (`properCourseAnticipated`, #337 round 4, untuned): rule 17's two hull lengths between hulls, plus one for the
    /// hulls and one for the closing.
    static let properCourseLookahead = 4.0

    /// `aim` as `properCourseLimited(_:_:)` holds it while she is told she's restricted; before that, on a reach or a
    /// run (`ProperCourse.Kind`), held no higher than her proper course itself (no tolerance: the view doesn't carry
    /// the rules file's) while she is clear astern (rule 12) of a boat within `properCourseLookahead` hull lengths:
    /// she would become restricted if she made the overlap to leeward. Not in a mark's zone.
    static func properCourseAnticipated(_ aim: Aim, _ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        if b.properCourse != nil { return properCourseLimited(aim, b) }
        // In a mark's zone rule 18 has the pair, not rule 17, and she sails her rounding.
        if b.zone?.isIn == true { return aim }
        let reach = properCourseLookahead * view.boatClass.hull.length
        let astern = view.others.contains { o in
            o.rightOfWay == RightOfWay(keepClear: view.seat, rule: .clearAstern)
                && ((o.position - b.position) * (o.position - b.position)).sum() < reach * reach
        }
        guard astern,
              let proper = ProperCourse.of(position: b.position, boomSide: b.boomSide, status: b.status,
                                           legIndex: b.legIndex, windDirection: b.windDirection,
                                           grooveTWS: b.grooveWindSpeed, course: view.course, boatClass: view.boatClass),
              proper.kind != .beat
        else { return aim }
        return properCourseLimited(aim, edge: proper.sailingAngle)
    }

    /// `aim` held no closer to the wind than `edge` (a sailing angle on her tack) plus `properCourseMargin`.
    private static func properCourseLimited(_ aim: Aim, edge: Double) -> Aim {
        let lowest = edge + properCourseMargin
        guard aim.angle - aim.tolerance < lowest else { return aim }
        var limited = aim
        limited.tolerance = min(aim.tolerance, properCourseSlack)
        let angle = min(.pi, max(aim.angle, lowest + limited.tolerance))
        if angle != aim.angle {
            limited.angle = angle
            limited.groove = nil
        }
        return limited
    }
}
