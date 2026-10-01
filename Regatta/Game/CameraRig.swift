import CoreGraphics
import Foundation
import RegattaCore

/// What the race camera frames, one frame, in metres (#113): your boat, the boats near her, the wind at her and
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

/// The race camera's maths (#113, #13, #224), with no SpriteKit: where the camera is, how far it zooms and which
/// way is up. `GameScene` advances it once a frame and copies it onto its `SKCameraNode`.
///
/// - Course-up turns the view so the course axis is at the top: the windward mark is up whatever the venue's
///   orientation. Boat-up follows your heading with a lag of `boatUpLagSeconds` (an exact exponential ease the
///   short way round, so tacks and penalty turns don't whip the view). A change of camera eases the same way.
/// - Auto framing (on by default) frames your boat, every boat within `framingHullLengths`, `framingUpwindSeconds`
///   of water upwind of you, the start line until `lineFramingSecondsAfterGun` after the gun, and the next mark
///   inside its zone; eased, within the pinch-zoom limits. A pinch-zoom holds `pinchHoldSeconds` after the
///   fingers lift, then eases back. With auto framing off, the camera follows your boat's velocity lead at
///   `defaultZoom`, and a pinch-zoom stays.
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

    var mode: Mode
    var autoFraming: Bool
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
    /// The follow camera's zoom (auto framing off, north-up): `defaultZoom` until a pinch-zoom.
    private var followZoom: Double
    /// Auto framing's pinch-zoom: the zoom while the fingers are down and through the hold after.
    private var pinchedZoom: Double?
    /// Seconds of the pinch-zoom's hold left; nil while the fingers are down or with no pinch-zoom.
    private(set) var pinchHoldLeft: Double?
    /// The zoom limits of the last frame, for a pinch-zoom between frames.
    private(set) var zoomLimits: ClosedRange<Double>
    private var hasFramed = false

    init(mode: Mode = .courseUp, autoFraming: Bool = true, style: CameraStyle = .standard,
         pointsPerMeter: Double = 8) {
        self.mode = mode
        self.autoFraming = autoFraming
        self.style = style
        self.pointsPerMeter = pointsPerMeter
        zoom = style.defaultZoom
        followZoom = style.defaultZoom
        zoomLimits = style.minZoom...max(style.minZoom, style.maxZoom)
    }

    /// Whether auto framing frames the view: it's on, in course-up or boat-up.
    var isAutoFraming: Bool {
        autoFraming && (mode == .courseUp || mode == .boatUp)
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

    /// Takes a new style (the tuning panel, #232). A new `defaultZoom` replaces your pinch-zoom.
    mutating func setStyle(_ new: CameraStyle) {
        let zoomChanged = new.defaultZoom != style.defaultZoom
        style = new
        guard zoomChanged else { return }
        followZoom = new.defaultZoom
        pinchedZoom = nil
        pinchHoldLeft = nil
        if !isAutoFraming && mode != .northUpCourse { zoom = followZoom }
    }

    // MARK: - Frame

    /// Moves the camera on by `dt` seconds of race clock towards framing `world` in a scene of `sceneSize`.
    /// The first frame and a `settled` one (a frozen render fixture) go straight to the target, so the camera
    /// never swoops in from the origin.
    mutating func advance(_ world: CameraWorld, sceneSize: CGSize, dt: Double, settled: Bool = false) {
        let snap = settled || !hasFramed
        defer { hasFramed = true }

        switch mode {
        case .northUpFollow, .northUpCourse:
            viewHeading = 0
        case .courseUp, .boatUp:
            let target = mode == .courseUp ? world.axis : world.myHeading
            if snap {
                viewHeading = wrapAngle(target)
            } else {
                let k = 1 - exp(-dt / max(style.boatUpLagSeconds, 1e-3))
                viewHeading = wrapAngle(viewHeading + wrapAngle(target - viewHeading) * k)
            }
        }

        zoomLimits = limits(for: world, sceneSize: sceneSize)
        if !isAutoFraming {
            pinchedZoom = nil
            pinchHoldLeft = nil
        } else if let left = pinchHoldLeft {
            let rest = left - dt
            if rest <= 0 {
                pinchHoldLeft = nil
                pinchedZoom = nil
            } else {
                pinchHoldLeft = rest
            }
        }

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

        if !isAutoFraming {
            // The follow camera: north-up's as it always was, and course-up's and boat-up's with auto framing off.
            // The lead follows your velocity, not the view, so boat-up doesn't fight it.
            if !hasFramed { center = point(world.myPosition) }
            let target = point(world.myPosition + world.myVelocity * style.lookAheadSeconds)
            let k = settled ? 1 : CGFloat(1 - exp(-dt * style.followRate))
            center = CGPoint(x: center.x + (target.x - center.x) * k, y: center.y + (target.y - center.y) * k)
            zoom = followZoom
            return
        }

        let framing = framingTarget(world, sceneSize: sceneSize)
        let target = point(framing.center)
        if snap {
            center = target
        } else {
            let k = CGFloat(1 - exp(-dt * style.followRate))
            center = CGPoint(x: center.x + (target.x - center.x) * k, y: center.y + (target.y - center.y) * k)
        }
        if let pinchedZoom {
            zoom = pinchedZoom.clamped(to: zoomLimits)
        } else if snap {
            zoom = framing.zoom
        } else {
            zoom += (framing.zoom - zoom) * (1 - exp(-dt * style.framingEaseRate))
        }
    }

    /// Auto framing's target (#224): the centre (metres) and zoom that frame your boat, every boat on the course
    /// within `framingHullLengths` of her, the water `framingUpwindSeconds` upwind of her, the start line until
    /// `lineFramingSecondsAfterGun`, and the next leg's marks once she's inside the zone of one, in the view's
    /// turned axes, within the zoom limits. Where the limits cut the view short, the boats and the mark in its zone
    /// stay in it and the water and the line give way: the centre comes back towards your boat until she's inside
    /// the middle 60 % of the screen and the boats near her are on it.
    func framingTarget(_ world: CameraWorld, sceneSize: CGSize) -> (center: Vec2, zoom: Double) {
        let me = world.myPosition
        let reach = style.framingHullLengths * world.hullLength
        // What must stay in view, and what is framed when there's room.
        var kept = [me]
        kept += world.others.filter { ($0 - me).length <= reach }
        if world.nextMarks.contains(where: { ($0 - me).length <= world.zoneRadius }) { kept += world.nextMarks }
        var framed = kept
        if world.wind.speed > 0 {
            framed.append(me + Vec2.heading(world.wind.direction) * (style.framingUpwindSeconds * world.wind.speed))
        }
        if world.time < style.lineFramingSecondsAfterGun { framed += world.startLine }

        // Boxes in the view's turned axes, from your boat, with a hull length of water round everything, so a boat
        // at the edge is a whole boat.
        let (up, right) = axes
        let pad = world.hullLength
        func box(_ points: [Vec2]) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
            let xs = points.map { ($0 - me).dot(right) }, ys = points.map { ($0 - me).dot(up) }
            return ((xs.min() ?? 0) - pad...(xs.max() ?? 0) + pad, (ys.min() ?? 0) - pad...(ys.max() ?? 0) + pad)
        }
        let all = box(framed), must = box(kept)
        let margin = max(style.framingMargin, 1)
        let width = Double(sceneSize.width), height = Double(sceneSize.height)
        let fit = min(width / ((all.x.upperBound - all.x.lowerBound) * pointsPerMeter * margin),
                      height / ((all.y.upperBound - all.y.lowerBound) * pointsPerMeter * margin))
        let zoom = (fit.isFinite ? fit : style.defaultZoom).clamped(to: limits(for: world, sceneSize: sceneSize))

        // The centre: the framed box's, within reach of your boat (the middle 60 %) and of what must stay in view.
        let halfWidth = width / 2 / (zoom * pointsPerMeter), halfHeight = height / 2 / (zoom * pointsPerMeter)
        func centre(_ all: ClosedRange<Double>, _ must: ClosedRange<Double>, half: Double) -> Double {
            let mine = -0.6 * half...0.6 * half
            let wanted = (all.lowerBound + all.upperBound) / 2
            let lower = max(mine.lowerBound, must.upperBound - half), upper = min(mine.upperBound, must.lowerBound + half)
            // If both can't hold (the kept boats wider than the view), your boat's reach wins.
            return lower <= upper ? wanted.clamped(to: lower...upper) : wanted.clamped(to: mine)
        }
        let cx = centre(all.x, must.x, half: halfWidth), cy = centre(all.y, must.y, half: halfHeight)
        return (me + right * cx + up * cy, zoom)
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

    /// The fingers spread by `scale` since the last call: the zoom changes now, within the limits.
    mutating func pinchChanged(by scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        if isAutoFraming {
            let zoomed = ((pinchedZoom ?? zoom) * scale).clamped(to: zoomLimits)
            pinchedZoom = zoomed
            pinchHoldLeft = nil
            zoom = zoomed
        } else {
            followZoom = (followZoom * scale).clamped(to: zoomLimits)
            if mode != .northUpCourse { zoom = followZoom }
        }
    }

    /// The fingers lifted: auto framing's pinch-zoom holds `pinchHoldSeconds` of race clock, then eases back.
    mutating func pinchEnded() {
        guard isAutoFraming, pinchedZoom != nil else { return }
        pinchHoldLeft = style.pinchHoldSeconds
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
}
