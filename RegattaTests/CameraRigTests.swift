import CoreGraphics
import Foundation
import SpriteKit
import SwiftUI
import Testing
import RegattaCore
@testable import Regatta

/// The race camera (#113, #322): course-up puts the windward mark at the top, boat-up lags your heading by about a
/// second, the centre leads your boat along her eased heading, shots set the zoom, and a pinch-zoom multiplies them.
@MainActor @Suite struct CameraRigTests {
    /// iPhone 17's scene (`RaceViewportPolicy`'s full-screen portrait size).
    static let iPhone = CGSize(width: 402, height: 874)
    static let hull = 4.6
    static func degrees(_ d: Double) -> Double { d * .pi / 180 }

    /// A course laid along `axis` with its start line's centre at the origin: the pin and committee boat 50 m either
    /// side (`lineHalf`), the windward mark 800 m up the axis, the gate 100 m down it. Your boat 20 m below the line,
    /// heading `heading` at 5 m/s, the ground wind 5 m/s down the axis. Nothing else, unless `others`.
    static func world(axis: Double = 0, me: Vec2? = nil, heading: Double? = nil, others: [Vec2] = [],
                      time: Double = 120, windSpeed: Double = 5, lineHalf: Double = 50, speed: Double = 5) -> CameraWorld {
        let up = Vec2.heading(axis), right = up.rightPerp
        let position = me ?? up * -20
        let heading = heading ?? axis
        let windward = up * 800
        return CameraWorld(myPosition: position, myVelocity: Vec2.heading(heading) * speed, myHeading: heading,
                           wind: Wind(direction: axis, speed: windSpeed), others: others, axis: axis,
                           startLine: [right * -lineHalf, right * lineHalf], nextMarks: [windward], zoneRadius: 3 * hull,
                           hullLength: hull, time: time,
                           course: [windward, up * -100 + right * -10, up * -100 + right * 10, right * -lineHalf,
                                    right * lineHalf])
    }

    /// The bearing on screen from `a` to `b`, clockwise from screen up, degrees.
    static func screenBearing(_ rig: CameraRig, from a: Vec2, to b: Vec2, sceneSize: CGSize = iPhone) -> Double {
        let p = rig.project(a, sceneSize: sceneSize), q = rig.project(b, sceneSize: sceneSize)
        return atan2(Double(q.x - p.x), Double(q.y - p.y)) * 180 / .pi
    }

    static func onScreen(_ point: CGPoint, _ sceneSize: CGSize = iPhone) -> Bool {
        CGRect(origin: .zero, size: sceneSize).contains(point)
    }

    // MARK: - Acceptance

    /// Course-up turns the view so the course axis is at the top: with the axis at 37°, the windward mark is
    /// straight up the screen from your boat, ±1°, at once and after racing on.
    @Test func courseUpPutsWindwardMarkAtTop() {
        let axis = Self.degrees(37)
        let world = Self.world(axis: axis)
        let windward = Vec2.heading(axis) * 800
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(abs(rig.viewHeading - axis) < 1e-9)
        // The course axis runs from the start line's centre (the origin) to the windward mark.
        let bearing = Self.screenBearing(rig, from: .zero, to: windward)
        #expect(abs(bearing) <= 1, "windward mark at \(bearing)° on screen")
        #expect(Self.onScreen(rig.project(world.myPosition, sceneSize: Self.iPhone)))

        // Sailing on, on a reach, the view stays course-up.
        var later = world
        for _ in 0..<300 {
            later.myHeading = axis + Self.degrees(80)
            later.myPosition += Vec2.heading(later.myHeading) * 5 / 60
            rig.advance(later, sceneSize: Self.iPhone, dt: 1.0 / 60)
        }
        let after = Self.screenBearing(rig, from: .zero, to: windward)
        #expect(abs(after) <= 1, "windward mark at \(after)° on screen after a reach")
    }

    /// Boat-up follows a 90° heading step with a 1 s lag: 63 % ± 5 % of the way round after 1 s, at any frame rate,
    /// and the short way round across ±180°.
    @Test func boatUpReaches63PercentAt1s() {
        for hz in [30.0, 60.0, 120.0] {
            var rig = CameraRig(mode: .boatUp)
            rig.advance(Self.world(heading: 0), sceneSize: Self.iPhone, dt: 0, settled: true)
            #expect(rig.viewHeading == 0)
            let stepped = Self.world(heading: .pi / 2)
            for _ in 0..<Int(hz) { rig.advance(stepped, sceneSize: Self.iPhone, dt: 1 / hz) }
            let share = rig.viewHeading / (.pi / 2)
            #expect(abs(share - 0.63) <= 0.05, "\(share * 100) % at \(hz) Hz")
        }

        // From 170° to −170° is 20° to starboard through 180°, never 340° to port.
        var rig = CameraRig(mode: .boatUp)
        rig.advance(Self.world(heading: Self.degrees(170)), sceneSize: Self.iPhone, dt: 0, settled: true)
        for _ in 0..<60 { rig.advance(Self.world(heading: Self.degrees(-170)), sceneSize: Self.iPhone, dt: 1.0 / 60) }
        let turned = wrapAngle(rig.viewHeading - Self.degrees(170)) * 180 / .pi
        #expect(abs(turned - 20 * 0.632) < 1, "turned \(turned)°")
    }

