import CoreGraphics
import Foundation
import RegattaCore

// Boat-side cues (#122, #15, #219): the wind vane with its groove tick and arc, the laylines, the ladder lines and
// the next-mark edge arrow. The maths only, with no SpriteKit: `GameScene` draws them in its cue layer and on its
// camera. Presentation only: nothing here reaches the race (ADR 0002).

/// Your wind vane (#15) and its groove tick (#219), as angles off your bow: radians, positive to starboard.
///
/// - The vane points to the wind over the ground (`Boat.windOverGround`), so it turns with her and with a shift.
/// - The tick is the groove on her boom's side: the autohelm's (`Autohelm.Reading.grooveAngle`), or while you hand
///   steer the groove of the wind she's in (upwind forward of the beam, downwind abaft it), to steer to.
/// - While the autohelm holds the groove and she sails within `BoatStyle.vaneLockDegrees` of it, the vane locks
///   to the tick.
/// - While it holds an angle off the groove (a pinch or a foot) by more than `grooveCueDeadbandDegrees`, a short
///   arc runs from the tick to the angle it holds.
nonisolated struct VaneCue: Equatable, Sendable {
    /// Where the vane points.
    var vane: Double
    /// Where the groove tick is.
    var tick: Double
    /// Whether the vane is locked to the tick (drawn at it).
    var isLocked: Bool
    /// Where the pinch or foot arc ends, from the tick; nil for none.
    var arcEnd: Double?

    /// `boat`'s vane in `boatClass`, with her autohelm's `reading` (nil while the rudder is held), or nil for none:
    /// a ghost has none, and nor has a boat with no wind yet (online before the key).
    init?(_ boat: Boat, reading: Autohelm.Reading?, isGhost: Bool, boatClass: BoatClass, style: BoatStyle = .standard) {
        guard !isGhost, boat.windOverGround.speed > 0 else { return nil }
        // Sailing angles are read against the boom: +1 with the boom to port, where the wind is over starboard.
        let side: Double = boat.boomSide == .port ? 1 : -1
        let grooveAngle: Double
        if let reading {
            grooveAngle = reading.grooveAngle
        } else {
            let groove: Autohelm.Groove = abs(boat.sailingAngle) < .pi / 2 ? .upwind : .downwind
            grooveAngle = Autohelm.grooveAngle(groove, tws: boat.grooveWindSpeed(in: boatClass), boatClass: boatClass)
        }
        tick = wrapAngle(side * grooveAngle)

        let holding = reading.map { !$0.isTapping } ?? false
        let onGroove = holding && reading?.target.groove != nil
            && abs(wrapAngle(boat.sailingAngle - grooveAngle)) <= deg2rad(style.vaneLockDegrees)
        isLocked = onGroove
        vane = onGroove ? tick : wrapAngle(boat.windOverGround.direction - boat.heading)

        if let reading, holding, reading.target.angle != nil,
           abs(reading.offsetFromGroove) > deg2rad(style.grooveCueDeadbandDegrees) {
            arcEnd = wrapAngle(side * (grooveAngle + reading.offsetFromGroove))
        } else {
            arcEnd = nil
        }
    }
}

/// The laylines drawn to the mark you're sailing for (#14, #15): `Laylines`, the formula a bot reads them by, at
/// the polar's best angle in the wind at the mark, never adjusted for current (#11).
nonisolated enum LaylineCue {
    /// How far back from the mark each is drawn, metres.
    static let length = 350.0

    /// The laylines to `leg`'s mark in `course`: segments from the mark back along the tracks that arrive at it,
    /// starboard's then port's. Downwind at a best angle of 180° they coincide, and one is drawn. Empty for a leg
    /// with none (the reach, the finish) or where `wind` gives none (no key yet).
    static func segments(for leg: CourseLayout.Leg, in course: CourseLayout, polar: PolarTable,
                         wind: (Vec2) -> GroundWind?) -> [(from: Vec2, to: Vec2)] {
        guard let lines = Laylines(for: leg, in: course, polar: polar, wind: wind) else { return [] }
        var headings = [lines.starboardHeading]
        if abs(wrapAngle(lines.portHeading - lines.starboardHeading)) > 1e-6 { headings.append(lines.portHeading) }
        // The layline is the track that arrives at the mark on this heading.
        return headings.map { (from: lines.mark, to: lines.mark - Vec2.heading($0) * length) }
    }
}

