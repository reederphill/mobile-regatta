import CoreGraphics
import Foundation
import RegattaCore

/// What the race camera frames, one frame, in metres (#113, #322): your boat, the boats near her, the wind at her and
/// the course's marks. Plain values, so a test builds one by hand; `init(_:)` takes a `RenderWorld`'s.
nonisolated struct CameraWorld: Sendable {
    var myPosition: Vec2
    var myVelocity: Vec2
    /// Your boat's compass heading, radians: what boat-up turns to.
    var myHeading: Double
    /// The ground wind at your boat (`Boat.windOverGround`): where upwind is, and how much water 30 s of it is.
    var wind: Wind
    /// Every other boat still on the course: ghosts (finished, DSQ) are left out.
    var others: [Vec2]
    /// The course axis (`CourseLayout.axis`): the compass bearing course-up puts at the top.
    var axis: Double
    /// The start line's pin and committee boat.
    var startLine: [Vec2]
    /// The marks of the leg you're sailing (`CourseLayout.marksOfLeg`).
    var nextMarks: [Vec2]
    /// A mark's zone radius (3 hull lengths): inside it, the next mark stays in view.
    var zoneRadius: Double
    var hullLength: Double
    /// Race clock, seconds: negative before the gun.
    var time: Double
    /// Every mark on the course, the start line's ends included (`CourseLayout.obstacles`).
    var course: [Vec2]
}

extension CameraWorld {
    init(_ world: RenderWorld) {
        let me = world.me
        let course = world.course
        self.init(myPosition: me.position, myVelocity: me.velocity, myHeading: me.heading, wind: me.windOverGround,
                  others: world.boats.enumerated()
                      .filter { $0.offset != world.myBoatIndex && !$0.element.isGhost }
                      .map(\.element.position),
                  axis: course.axis,
                  startLine: [course.startLine.pin.position, course.startLine.committee.position],
                  nextMarks: course.marksOfLeg(course.legSailed(status: me.status, legIndex: me.legIndex)).map(\.position),
                  zoneRadius: course.zoneRadius, hullLength: world.boatClass.hull.length, time: world.time,
                  course: course.obstacles.map(\.position))
    }
}