    /// The scene's size comes from `RaceViewportPolicy` (#107), not the window: an iPad's full-screen and Split
    /// View windows draw the same course-up view, the windward mark at the top ±1° and your boat in the middle.
    @Test func courseUpAtTwoIPadWindowSizes() {
        let screen = CGSize(width: 1032, height: 1376)
        let policy = RaceViewportPolicy.shipping
        let windows = [screen, CGSize(width: 678, height: 1376), CGSize(width: 1376, height: 1032)]
        let sizes = windows.map { policy.layout(window: $0, safeAreaInsets: EdgeInsets(), screen: screen).sceneSize }
        #expect(sizes.allSatisfy { $0 == screen })

        let axis = Self.degrees(37)
        let world = Self.world(axis: axis)
        let windward = Vec2.heading(axis) * 800
        var projections: [CGPoint] = []
        for size in sizes.prefix(2) {
            var rig = CameraRig(mode: .courseUp)
            rig.advance(world, sceneSize: size, dt: 0, settled: true)
            let bearing = Self.screenBearing(rig, from: .zero, to: windward, sceneSize: size)
            #expect(abs(bearing) <= 1, "windward mark at \(bearing)° in \(size)")
            let me = rig.project(world.myPosition, sceneSize: size)
            #expect(abs(me.x - size.width / 2) <= size.width * 0.3 && abs(me.y - size.height / 2) <= size.height * 0.3)
            projections.append(me)
        }
        #expect(projections[0] == projections[1])
    }

    // MARK: - Heading lead and shots (#322)

    /// How much of the lead's full ellipse is drawn: 1 on a steady heading, less as the heading turns.
    static func leadShare(_ rig: CameraRig) -> Double {
        let style = CameraStyle.standard
        return ((rig.lead.across / style.leadAcross) * (rig.lead.across / style.leadAcross)
            + (rig.lead.along / style.leadAlong) * (rig.lead.along / style.leadAlong)).squareRoot()
    }

    /// Your boat's height up the screen, as a share of it.
    static func heightUp(_ rig: CameraRig, _ p: Vec2, _ size: CGSize = iPhone) -> Double {
        Double(rig.project(p, sceneSize: size).y / size.height)
    }

    /// On a dead run in course-up the lead points down the screen, the way she's going, not upwind: your boat sits
    /// above the screen's centre with the open water she's sailing into below her.
    @Test func runningLeadsAlongHeadingNotUpwind() {
        let axis = Self.degrees(37)
        var world = Self.world(axis: axis, heading: axis + .pi)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(abs(rig.viewHeading - axis) < 1e-9)
        #expect(Self.heightUp(rig, world.myPosition) > 0.65, "boat \(Self.heightUp(rig, world.myPosition)) up")

        // Running on for 20 s: the same, with the windward mark (upwind) behind her and off the top.
        for _ in 0..<(60 * 20) {
            world.myPosition += Vec2.heading(world.myHeading) * 5 / 60
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
        }
        let up = Self.heightUp(rig, world.myPosition)
        #expect(abs(up - (0.5 + CameraStyle.standard.leadAlong / 2)) < 1e-6, "boat \(up) up")
        #expect(abs(Double(rig.project(world.myPosition, sceneSize: Self.iPhone).x) - Self.iPhone.width / 2) < 1e-6)
    }

    /// A boat sailing in from 8 hull lengths to 2 (through close quarters' 4–6) changes the zoom, never where your
    /// boat sits on screen: the centre stays your boat plus the lead, frame to frame.
    @Test func boatEnteringReachDoesNotMoveTheCentre() {
        for mode in [CameraRig.Mode.courseUp, .boatUp] {
            let heading = Self.degrees(30)
            var me = Vec2(0, -20)
            let abeam = Vec2.heading(heading).rightPerp
            var world = Self.world(me: me, heading: heading, others: [me + abeam * 8 * Self.hull])
            var rig = CameraRig(mode: mode)
            rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
            let first = rig.project(me, sceneSize: Self.iPhone)
            let openZoom = rig.zoom
            for frame in 1...(60 * 10) {
                me += Vec2.heading(heading) * 5 / 60
                let apart = Self.hull * max(2, 8 - 6 * Double(frame) / 360)
                world.myPosition = me
                world.others = [me + abeam * apart]
                rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
                let p = rig.project(me, sceneSize: Self.iPhone)
                #expect(abs(p.x - first.x) < 1e-6 && abs(p.y - first.y) < 1e-6, "\(mode) frame \(frame): \(p) not \(first)")
            }
            #expect(rig.shot == .closeQuarters)
            #expect(rig.zoom > openZoom * 2, "zoom \(rig.zoom) from \(openZoom)")
        }
    }

