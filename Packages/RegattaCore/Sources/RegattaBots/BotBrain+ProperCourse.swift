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
        let lowest = notice.edgeSailingAngle + properCourseMargin
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