/// The race camera's maths (#113, #13, #322), with no SpriteKit: where the camera is, how far it zooms and which
/// way is up. `GameScene` advances it once a frame and copies it onto its `SKCameraNode`.
///
/// - Course-up turns the view so the course axis is at the top: the windward mark is up whatever the venue's
///   orientation. Boat-up follows your heading with a lag of `boatUpLagSeconds` (an exact exponential ease the
///   short way round, so tacks and penalty turns don't whip the view), and is course-up until the gun while the
///   pre-start shot frames the line. A change of camera eases the same way.
/// - The centre is rigid on your boat plus the **heading lead**: an ellipse sized as a share of the screen
///   (`leadAlong` of half its height up it, `leadAcross` of half its width across), pointing the way your heading
///   eased over `leadDirectionSeconds` points and shrinking as your heading turns (360s, pre-start spins). Nothing
///   else moves it after the start.
/// - **Shots** set the zoom only (auto zoom, on by default), in order of precedence: pre-start (the line, until
///   `gunHandOverSeconds` after the gun), close quarters, mark rounding (which widens just enough to keep the mark
///   on screen) and open water. A shot holds `shotDwellSeconds` unless a higher one replaces it, and a change eases
///   over `shotTransitionSeconds`. With auto zoom off, the lead stays and the zoom is open water's.
/// - A pinch-zoom is a multiplier on every shot's zoom, kept across races (`DeviceSettings.zoomMultiplier`).
/// - The two north-up modes are the render fixtures' cameras from before #113 (#62): following your boat, and the
///   whole course. Nothing else uses them.
///
/// Render-only: never logged, never on the wire.
nonisolated struct CameraRig: Sendable {
    enum Mode: Equatable, Sendable {
        case courseUp, boatUp
        /// North up, following your boat's velocity lead at the follow zoom (the fixtures' `"camera": "boat"`).
        case northUpFollow
        /// North up, the whole course in view (the fixtures' `"camera": "course"`).
        case northUpCourse
    }

    /// What sets the zoom (#322), in rising precedence.
    enum Shot: Int, Comparable, Sendable {
        case openWater, markRounding, closeQuarters, preStart

        static func < (a: Shot, b: Shot) -> Bool { a.rawValue < b.rawValue }
    }

    var mode: Mode
    var autoZoom: Bool
    let pointsPerMeter: Double
    private(set) var style: CameraStyle

    /// The camera's position, scene points.
    private(set) var center = CGPoint.zero
    /// The compass heading at the top of the screen, radians in [−π, π).
    private(set) var viewHeading = 0.0
    /// The zoom drawn: scene points a world point spans. The north-up course camera's is `1 / courseScale`.
    private(set) var zoom: Double
    /// The north-up course camera's scale, which frames the course rather than zooming.
    private var courseScale: CGFloat?
    /// The north-up follow camera's zoom: `defaultZoom` until a pinch-zoom.
    private var followZoom: Double
    /// The zoom limits of the last frame, for a pinch-zoom between frames.
    private(set) var zoomLimits: ClosedRange<Double>
    private var hasFramed = false

    // Heading lead.
    /// The lead's direction, a compass heading in radians: your heading, eased.
    private(set) var leadDirection: Double?
    /// Your heading's rate of turn, radians a second, smoothed over `leadUnsteadinessSeconds`.
    private(set) var headingRate = 0.0
    private var lastHeading: Double?
    /// The lead drawn, in shares of half the screen's width (`across`) and height (`along`): the centre's offset
    /// from your boat on screen.
    private(set) var lead = (across: 0.0, along: 0.0)

    // Shots.
    /// The shot after the gun's hand-over (close quarters, mark rounding or open water).
    private var raceShot = Shot.openWater
    /// The race shot's zoom when it last changed, per unit of the pinch multiplier, eased from over the transition.
    private var raceShotFrom: Double
    private var raceShotProgress = 1.0
    private var raceShotDwell = Double.infinity
    /// The race shot's zoom drawn last frame, per unit of the pinch multiplier.
    private var raceShotDrawn: Double
    private(set) var isCloseQuarters = false
    private var closeQuartersTimer = 0.0
    /// The marks being rounded while the mark-rounding shot is on.
    private var roundingMarks: [Vec2]?
    /// Whether a start line end is off screen in the pre-start shot: the seam for #122's edge arrow.
    private(set) var lineEndOffScreen = false
    /// The time of the last frame, for which shot it was.
    private var lastTime = 0.0

    // Pinch-zoom.
    /// The pinch multiplier on every shot's zoom (#322): 1 until a pinch, kept across races by the scene.
    private(set) var zoomMultiplier = 1.0
    /// The multiplier drawn: eases to `zoomMultiplier` after a double tap's reset.
    private var appliedMultiplier = 1.0
    private var multiplierFrom = 1.0
    private var multiplierProgress = 1.0

    init(mode: Mode = .courseUp, autoZoom: Bool = true, style: CameraStyle = .standard,
         pointsPerMeter: Double = 8) {
        self.mode = mode
        self.autoZoom = autoZoom
        self.style = style
        self.pointsPerMeter = pointsPerMeter
        zoom = style.defaultZoom
        followZoom = style.defaultZoom
        raceShotFrom = style.openWaterZoom
        raceShotDrawn = style.openWaterZoom
        zoomLimits = style.minZoom...max(style.minZoom, style.maxZoom)
    }

    /// Whether shots set the zoom: auto zoom is on, in course-up or boat-up.
    var isAutoZooming: Bool {
        autoZoom && (mode == .courseUp || mode == .boatUp)
    }

    /// The shot drawn: pre-start until the hand-over after the gun, then the race's.
    var shot: Shot {
        guard isAutoZooming else { return .openWater }
        return lastTime < style.gunHandOverSeconds ? .preStart : raceShot
    }

    /// The `SKCameraNode`'s scale: world points per scene point.
    var cameraScale: CGFloat { courseScale ?? 1 / CGFloat(zoom) }

    /// The `SKCameraNode`'s `zRotation`. A camera turned anticlockwise by θ shows the world turned clockwise by
    /// θ, so the compass heading `viewHeading` comes to the top at −`viewHeading`.
    var cameraRotation: CGFloat { CGFloat(-viewHeading) }

    /// Screen up and screen right, as world unit vectors.
    var axes: (up: Vec2, right: Vec2) {
        let up = Vec2.heading(viewHeading)
        return (up, up.rightPerp)
    }

    /// Takes a new style (the tuning panel, #232). A new `defaultZoom` replaces the north-up follow camera's
    /// pinch-zoom.
    mutating func setStyle(_ new: CameraStyle) {
        let zoomChanged = new.defaultZoom != style.defaultZoom
        style = new
        guard zoomChanged else { return }
        followZoom = new.defaultZoom
        if mode == .northUpFollow { zoom = followZoom }
    }

    // MARK: - Frame

    /// Moves the camera on by `dt` seconds of race clock towards framing `world` in a scene of `sceneSize`.
    /// The first frame and a `settled` one (a frozen render fixture) go straight to the target, so the camera
    /// never swoops in from the origin.
    mutating func advance(_ world: CameraWorld, sceneSize: CGSize, dt: Double, settled: Bool = false) {
        let snap = settled || !hasFramed
        defer {
            hasFramed = true
            lastTime = world.time
        }

        switch mode {
        case .northUpFollow, .northUpCourse:
            viewHeading = 0
        case .courseUp, .boatUp:
            // Before the gun the pre-start shot frames the line, so boat-up is course-up until it.
            let courseUp = mode == .courseUp || (isAutoZooming && world.time < 0)
            let target = courseUp ? world.axis : world.myHeading
            if snap {
                viewHeading = wrapAngle(target)
            } else {
                let k = 1 - exp(-dt / max(style.boatUpLagSeconds, 1e-3))
                viewHeading = wrapAngle(viewHeading + wrapAngle(target - viewHeading) * k)
            }
        }

        zoomLimits = limits(for: world, sceneSize: sceneSize)

        if mode == .northUpCourse {
            // As the course camera always framed: no easing, never closer than the follow zoom.
            if let framing = Self.courseFraming(world.course, sceneSize: sceneSize, zoom: CGFloat(followZoom),
                                                margin: CGFloat(style.courseMargin), pointsPerMeter: pointsPerMeter) {
                center = framing.center
                courseScale = framing.scale
                zoom = Double(1 / framing.scale)
            }
            return
        }
        courseScale = nil

        if mode == .northUpFollow {
            // The follow camera, as it always was: on your boat's velocity lead.
            if !hasFramed { center = point(world.myPosition) }
            let target = point(world.myPosition + world.myVelocity * style.lookAheadSeconds)
            let k = settled ? 1 : CGFloat(1 - exp(-dt * style.followRate))
            center = CGPoint(x: center.x + (target.x - center.x) * k, y: center.y + (target.y - center.y) * k)
            zoom = followZoom
            return
        }

        advanceLead(world, dt: dt, snap: snap)
        advanceMultiplier(dt: dt, snap: snap)
        if isAutoZooming {
            advanceRaceShot(world, dt: dt, snap: snap)
        } else {
            resetRaceShot()
        }

        // The race's composition: your boat plus the heading lead, at the race shot's zoom.
        let raceZoom = raceShotZoom(world, sceneSize: sceneSize)
        let raced = (center: leadCentre(world, sceneSize: sceneSize, zoom: raceZoom), zoom: raceZoom)
        let handOver = max(style.gunHandOverSeconds, 1e-3)
        guard isAutoZooming, world.time < handOver else {
            center = point(raced.center)
            zoom = raced.zoom
            lineEndOffScreen = false
            return
        }
        // The pre-start shot, handing over to the race's over `gunHandOverSeconds` after the gun.
        let pre = preStartComposition(world, sceneSize: sceneSize)
        let w = world.time < 0 ? 1 : 1 - Self.smoothstep(world.time / handOver)
        zoom = pre.zoom * w + raced.zoom * (1 - w)
        center = point(pre.center * w + raced.center * (1 - w))
        lineEndOffScreen = world.startLine.contains { !Self.isOnScreen(project($0, sceneSize: sceneSize), sceneSize) }
    }

    // MARK: Heading lead

    /// Eases the lead's direction towards your heading and measures how unsteady the heading is.
    private mutating func advanceLead(_ world: CameraWorld, dt: Double, snap: Bool) {
        let heading = world.myHeading
        if snap || leadDirection == nil {
            leadDirection = wrapAngle(heading)
            headingRate = 0
        } else if dt > 0, let direction = leadDirection {
            let rate = abs(wrapAngle(heading - (lastHeading ?? heading))) / dt
            headingRate += (rate - headingRate) * (1 - exp(-dt / max(style.leadUnsteadinessSeconds, 1e-3)))
            let k = 1 - exp(-dt / max(style.leadDirectionSeconds, 1e-3))
            leadDirection = wrapAngle(direction + wrapAngle(heading - direction) * k)
        }
        lastHeading = heading
        let gone = max(style.leadGoneTurnRate, 1e-3) * .pi / 180
        let steadiness = max(0, 1 - headingRate / gone)
        let onScreen = (leadDirection ?? heading) - viewHeading
        lead = (across: sin(onScreen) * style.leadAcross * steadiness, along: cos(onScreen) * style.leadAlong * steadiness)
    }

    /// The centre (metres) your boat plus the heading lead puts the view at, at `zoom`.
    private func leadCentre(_ world: CameraWorld, sceneSize: CGSize, zoom: Double) -> Vec2 {
        let (up, right) = axes
        let k = zoom * pointsPerMeter
        return world.myPosition + right * (lead.across * Double(sceneSize.width) / 2 / k)
            + up * (lead.along * Double(sceneSize.height) / 2 / k)
    }

    // MARK: Shots

    /// The race shot's conditions (close quarters' timers, the mark being rounded), and a change of shot when
    /// the dwell or precedence allows.
    private mutating func advanceRaceShot(_ world: CameraWorld, dt: Double, snap: Bool) {
        // Close quarters: on after a boat is within `closeQuartersOnHullLengths` for `closeQuartersOnSeconds`, off
        // after none is within `closeQuartersOffHullLengths` for `closeQuartersOffSeconds`.
        let nearest = world.others.map { ($0 - world.myPosition).length }.min() ?? .infinity
        let within = nearest <= style.closeQuartersOnHullLengths * world.hullLength
        let clear = nearest > style.closeQuartersOffHullLengths * world.hullLength
        if snap {
            isCloseQuarters = isCloseQuarters ? !clear : within
            closeQuartersTimer = 0
        } else if isCloseQuarters {
            closeQuartersTimer = clear ? closeQuartersTimer + dt : 0
            if closeQuartersTimer >= style.closeQuartersOffSeconds {
                isCloseQuarters = false
                closeQuartersTimer = 0
            }
        } else {
            closeQuartersTimer = within ? closeQuartersTimer + dt : 0
            if closeQuartersTimer >= style.closeQuartersOnSeconds {
                isCloseQuarters = true
                closeQuartersTimer = 0
            }
        }

        // Mark rounding: on inside `markRoundingZones` zones of the next mark; off once past it (it's no longer
        // next) and out of its zone, or back out past the shot's reach without rounding.
        let reach = style.markRoundingZones * world.zoneRadius
        func distance(_ marks: [Vec2]) -> Double { marks.map { ($0 - world.myPosition).length }.min() ?? .infinity }
        if let marks = roundingMarks {
            let past = marks != world.nextMarks
            let d = distance(marks)
            if (past && d > world.zoneRadius) || (!past && d > reach) { roundingMarks = nil }
        }
        if roundingMarks == nil, distance(world.nextMarks) <= reach { roundingMarks = world.nextMarks }

        let wanted: Shot = isCloseQuarters ? .closeQuarters : roundingMarks != nil ? .markRounding : .openWater
        raceShotDwell += dt
        raceShotProgress = min(1, raceShotProgress + dt / max(style.shotTransitionSeconds, 1e-3))
        if wanted != raceShot, snap || raceShotDwell >= style.shotDwellSeconds || wanted > raceShot {
            raceShotFrom = raceShotDrawn
            raceShot = wanted
            raceShotDwell = 0
            raceShotProgress = snap ? 1 : 0
        }
    }

    /// Auto zoom off: no shots, open water's zoom.
    private mutating func resetRaceShot() {
        raceShot = .openWater
        raceShotFrom = style.openWaterZoom
        raceShotDrawn = style.openWaterZoom
        raceShotProgress = 1
        raceShotDwell = .infinity
        isCloseQuarters = false
        closeQuartersTimer = 0
        roundingMarks = nil
    }

    /// The race shot's zoom this frame, eased from the last shot's, times the pinch multiplier, within the limits.
    /// Mark rounding's widens just enough to keep the mark on screen.
    private mutating func raceShotZoom(_ world: CameraWorld, sceneSize: CGSize) -> Double {
        let multiplier = appliedMultiplier
        var target: Double
        switch raceShot {
        case .openWater, .preStart: target = style.openWaterZoom * multiplier
        case .closeQuarters: target = style.closeQuartersZoom * multiplier
        case .markRounding:
            target = style.markRoundingZoom * multiplier
            if let marks = roundingMarks,
               let mark = marks.min(by: { ($0 - world.myPosition).length < ($1 - world.myPosition).length }) {
                target = min(target, markZoomCap(mark, world: world, sceneSize: sceneSize))
            }
        }
        let e = Self.smoothstep(raceShotProgress)
        let eased = raceShotFrom * multiplier + (target - raceShotFrom * multiplier) * e
        raceShotDrawn = eased / multiplier
        return eased.clamped(to: zoomLimits)
    }

    /// The closest zoom that keeps `mark` inside `edgeMargin` of the screen, with the centre on your boat's lead.
    private func markZoomCap(_ mark: Vec2, world: CameraWorld, sceneSize: CGSize) -> Double {
        let (up, right) = axes
        let d = mark - world.myPosition
        let m = style.edgeMargin
        // The mark's offset from the centre in half-screens is a·zoom − lead on each axis: keep it within ±m.
        func cap(_ metres: Double, half: Double, lead: Double) -> Double {
            let a = metres * pointsPerMeter / half
            if a > 1e-12 { return (m + lead) / a }
            if a < -1e-12 { return (m - lead) / -a }
            return .infinity
        }
        return min(cap(d.dot(right), half: Double(sceneSize.width) / 2, lead: lead.across),
                   cap(d.dot(up), half: Double(sceneSize.height) / 2, lead: lead.along))
    }

    /// The pre-start shot (#322): your boat `preStartBoatHeight` up the screen below the line (as far down it above
    /// the line, easing between over `preStartFlipLineLengths` either side), the view centred across on the line's
    /// middle as far as keeps her inside the middle `preStartBoatWidth` of it, zoomed as close as fits both line
    /// ends inside `edgeMargin`, down to the widest limit; times the pinch multiplier.
    func preStartComposition(_ world: CameraWorld, sceneSize: CGSize) -> (center: Vec2, zoom: Double) {
        let me = world.myPosition
        guard world.startLine.count == 2 else {
            let zoom = (style.openWaterZoom * appliedMultiplier).clamped(to: zoomLimits)
            return (leadCentre(world, sceneSize: sceneSize, zoom: zoom), zoom)
        }
        let (up, right) = axes
        let width = Double(sceneSize.width), height = Double(sceneSize.height)
        let ends = world.startLine
        let middle = (ends[0] + ends[1]) / 2
        let lineLength = max((ends[1] - ends[0]).length, 1)
        // Below the line (negative) your boat sits low, above it high: a smooth flip through the line.
        let above = (me - middle).dot(up)
        let flip = tanh(above / max(style.preStartFlipLineLengths * lineLength, 1e-3))
        // Your boat's height on screen from its middle, points.
        let boatY = (0.5 - style.preStartBoatHeight) * flip * height
        let middleAcross = (middle - me).dot(right)

        // The centre's offset across from your boat at zoom `z`, metres.
        func across(_ z: Double) -> Double {
            let half = style.preStartBoatWidth * width / 2 / (z * pointsPerMeter)
            return middleAcross.clamped(to: -half...half)
        }
        func fits(_ z: Double) -> Bool {
            let k = z * pointsPerMeter
            let boatX = -across(z) * k
            return ends.allSatisfy { end in
                let d = end - me
                return abs(boatX + d.dot(right) * k) <= style.edgeMargin * width / 2
                    && abs(boatY + d.dot(up) * k) <= style.edgeMargin * height / 2
            }
        }
        let limits = zoomLimits
        var fit: Double
        if fits(limits.upperBound) {
            fit = limits.upperBound
        } else if !fits(limits.lowerBound) {
            fit = limits.lowerBound
        } else {
            // Fitting only gets easier zooming out: bisect between the limits, in log zoom.
            var lo = log(limits.lowerBound), hi = log(limits.upperBound)
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if fits(exp(mid)) { lo = mid } else { hi = mid }
            }
            fit = exp(lo)
        }
        let zoom = (fit * appliedMultiplier).clamped(to: limits)
        let k = zoom * pointsPerMeter
        return (me + right * across(zoom) + up * (-boatY / k), zoom)
    }

    /// The pinch-zoom limits for `world`: `minZoom`…`maxZoom`, the widest raised to the zoom that just fits the
    /// whole course in this view, so zooming out never shows more than the course.
    func limits(for world: CameraWorld, sceneSize: CGSize) -> ClosedRange<Double> {
        let upper = max(style.maxZoom, 0.01)
        var lower = min(style.minZoom, upper)
        let (up, right) = axes
        let xs = world.course.map { $0.dot(right) }, ys = world.course.map { $0.dot(up) }
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
            let fit = min(Double(sceneSize.width) / ((maxX - minX) * pointsPerMeter),
                          Double(sceneSize.height) / ((maxY - minY) * pointsPerMeter))
            if fit.isFinite { lower = min(max(lower, fit), upper) }
        }
        return lower...upper
    }

    // MARK: - Pinch-zoom

    /// Sets the pinch multiplier, as the scene does from the saved one: at once, no easing.
    mutating func setZoomMultiplier(_ multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0, multiplier != zoomMultiplier else { return }
        zoomMultiplier = multiplier
        appliedMultiplier = multiplier
        multiplierFrom = multiplier
        multiplierProgress = 1
    }

    /// The fingers spread by `scale` since the last call: the zoom changes now, within the limits. In course-up and
    /// boat-up it's the multiplier on every shot that changes.
    mutating func pinchChanged(by scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        switch mode {
        case .northUpFollow, .northUpCourse:
            followZoom = (followZoom * scale).clamped(to: zoomLimits)
            if mode != .northUpCourse { zoom = followZoom }
        case .courseUp, .boatUp:
            let zoomed = (zoom * scale).clamped(to: zoomLimits)
            let applied = zoom > 0 ? zoomed / zoom : 1
            zoom = zoomed
            zoomMultiplier = (appliedMultiplier * applied).clamped(to: 0.1...10)
            appliedMultiplier = zoomMultiplier
            multiplierFrom = zoomMultiplier
            multiplierProgress = 1
        }
    }

    /// A double tap: the multiplier eases back to 1 over a shot transition.
    mutating func resetZoomMultiplier() {
        guard zoomMultiplier != 1 || appliedMultiplier != 1 else { return }
        multiplierFrom = appliedMultiplier
        zoomMultiplier = 1
        multiplierProgress = 0
    }

    private mutating func advanceMultiplier(dt: Double, snap: Bool) {
        multiplierProgress = snap ? 1 : min(1, multiplierProgress + dt / max(style.shotTransitionSeconds, 1e-3))
        appliedMultiplier = multiplierFrom + (zoomMultiplier - multiplierFrom) * Self.smoothstep(multiplierProgress)
        if multiplierProgress >= 1 { multiplierFrom = zoomMultiplier }
    }

    // MARK: - Projection

    /// Where world point `p` (metres) is drawn, in scene points from the visible area's bottom-left corner, y up:
    /// on screen when inside 0…width, 0…height of `sceneSize`. For the HUD's edge arrows (#122) and tests.
    func project(_ p: Vec2, sceneSize: CGSize) -> CGPoint {
        let (up, right) = axes
        let scale = Double(cameraScale)
        let d = p * pointsPerMeter - Vec2(Double(center.x), Double(center.y))
        return CGPoint(x: Double(sceneSize.width) / 2 + d.dot(right) / scale,
                       y: Double(sceneSize.height) / 2 + d.dot(up) / scale)
    }

    // MARK: - Course framing

    /// The north-up course camera over `points` (metres) in a scene of `sceneSize`: centred on them, scaled to show
    /// all of them with a margin, and never closer than `zoom`.
    static func courseFraming(_ points: [Vec2], sceneSize: CGSize, zoom: CGFloat, margin: CGFloat,
                              pointsPerMeter: Double) -> (center: CGPoint, scale: CGFloat)? {
        let ppm = CGFloat(pointsPerMeter)
        let xs = points.map { CGFloat($0.x) * ppm }, ys = points.map { CGFloat($0.y) * ppm }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              sceneSize.width > 0, sceneSize.height > 0 else { return nil }
        return (CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                max((maxX - minX) / sceneSize.width, (maxY - minY) / sceneSize.height, 1 / zoom) * margin)
    }

    private func point(_ v: Vec2) -> CGPoint {
        let ppm = CGFloat(pointsPerMeter)
        return CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm)
    }

    /// 0 to 1 with a gentle start and end: the shots' and the hand-over's ease.
    static func smoothstep(_ t: Double) -> Double {
        let x = t.clamped(to: 0...1)
        return x * x * (3 - 2 * x)
    }

    static func isOnScreen(_ p: CGPoint, _ sceneSize: CGSize) -> Bool {
        p.x >= 0 && p.x <= sceneSize.width && p.y >= 0 && p.y <= sceneSize.height
    }
}