    /// A boat oscillating across 4–6 hull lengths, at any pace, changes the shot at most once in any 4 s: close
    /// quarters comes on after a second within 4 and holds until none is within 6 for 3 s, and holds 4 s anyway.
    @Test func closeQuartersHasHysteresisAndDwell() {
        // A boat holding 3 hull lengths off: close quarters comes on after 1 s, not before.
        var near = Self.world(heading: 0)
        var onRig = CameraRig(mode: .courseUp)
        onRig.advance(near, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(onRig.shot == .openWater)
        near.others = [near.myPosition + Vec2(3 * Self.hull, 0)]
        for frame in 1...(60 * 2) {
            near.time += 1.0 / 60
            onRig.advance(near, sceneSize: Self.iPhone, dt: 1.0 / 60)
            if frame <= 57 { #expect(onRig.shot == .openWater, "close quarters early, frame \(frame)") }
            if frame >= 62 { #expect(onRig.shot == .closeQuarters, "no close quarters after 1 s, frame \(frame)") }
        }

        for period in [2.0, 5.0, 8.0, 20.0] {
            var world = Self.world(heading: 0)
            var rig = CameraRig(mode: .courseUp)
            rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
            var changes: [Double] = []
            var shot = rig.shot
            for frame in 1...(60 * 80) {
                let t = Double(frame) / 60
                world.time = 120 + t
                world.myPosition += Vec2(0, 5.0 / 60)
                world.others = [world.myPosition + Vec2(1, 0) * Self.hull * (5 + 1.5 * sin(2 * .pi * t / period))]
                rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
                if rig.shot != shot {
                    changes.append(t)
                    shot = rig.shot
                }
            }
            for (a, b) in zip(changes, changes.dropFirst()) {
                #expect(b - a >= 4 - 1e-9, "period \(period): changes at \(a) and \(b)")
            }
            if period < 10 {
                #expect(changes.count <= 1, "period \(period): \(changes)")
            } else {
                #expect(changes.count >= 2, "period \(period): close quarters should come and go, \(changes)")
            }
        }
    }

    /// After a 90° heading step the lead's direction is 63 % ± 5 % of the way round at 2 s, at any frame rate.
    @Test func tackEasesTheLead() {
        for hz in [30.0, 60.0, 120.0] {
            var rig = CameraRig(mode: .courseUp)
            rig.advance(Self.world(heading: 0), sceneSize: Self.iPhone, dt: 0, settled: true)
            #expect(rig.leadDirection == 0)
            let stepped = Self.world(heading: .pi / 2)
            for _ in 0..<Int(2 * hz) { rig.advance(stepped, sceneSize: Self.iPhone, dt: 1 / hz) }
            let share = (rig.leadDirection ?? 0) / (.pi / 2)
            #expect(abs(share - 0.63) <= 0.05, "\(share * 100) % at \(hz) Hz")
        }
        // The short way round: from 170° to −170° through 180°.
        var rig = CameraRig(mode: .courseUp)
        rig.advance(Self.world(heading: Self.degrees(170)), sceneSize: Self.iPhone, dt: 0, settled: true)
        for _ in 0..<120 { rig.advance(Self.world(heading: Self.degrees(-170)), sceneSize: Self.iPhone, dt: 1.0 / 60) }
        let turned = wrapAngle((rig.leadDirection ?? 0) - Self.degrees(170)) * 180 / .pi
        #expect(abs(turned - 20 * 0.632) < 1, "turned \(turned)°")
    }

    /// A penalty turn (a 360 in 10 s) pulls the lead in to under a third of its length within 3 s, and a straight
    /// course gives the full lead back.
    @Test func penaltyTurnShrinksTheLead() {
        var world = Self.world(heading: 0)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        for _ in 0..<(60 * 5) { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(abs(Self.leadShare(rig) - 1) < 1e-9)
        for frame in 1...(60 * 10) {
            world.myHeading = wrapAngle(2 * .pi * Double(frame) / 600)
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            if frame >= 180 { #expect(Self.leadShare(rig) < 1.0 / 3, "lead \(Self.leadShare(rig)) at \(frame)") }
        }
        for _ in 0..<(60 * 6) { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(Self.leadShare(rig) > 0.99)
    }

    /// Before the gun on a portrait phone, with your boat at rest 3 line lengths below the line: she's 40 % ± 3 % up the
    /// screen and both line ends are on it, in course-up and in boat-up (which is course-up until the gun). Above
    /// the line the composition flips. After the gun it hands over to the lead over 3 s, without a jump.
    @Test func preStartPutsBoatAt40PercentWithTheLine() {
        let axis = Self.degrees(37)
        let up = Vec2.heading(axis)
        let lineHalf = 23.0
        for mode in [CameraRig.Mode.courseUp, .boatUp] {
            let world = Self.world(axis: axis, me: up * (-3 * 2 * lineHalf), heading: axis + Self.degrees(100),
                                   time: -60, lineHalf: lineHalf, speed: 0)
            var rig = CameraRig(mode: mode)
            rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
            #expect(rig.shot == .preStart)
            #expect(abs(rig.viewHeading - axis) < 1e-9, "\(mode) is course-up before the gun")
            let height = Self.heightUp(rig, world.myPosition)
            #expect(abs(height - 0.4) <= 0.03, "\(mode): boat \(height) up")
            for end in world.startLine {
                #expect(Self.onScreen(rig.project(end, sceneSize: Self.iPhone)), "\(mode): line end off screen")
            }
            #expect(!rig.lineEndOffScreen)

            var above = world
            above.myPosition = up * (3 * 2 * lineHalf)
            rig.advance(above, sceneSize: Self.iPhone, dt: 0, settled: true)
            let flipped = Self.heightUp(rig, above.myPosition)
            #expect(abs(flipped - 0.6) <= 0.03, "\(mode): above the line, boat \(flipped) up")
        }

        // Off-centre across the line: a little, and the view stays centred on the line's middle; far, and the view
        // follows her only as far as keeps her inside the middle 70 % of the width.
        let right = up.rightPerp
        for mode in [CameraRig.Mode.courseUp, .boatUp] {
            var rig = CameraRig(mode: mode)
            let near = Self.world(axis: axis, me: up * (-3 * 2 * lineHalf) + right * 10, heading: axis, time: -60,
                                  lineHalf: lineHalf, speed: 0)
            rig.advance(near, sceneSize: Self.iPhone, dt: 0, settled: true)
            #expect(abs(rig.project(Vec2(0, 0), sceneSize: Self.iPhone).x - Self.iPhone.width / 2) < 1e-6,
                    "\(mode): the line's middle off centre")
            #expect(abs(Self.heightUp(rig, near.myPosition) - 0.4) <= 0.03)
            for across in [-1.0, 1.0] {
                let far = Self.world(axis: axis, me: up * (-3 * 2 * lineHalf) + right * (across * 6 * 2 * lineHalf),
                                     heading: axis, time: -60, lineHalf: lineHalf, speed: 0)
                rig.advance(far, sceneSize: Self.iPhone, dt: 0, settled: true)
                let x = Double(rig.project(far.myPosition, sceneSize: Self.iPhone).x / Self.iPhone.width)
                #expect(abs(x - 0.5) <= 0.35 + 1e-6, "\(mode): boat \(x) across")
                #expect(abs(abs(x - 0.5) - 0.35) < 1e-6, "\(mode): the view should follow her only to the edge")
                #expect(abs(Self.heightUp(rig, far.myPosition) - 0.4) <= 0.03)
            }
        }

        // A line too long to fit even at the widest zoom: the widest it is, and a line end is off screen.
        let long = Self.world(axis: axis, me: up * -100, heading: axis, time: -60, lineHalf: 2000, speed: 0)
        var wide = CameraRig(mode: .courseUp)
        wide.advance(long, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(wide.shot == .preStart)
        #expect(wide.zoom == wide.zoomLimits.lowerBound)
        #expect(wide.lineEndOffScreen)

        // Sailing up through the line to the gun and on: the view moves smoothly, and 3 s after the gun the boat
        // is where the lead puts her.
        var world = Self.world(axis: axis, me: up * -60, heading: axis, time: -10, lineHalf: lineHalf)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        var last = rig.project(world.myPosition, sceneSize: Self.iPhone)
        var lastZoom = rig.zoom
        for _ in 1...(60 * 16) {
            world.time += 1.0 / 60
            world.myPosition += up * 5 / 60
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            let p = rig.project(world.myPosition, sceneSize: Self.iPhone)
            #expect(hypot(p.x - last.x, p.y - last.y) < 4, "a jump of \(p) from \(last) at \(world.time)")
            #expect(abs(rig.zoom - lastZoom) < 0.02, "a zoom jump at \(world.time)")
            last = p
            lastZoom = rig.zoom
        }
        #expect(rig.shot == .openWater)
        #expect(abs(Self.heightUp(rig, world.myPosition) - (0.5 - CameraStyle.standard.leadAlong / 2)) < 1e-6)
    }

    /// Under way before the gun, the heading lead takes the composition over from the line's (#322): reaching along
    /// the line at speed, the boat is not at the edge across and has open water ahead of her bow, however far along
    /// the line she is; sailing away from the line zooms out to keep both line ends on screen; and the share moves
    /// smoothly from rest to speed.
    @Test func preStartLeadsAlongHeadingWhenUnderWay() {
        let axis = Self.degrees(37)
        let up = Vec2.heading(axis), right = up.rightPerp
        let lineHalf = 23.0
        let below = up * (-1.5 * 2 * lineHalf)
        for mode in [CameraRig.Mode.courseUp, .boatUp] {
            for side in [-1.0, 1.0] {
                // Reaching away from the line's middle, towards its end and on past it.
                let me = below + right * (side * 2 * lineHalf)
                let world = Self.world(axis: axis, me: me, heading: axis + side * .pi / 2, time: -60,
                                       lineHalf: lineHalf, speed: 4)
                var rig = CameraRig(mode: mode)
                rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
                var stopped = world
                stopped.myVelocity = Vec2(0, 0)
                var atRest = CameraRig(mode: mode)
                atRest.advance(stopped, sceneSize: Self.iPhone, dt: 0, settled: true)
                let x = Double(rig.project(me, sceneSize: Self.iPhone).x / Self.iPhone.width)
                let restX = Double(atRest.project(me, sceneSize: Self.iPhone).x / Self.iPhone.width)
                // Her bow points to screen right (side 1) or left (side -1): the boat is behind the middle of the
                // screen, with at least a quarter of it ahead of her bow.
                #expect(abs(x - 0.5) <= 0.25 + 1e-6, "\(mode): boat \(x) across the screen")
                #expect(abs(x - 0.5) < abs(restX - 0.5), "\(mode): no nearer the edge than at rest")
            }
        }

        // Sailing straight away from the line: the line stays on screen by zooming out, the boat well off the edge.
        let away = Self.world(axis: axis, me: below, heading: axis + .pi, time: -60, lineHalf: lineHalf, speed: 4)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(away, sceneSize: Self.iPhone, dt: 0, settled: true)
        var rest = away
        rest.myVelocity = Vec2(0, 0)
        var atRest = CameraRig(mode: .courseUp)
        atRest.advance(rest, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(rig.zoom <= atRest.zoom + 1e-9, "zooms out, or no closer than at rest, to keep the line")
        for end in away.startLine {
            #expect(Self.onScreen(rig.project(end, sceneSize: Self.iPhone)), "line end off screen going away")
        }
        let height = Self.heightUp(rig, away.myPosition)
        #expect(height > 0.5 && height < 0.8, "boat \(height) up, bow down the screen: more room below her than above")

        // The share from rest to speed is smooth: the boat's place on the screen moves less than a point per
        // 0.05 m/s.
        var last: CGPoint?
        for step in 0...60 {
            var w = Self.world(axis: axis, me: below + right * 30, heading: axis, time: -60, lineHalf: lineHalf,
                               speed: Double(step) * 0.05)
            w.myVelocity = Vec2.heading(axis) * Double(step) * 0.05
            var r = CameraRig(mode: .courseUp)
            r.advance(w, sceneSize: Self.iPhone, dt: 0, settled: true)
            let p = r.project(w.myPosition, sceneSize: Self.iPhone)
            if let last { #expect(hypot(p.x - last.x, p.y - last.y) < 12, "a jump at \(step)") }
            last = p
        }
    }

    /// A start line end under the HUD or the controls counts as off screen (#122): `lineEndOffScreen` reads the
    /// clear area `visibleInsets` leaves, the same rect the edge arrow reads, so the two never disagree.
    @Test func lineEndUnderTheHUDIsOffScreen() {
        let axis = Self.degrees(37)
        let up = Vec2.heading(axis)
        let world = Self.world(axis: axis, me: up * (-3 * 2 * 23.0), heading: axis, time: -60, lineHalf: 23, speed: 0)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(!rig.lineEndOffScreen, "both ends on the bare screen")
        let ends = world.startLine.map { rig.project($0, sceneSize: Self.iPhone) }
        let lowest = ends.map(\.y).min() ?? 0

        // A HUD reaching just below the line: both ends under it.
        rig.visibleInsets = ViewInsets(top: Self.iPhone.height - lowest + 1, bottom: 0, side: 0)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(rig.lineEndOffScreen, "the line's ends are under the HUD")
        let visible = rig.visibleInsets.visibleRect(sceneSize: Self.iPhone)
        for end in world.startLine {
            #expect(!ViewInsets.contains(visible, rig.project(end, sceneSize: Self.iPhone)))
            #expect(EdgeArrow.placement(projected: rig.project(end, sceneSize: Self.iPhone), visible: visible) != nil,
                    "the arrow reads the end as off screen too")
        }

        // One just clear of it: on screen again.
        rig.visibleInsets = ViewInsets(top: Self.iPhone.height - (ends.map(\.y).max() ?? 0) - 1, bottom: 0, side: 0)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(!rig.lineEndOffScreen)
    }

    /// Rounding the windward mark with a close pinch-zoom: the mark-rounding shot widens, smoothly and only as
    /// much as it must, to keep the mark on screen.
    @Test func markRoundingWidensToKeepTheMark() {
        // Inside the shot's reach with the mark already on screen: the shot's own zoom, not widened.
        var fits = CameraRig(mode: .courseUp)
        fits.advance(Self.world(me: Vec2(-10, 790), heading: .pi / 2, time: 300), sceneSize: Self.iPhone, dt: 0,
                     settled: true)
        #expect(fits.shot == .markRounding)
        #expect(abs(fits.zoom - CameraStyle.standard.markRoundingZoom) < 1e-9, "zoom \(fits.zoom)")

        let mark = Vec2(0, 800)
        var world = Self.world(me: Vec2(-60, 780), heading: .pi / 2, time: 300)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        rig.pinchChanged(by: 2)
        #expect(abs(rig.zoomMultiplier - 2) < 1e-9)
        var since: Double?
        var widest = Double.infinity
        var lastZoom = rig.zoom
        var rounded = false
        for frame in 1...(60 * 24) {
            world.myPosition += Vec2(5.0 / 60, 0)
            world.time += 1.0 / 60
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            #expect(abs(rig.zoom - lastZoom) < 0.02, "a zoom jump at frame \(frame)")
            lastZoom = rig.zoom
            if rig.shot == .markRounding {
                rounded = true
                since = (since ?? 0) + 1.0 / 60
                if since! > CameraStyle.standard.shotTransitionSeconds {
                    #expect(Self.onScreen(rig.project(mark, sceneSize: Self.iPhone)), "mark off screen at \(world.myPosition)")
                    widest = min(widest, rig.zoom)
                }
            } else {
                since = nil
            }
        }
        #expect(rounded)
        #expect(widest < CameraStyle.standard.markRoundingZoom * 2 - 0.05, "never widened: \(widest)")
    }

    /// The pinch multiplier rides on every shot: open water's zoom and then close quarters' are both multiplied,
    /// a new race starts with the kept multiplier, a double tap eases it back to 1, and zooming out stops at the
    /// whole course.
    @Test func pinchMultiplierPersistsAcrossShots() {
        let style = CameraStyle.standard
        var world = Self.world(heading: 0)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(abs(rig.zoom - style.openWaterZoom) < 1e-9)
        rig.pinchChanged(by: 1.2)
        #expect(abs(rig.zoom - style.openWaterZoom * 1.2) < 1e-9)
        #expect(abs(rig.zoomMultiplier - 1.2) < 1e-9)
        for _ in 0..<60 { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(abs(rig.zoom - style.openWaterZoom * 1.2) < 1e-9)

        world.others = [world.myPosition + Vec2(2 * Self.hull, 0)]
        for _ in 0..<(60 * 4) { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(rig.shot == .closeQuarters)
        #expect(abs(rig.zoom - style.closeQuartersZoom * 1.2) < 1e-9, "zoom \(rig.zoom)")

        // The next race: the scene hands the kept multiplier to its new rig.
        var next = CameraRig(mode: .courseUp)
        next.setZoomMultiplier(1.2)
        next.advance(Self.world(heading: 0), sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(abs(next.zoom - style.openWaterZoom * 1.2) < 1e-9)

        // A double tap: back to 1, eased.
        next.resetZoomMultiplier()
        #expect(next.zoomMultiplier == 1)
        var lastZoom = next.zoom
        for _ in 0..<(60 * 3) {
            next.advance(Self.world(heading: 0), sceneSize: Self.iPhone, dt: 1.0 / 60)
            #expect(abs(next.zoom - lastZoom) < 0.01)
            lastZoom = next.zoom
        }
        #expect(abs(next.zoom - style.openWaterZoom) < 1e-9)

        // A course that fits a closer zoom than the widest: zooming out stops at it.
        var small = Self.world(heading: 0)
        small.course = [Vec2(0, 30), Vec2(0, -30), Vec2(-20, 0), Vec2(20, 0)]
        next.advance(small, sceneSize: Self.iPhone, dt: 1.0 / 60)
        #expect(next.zoomLimits.lowerBound > style.minZoom)
        #expect(next.zoomLimits.lowerBound <= 874 / (60 * 8.0) + 1e-9)
        next.pinchChanged(by: 0.01)
        #expect(next.zoom == next.zoomLimits.lowerBound)
    }

    /// With auto zoom off the heading lead stays, and the zoom is open water's times the pinch multiplier whatever
    /// happens: no close quarters, no pre-start shot.
    @Test func autoZoomOffKeepsTheLead() {
        let style = CameraStyle.standard
        let axis = Self.degrees(37)
        var world = Self.world(axis: axis, heading: axis + .pi, time: -30)
        var rig = CameraRig(mode: .courseUp, autoZoom: false)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(rig.shot == .openWater)
        #expect(abs(rig.zoom - style.openWaterZoom) < 1e-9)
        #expect(abs(Self.heightUp(rig, world.myPosition) - (0.5 + style.leadAlong / 2)) < 1e-6, "the lead stays")
        rig.pinchChanged(by: 1.5)
        world.others = [world.myPosition + Vec2.heading(axis).rightPerp * Self.hull]
        for _ in 0..<(60 * 20) {
            world.time += 1.0 / 60
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            #expect(rig.shot == .openWater)
        }
        #expect(abs(rig.zoom - style.openWaterZoom * 1.5) < 1e-9)
        #expect(abs(Self.heightUp(rig, world.myPosition) - (0.5 + style.leadAlong / 2)) < 1e-6)
    }

    /// Leaving the mark's zone inside the shot's 4 s dwell: the shot holds, and so does its widening to keep the
    /// mark on screen, so the zoom never steps from the capped to the uncapped mark-rounding zoom in one frame.
    @Test func leavingTheMarkInsideTheDwellDoesNotPop() {
        let style = CameraStyle.standard
        let mark = Vec2(0, 800)
        var world = Self.world(me: Vec2(-40, 798), heading: .pi / 2, time: 300)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        rig.pinchChanged(by: 2)
        #expect(abs(rig.zoomMultiplier - 2) < 1e-9)
        // At 120 Hz, so the widening's own steps stay well under the pop it used to make (about 0.6).
        var lastZoom = rig.zoom
        var narrowest = Double.infinity
        var left = false
        for frame in 1...(120 * 10) {
            world.myPosition += Vec2(12.0 / 120, 0)
            world.time += 1.0 / 120
            // Past the mark, the next leg's.
            if world.myPosition.x > 0 { world.nextMarks = [Vec2(0, -100)] }
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 120)
            #expect(abs(rig.zoom - lastZoom) < 0.03, "a zoom step of \(rig.zoom - lastZoom) at frame \(frame)")
            lastZoom = rig.zoom
            if rig.shot == .markRounding { narrowest = min(narrowest, rig.zoom) }
            if !left, world.myPosition.x > 0, (world.myPosition - mark).length > world.zoneRadius {
                left = true
                #expect(rig.shot == .markRounding, "the shot should hold through its dwell")
            }
        }
        #expect(left)
        #expect(narrowest < style.markRoundingZoom * 2 - 0.05, "the cap never engaged: \(narrowest)")
        #expect(rig.shot == .openWater)
    }

    /// A pinch at a zoom limit, or against mark rounding's cap, changes nothing: the multiplier stays what the
    /// drawn zoom over the shot's own zoom says, so a later pinch the other way shows at once.
    @Test func pinchAtALimitKeepsTheMultiplier() {
        let style = CameraStyle.standard
        let world = Self.world(heading: 0)
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        let upper = rig.zoomLimits.upperBound, lower = rig.zoomLimits.lowerBound

        rig.pinchChanged(by: 4)
        #expect(abs(rig.zoom - upper) < 1e-9)
        #expect(abs(rig.zoomMultiplier - upper / style.openWaterZoom) < 1e-9)
        let atUpper = (zoom: rig.zoom, multiplier: rig.zoomMultiplier)
        rig.pinchChanged(by: 1.5)
        #expect(rig.zoomMultiplier == atUpper.multiplier && rig.zoom == atUpper.zoom)
        rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
        #expect(abs(rig.zoom - upper) < 1e-9)
        rig.pinchChanged(by: 0.9)
        #expect(abs(rig.zoom - upper * 0.9) < 1e-9)
        rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
        #expect(abs(rig.zoom - upper * 0.9) < 1e-9, "the pinch out shows at once and stays")

        rig.pinchChanged(by: 0.01)
        #expect(abs(rig.zoom - lower) < 1e-9)
        let atLower = (zoom: rig.zoom, multiplier: rig.zoomMultiplier)
        #expect(abs(atLower.multiplier - lower / style.openWaterZoom) < 1e-9)
        rig.pinchChanged(by: 0.5)
        #expect(rig.zoomMultiplier == atLower.multiplier && rig.zoom == atLower.zoom)

        // Mark rounding's cap: pinching in stops where the mark would leave the screen.
        let rounding = Self.world(me: Vec2(-25, 795), heading: .pi / 2, time: 300)
        var capped = CameraRig(mode: .courseUp)
        capped.advance(rounding, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(capped.shot == .markRounding)
        #expect(abs(capped.zoom - style.markRoundingZoom) < 1e-9)
        capped.pinchChanged(by: 3)
        let atCap = (zoom: capped.zoom, multiplier: capped.zoomMultiplier)
        #expect(atCap.zoom < style.markRoundingZoom * 3 - 0.1, "the cap should stop the pinch: \(atCap.zoom)")
        #expect(abs(atCap.multiplier * style.markRoundingZoom - atCap.zoom) < 1e-9)
        capped.pinchChanged(by: 1.5)
        #expect(capped.zoomMultiplier == atCap.multiplier && capped.zoom == atCap.zoom)
        capped.advance(rounding, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(abs(capped.zoom - atCap.zoom) < 1e-9)
        #expect(Self.onScreen(capped.project(Vec2(0, 800), sceneSize: Self.iPhone)))
    }

    /// The pinch-zoom's reset is a two-finger double tap, so a one-finger double tap that steers never resets it.
    @Test func zoomResetIsATwoFingerDoubleTap() {
        let tap = GameScene.zoomResetRecognizer(target: nil, action: nil)
        #expect(tap.numberOfTouchesRequired == 2)
        #expect(tap.numberOfTapsRequired == 2)
        #expect(!tap.cancelsTouchesInView, "the taps still reach the scene")
    }

    /// A rig reports no pre-start shot before its first frame, and the right one from the first frame's race clock.
    @Test func shotFollowsTheFirstFramesClock() {
        var midRace = CameraRig(mode: .courseUp)
        #expect(midRace.shot == .openWater)
        midRace.advance(Self.world(time: 120), sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(midRace.shot == .openWater)
        var beforeGun = CameraRig(mode: .courseUp)
        beforeGun.advance(Self.world(time: -30), sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(beforeGun.shot == .preStart)
    }

    // MARK: - The rest of the camera

    /// The rotation's sign, checked against SpriteKit itself (ruling 6): a boat heading east in boat-up has her bow
    /// straight up the screen in the camera's own space, where `project` puts it.
    @Test func boatUpPutsTheBowUpOnScreen() {
        let east = Double.pi / 2
        let world = Self.world(heading: east)
        var rig = CameraRig(mode: .boatUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)

        let scene = SKScene(size: Self.iPhone)
        let cam = SKCameraNode()
        scene.addChild(cam)
        scene.camera = cam
        cam.position = rig.center
        cam.setScale(rig.cameraScale)
        cam.zRotation = rig.cameraRotation
        let ppm = rig.pointsPerMeter
        for p in [world.myPosition, world.myPosition + Vec2.heading(east) * 10] {
            let inCamera = cam.convert(CGPoint(x: p.x * ppm, y: p.y * ppm), from: scene)
            let projected = rig.project(p, sceneSize: Self.iPhone)
            // The camera's space is scaled with it: a scene point per view point, centred.
            // SpriteKit's transforms are single precision.
            #expect(abs(projected.x - Self.iPhone.width / 2 - inCamera.x) < 1e-3)
            #expect(abs(projected.y - Self.iPhone.height / 2 - inCamera.y) < 1e-3)
        }
        #expect(abs(Self.screenBearing(rig, from: world.myPosition, to: world.myPosition + Vec2.heading(east) * 10)) < 1e-6)
    }

    /// The north-up follow camera is the boat camera from before #113, value for value, so the render fixtures
    /// drawn with it keep their references: on her velocity's lead at the default zoom, unturned.
    @Test func northUpFollowIsTheOldBoatCamera() {
        let world = Self.world(axis: Self.degrees(37), heading: Self.degrees(100))
        var rig = CameraRig(mode: .northUpFollow)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        let start = CGPoint(x: CGFloat(world.myPosition.x) * 8, y: CGFloat(world.myPosition.y) * 8)
        let lead = world.myPosition + world.myVelocity * CameraStyle.standard.lookAheadSeconds
        let target = CGPoint(x: CGFloat(lead.x) * 8, y: CGFloat(lead.y) * 8)
        #expect(rig.center == CGPoint(x: start.x + (target.x - start.x) * 1, y: start.y + (target.y - start.y) * 1))
        #expect(rig.cameraScale == 1 / GameScene.defaultZoom)
        #expect(rig.cameraRotation == 0 && rig.viewHeading == 0)

        var course = CameraRig(mode: .northUpCourse)
        course.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        let framing = CameraRig.courseFraming(world.course, sceneSize: Self.iPhone, zoom: GameScene.defaultZoom,
                                              margin: 1.2, pointsPerMeter: 8)
        #expect(course.center == framing?.center && course.cameraScale == framing?.scale && course.cameraRotation == 0)
    }

    /// A new default zoom from the tuning panel replaces the north-up follow camera's pinch-zoom (#232), as it did
    /// before #113.
    @Test func aNewDefaultZoomReplacesThePinchZoom() {
        var rig = CameraRig(mode: .northUpFollow)
        rig.advance(Self.world(), sceneSize: Self.iPhone, dt: 0, settled: true)
        rig.pinchChanged(by: 2)
        var style = CameraStyle.standard
        style.defaultZoom = 1.1
        rig.setStyle(style)
        #expect(rig.zoom == 1.1)
    }

    /// The HUD's arrows turn with the view: a compass bearing on screen is the bearing less the view heading.
    @Test func hudArrowsTurnWithTheView() {
        let view = Self.degrees(37)
        #expect(abs(HUDModel.screenAngle(ofCompass: Self.degrees(37), viewHeading: view)) < 1e-12)
        #expect(abs(HUDModel.screenAngle(ofCompass: Self.degrees(127), viewHeading: view) - Self.degrees(90)) < 1e-12)
        #expect(abs(HUDModel.screenAngle(ofCompass: Self.degrees(-160), viewHeading: view) - Self.degrees(163)) < 1e-12)
    }

    /// A camera tuning saved before #113 keeps its values; the new fields take their standard ones.
    @Test func preOneThirteenCameraKeepsItsTuning() throws {
        let json = #"{"lookAheadSeconds":3,"followRate":2,"defaultZoom":1,"courseMargin":1.5}"#
        let style = try JSONDecoder().decode(CameraStyle.self, from: Data(json.utf8))
        var expected = CameraStyle.standard
        expected.lookAheadSeconds = 3
        expected.followRate = 2
        expected.defaultZoom = 1
        expected.courseMargin = 1.5
        #expect(style == expected)

        // One saved with #113's framing and pinch hold (#322 dropped them) keeps the rest.
        let framed = #"{"boatUpLagSeconds":2,"framingHullLengths":8,"framingUpwindSeconds":20,"lineFramingSecondsAfterGun":5,"framingMargin":1.5,"framingEaseRate":2,"pinchHoldSeconds":3,"minZoom":0.4}"#
        let kept = try JSONDecoder().decode(CameraStyle.self, from: Data(framed.utf8))
        var keptExpected = CameraStyle.standard
        keptExpected.boatUpLagSeconds = 2
        keptExpected.minZoom = 0.4
        #expect(kept == keptExpected)
    }
}
