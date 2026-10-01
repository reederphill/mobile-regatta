import CoreGraphics
import Foundation
import SpriteKit
import SwiftUI
import Testing
import RegattaCore
@testable import Regatta

/// The race camera (#113): course-up puts the windward mark at the top, boat-up lags your heading by about a
/// second, auto framing keeps the boats near you in view, and a pinch-zoom holds, then eases back.
@MainActor @Suite struct CameraRigTests {
    /// iPhone 17's scene (`RaceViewportPolicy`'s full-screen portrait size).
    static let iPhone = CGSize(width: 402, height: 874)
    static let hull = 4.6
    static func degrees(_ d: Double) -> Double { d * .pi / 180 }

    /// A course laid along `axis` with its start line's centre at the origin: the pin and committee boat 50 m either
    /// side, the windward mark 800 m up the axis, the gate 100 m down it. Your boat 20 m below the line, heading
    /// `heading` at 5 m/s, the ground wind 5 m/s down the axis. Nothing else, unless `others`.
    static func world(axis: Double = 0, me: Vec2? = nil, heading: Double? = nil, others: [Vec2] = [],
                      time: Double = 120, windSpeed: Double = 5) -> CameraWorld {
        let up = Vec2.heading(axis), right = up.rightPerp
        let position = me ?? up * -20
        let heading = heading ?? axis
        let windward = up * 800
        return CameraWorld(myPosition: position, myVelocity: Vec2.heading(heading) * 5, myHeading: heading,
                           wind: Wind(direction: axis, speed: windSpeed), others: others, axis: axis,
                           startLine: [right * -50, right * 50], nextMarks: [windward], zoneRadius: 3 * hull,
                           hullLength: hull, time: time,
                           course: [windward, up * -100 + right * -10, up * -100 + right * 10, right * -50, right * 50])
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

    /// Auto framing keeps a boat five hull lengths from yours in view with yours, in course-up and boat-up, while
    /// she sails out to it from alongside you; both whole, inside the screen.
    @Test func twoBoatsFiveLengthsApartStayFramed() {
        for (mode, heading) in [(CameraRig.Mode.courseUp, 0.0), (.courseUp, Self.degrees(-45)), (.boatUp, Self.degrees(45)),
                                (.boatUp, Self.degrees(180))] {
            var rig = CameraRig(mode: mode)
            var me = Vec2(0, -20)
            let course = Vec2.heading(heading)
            let abeam = course.rightPerp
            var world = Self.world(me: me, heading: heading, others: [me + abeam * Self.hull])
            rig.advance(world, sceneSize: Self.iPhone, dt: 0)
            for frame in 1...600 {
                me += course * 5 / 60
                // She opens out from one hull length abeam to five over the first 5 s, then holds there.
                let apart = Self.hull * (1 + 4 * min(Double(frame) / 300, 1))
                world.myPosition = me
                world.others = [me + abeam * apart]
                rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            }
            let other = world.others[0]
            #expect(abs((other - me).length - 5 * Self.hull) < 1e-6)
            // Each boat whole on screen: a hull length round her centre.
            for boat in [me, other] {
                for corner in [Vec2(1, 1), Vec2(1, -1), Vec2(-1, 1), Vec2(-1, -1)] {
                    let point = rig.project(boat + corner * Self.hull / 2, sceneSize: Self.iPhone)
                    #expect(Self.onScreen(point), "\(mode) heading \(heading): \(point) off screen, zoom \(rig.zoom), centre \(rig.center), me \(me), vh \(rig.viewHeading)")
                }
            }
            #expect(rig.zoomLimits.contains(rig.zoom))
        }
    }

    /// A pinch-zoom takes the zoom at once, holds it 5 s ± 0.5 s after the fingers lift (not while they're down),
    /// then eases back to auto framing's zoom without snapping.
    @Test func pinchZoomHoldsThenEasesBack() {
        let world = Self.world()
        var rig = CameraRig(mode: .courseUp)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        let auto = rig.zoom
        rig.pinchChanged(by: 1.6)
        let pinched = rig.zoom
        #expect(abs(pinched - auto * 1.6) < 1e-9)
        // Fingers down for 8 s: the zoom stays put.
        for _ in 0..<480 { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(rig.zoom == pinched)
        rig.pinchEnded()
        var held: Double?
        var previous = rig.zoom
        var biggestStep = 0.0
        for frame in 1...(60 * 20) {
            rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60)
            if held == nil, rig.zoom != pinched { held = Double(frame) / 60 }
            biggestStep = max(biggestStep, abs(rig.zoom - previous))
            previous = rig.zoom
        }
        #expect(held.map { abs($0 - 5) <= 0.5 } == true, "held \(String(describing: held)) s")
        #expect(abs(rig.zoom - auto) / auto < 0.01, "zoom \(rig.zoom), auto \(auto)")
        #expect(biggestStep < (pinched - auto) * 0.05, "a step of \(biggestStep) is a snap")
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

    /// Auto framing frames the start line before the gun and up to 10 s after, then lets it go; inside the next
    /// mark's zone the mark is in view.
    @Test func autoFramingFramesTheLineAndTheMarkInItsZone() {
        let rig = CameraRig(mode: .courseUp)
        var world = Self.world(time: -60)
        let line = rig.framingTarget(world, sceneSize: Self.iPhone)
        world.time = 9
        #expect(rig.framingTarget(world, sceneSize: Self.iPhone) == line)
        world.time = 11
        let raced = rig.framingTarget(world, sceneSize: Self.iPhone)
        #expect(raced.zoom > line.zoom, "the line no longer widens the view")

        var settled = CameraRig(mode: .courseUp)
        var atMark = Self.world(me: Vec2(0, 790), heading: 0, time: 300)
        atMark.wind = Wind(direction: 0, speed: 0)
        settled.advance(atMark, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(Self.onScreen(settled.project(Vec2(0, 800), sceneSize: Self.iPhone)))
        atMark.myPosition = Vec2(0, 700)
        settled.advance(atMark, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(!Self.onScreen(settled.project(Vec2(0, 800), sceneSize: Self.iPhone)), "out of the zone, 100 m off")
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

    /// With auto framing off, the camera follows your boat's lead at the default zoom, turned, and a pinch-zoom
    /// stays: no hold, no easing back. Zooming out stops at the whole course.
    @Test func autoFramingOffKeepsThePinchZoom() {
        let world = Self.world(axis: Self.degrees(37))
        var rig = CameraRig(mode: .courseUp, autoFraming: false)
        rig.advance(world, sceneSize: Self.iPhone, dt: 0, settled: true)
        #expect(rig.zoom == CameraStyle.standard.defaultZoom)
        #expect(abs(rig.viewHeading - Self.degrees(37)) < 1e-9)
        rig.pinchChanged(by: 1.5)
        rig.pinchEnded()
        for _ in 0..<(60 * 20) { rig.advance(world, sceneSize: Self.iPhone, dt: 1.0 / 60) }
        #expect(abs(rig.zoom - CameraStyle.standard.defaultZoom * 1.5) < 1e-9)
        rig.pinchChanged(by: 0.01)
        #expect(rig.zoom == CameraStyle.standard.minZoom)

        // A course that fits a closer zoom than the widest: zooming out stops at it.
        var small = world
        small.course = [Vec2(0, 30), Vec2(0, -30), Vec2(-20, 0), Vec2(20, 0)]
        rig.advance(small, sceneSize: Self.iPhone, dt: 1.0 / 60)
        let fit = 874 / (60 * 8.0)
        #expect(rig.zoomLimits.lowerBound > CameraStyle.standard.minZoom)
        #expect(rig.zoomLimits.lowerBound <= fit + 1e-9)
        rig.pinchChanged(by: 0.01)
        #expect(rig.zoom == rig.zoomLimits.lowerBound)
    }

    /// A new default zoom from the tuning panel replaces a pinch-zoom (#232), as it did before #113.
    @Test func aNewDefaultZoomReplacesThePinchZoom() {
        var rig = CameraRig(mode: .courseUp, autoFraming: false)
        rig.advance(Self.world(), sceneSize: Self.iPhone, dt: 0, settled: true)
        rig.pinchChanged(by: 2)
        var style = CameraStyle.standard
        style.defaultZoom = 1.1
        rig.setStyle(style)
        #expect(rig.zoom == 1.1)
    }

    /// The HUD's arrows turn with the view: a compass bearing on screen is the bearing less the view heading.
    @Test func hudArrowsTurnWithTheView() {
        var hud = HUDState()
        hud.viewHeading = Self.degrees(37)
        #expect(abs(hud.screenAngle(ofCompass: Self.degrees(37))) < 1e-12)
        #expect(abs(hud.screenAngle(ofCompass: Self.degrees(127)) - Self.degrees(90)) < 1e-12)
        #expect(abs(hud.screenAngle(ofCompass: Self.degrees(-160)) - Self.degrees(163)) < 1e-12)
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
    }
}