/// The ladder lines (CONTEXT.md, "Ladder line"): lines across the course axis, the seeded mean wind fixed for the
/// race, `spacing` apart from the windward mark, so boats on one line are level to windward or leeward. Never the
/// live wind, which would show the start line's bias (#122: no line-bias cue). On a reach they run across the leg
/// instead, as its ladder distance does (#267).
nonisolated enum LadderCue {
    /// The most lines drawn, whatever the zoom.
    static let maxLines = 80

    /// The direction the lines step along for `leg` in `course`, and the point they're spaced from: up the axis
    /// from the windward mark, or on a reach (a leg that runs further across the axis than along it, as `Race`'s
    /// ladder reads it) down the leg from its mark.
    static func step(for leg: CourseLayout.Leg, in course: CourseLayout) -> (along: Vec2, anchor: Vec2) {
        let windward = course.targetPosition(for: .round(CourseLayout.windwardIndex))
        guard case .round = leg, let k = course.legs.firstIndex(of: leg) else { return (course.upwind, windward) }
        let from = k == 0 ? course.startLine.centre : course.targetPosition(for: course.legs[k - 1])
        let to = course.targetPosition(for: leg)
        let run = to - from
        let up = course.upwind
        guard abs(run.dot(up.rightPerp)) > abs(run.dot(up)) else { return (up, windward) }
        return (run.normalized, to)
    }

    /// The ladder lines within `radius` metres of `centre` for `leg`, `spacing` metres apart.
    static func segments(for leg: CourseLayout.Leg, in course: CourseLayout, centre: Vec2, radius: Double,
                         spacing: Double) -> [(from: Vec2, to: Vec2)] {
        guard spacing > 0, radius > 0 else { return [] }
        let (along, anchor) = step(for: leg, in: course)
        let across = along.rightPerp
        let s0 = (centre - anchor).dot(along)
        let first = Int(((s0 - radius) / spacing).rounded(.up)), last = Int(((s0 + radius) / spacing).rounded(.down))
        guard first <= last else { return [] }
        let mid = (first + last) / 2
        let lo = max(first, mid - maxLines / 2), hi = min(last, lo + maxLines - 1)
        return (lo...hi).map { k in
            let p = anchor + along * (Double(k) * spacing)
            let d = (p - centre).dot(along)
            let half = max(radius * radius - d * d, 0).squareRoot()
            let foot = p + across * (centre - p).dot(across)
            return (from: foot - across * half, to: foot + across * half)
        }
    }
}

/// The orange next-mark edge arrow (#15): pinned to the edge of the race view, pointing at the mark, shown only
/// while the mark is off screen; no distance. It turns with the view, since it reads the camera's projection.
nonisolated enum EdgeArrow {
    /// Where it's drawn: scene points from the visible area's bottom-left corner, and the way it points, radians
    /// counter-clockwise from the screen's right (SpriteKit's `zRotation`).
    struct Placement: Equatable, Sendable {
        var position: CGPoint
        var angle: CGFloat
    }

    /// The part of a scene of `sceneSize` a mark must be inside to count as on screen: inset by `style`'s edge
    /// arrow insets, clear of the HUD and controls.
    static func visibleRect(sceneSize: CGSize, style: BoatStyle) -> CGRect {
        let side = CGFloat(style.edgeArrowInsetSide), top = CGFloat(style.edgeArrowInsetTop)
        let bottom = CGFloat(style.edgeArrowInsetBottom)
        return CGRect(x: side, y: bottom, width: max(sceneSize.width - 2 * side, 1),
                      height: max(sceneSize.height - top - bottom, 1))
    }

    /// The arrow for a mark drawn at `projected` (`CameraRig.project`): nil while it's inside `visible`, else on
    /// `visible`'s edge where the ray from its centre to the mark leaves it, pointing along that ray.
    static func placement(projected p: CGPoint, visible: CGRect) -> Placement? {
        guard !visible.contains(p) else { return nil }
        let c = CGPoint(x: visible.midX, y: visible.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let tx = dx == 0 ? CGFloat.infinity : (visible.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (visible.height / 2) / abs(dy)
        let t = min(tx, ty)
        return Placement(position: CGPoint(x: c.x + dx * t, y: c.y + dy * t), angle: atan2(dy, dx))
    }

    /// What the arrow points at for your boat with `status` on leg `legIndex` in `course`: the start line's centre
    /// before you've started (prestart, OCS), the leg's mark while racing (a gate's or the finish line's centre,
    /// `CourseLayout.targetPosition`), and nothing once you've stopped. In the pre-start shot with a line end off
    /// screen (`CameraRig.lineEndOffScreen`), both ends, so the arrow can point at the one that's off.
    static func targets(status: BoatStatus, legIndex: Int, course: CourseLayout, lineEndOffScreen: Bool) -> [Vec2] {
        switch status {
        case .prestart, .ocs:
            let line = course.startLine
            return lineEndOffScreen ? [line.pin.position, line.committee.position] : [line.centre]
        case .racing:
            guard course.legs.indices.contains(legIndex) else { return [] }
            return [course.targetPosition(for: course.legs[legIndex])]
        case .finished, .dsq:
            return []
        }
    }

    /// The arrow for `targets`, each drawn where `project` puts it: one target's placement, or of two (a line's
    /// ends), the one that's off screen, or the line's middle when both are.
    static func placement(targets: [Vec2], project: (Vec2) -> CGPoint, visible: CGRect) -> Placement? {
        let placed = targets.compactMap { placement(projected: project($0), visible: visible) }
        guard targets.count == 2, placed.count == 2 else { return placed.first }
        return placement(projected: project((targets[0] + targets[1]) / 2), visible: visible) ?? placed.first
    }
}
