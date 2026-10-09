import CoreGraphics
import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The boat-side cues (#122): laylines at the class's best angle, the next-mark edge arrow only while the mark is off
/// screen, the wind vane's groove tick, lock and arc, the pinch/foot sail shape, and ladder lines across the axis.
@MainActor @Suite struct BoatCueTests {
    static let boatClass = Race.defaultBoatClass
    /// The default class with an autohelm that holds a centred rudder (skiff@6's): the default, skiff@7, steers by
    /// hand (#437), so a test of a held rudder on a holding class names this.
    static let holdingClass: BoatClass = {
        var holding = Race.defaultBoatClass
        holding.steering.autohelm.holdsWhenCentred = true
        return holding
    }()

    /// The prestart fixture's course: a real derived course, its axis 9° off north.
    static func course() throws -> CourseLayout {
        let (fixture, log) = try RenderFixture.load(named: "prestart", in: RenderFixtureTests.fixtures)
        return try FixtureDriver(log: log, freezeTick: fixture.freezeTick).course
    }

    // MARK: - Laylines

    /// The laylines to the windward mark arrive at the polar's best upwind angle to the wind at the mark, and to the
    /// gate at its best downwind angle, in 6, 12 and 20 knots: one on each tack, or one only where the downwind
    /// best angle is dead downwind and the two coincide. The cue takes the wind at the mark and nothing else, so
    /// current never moves them (#11).
    @Test func laylineAngleIsClassBestAngle() throws {
        let course = try Self.course()
        let polar = Self.boatClass.polar
        let direction = course.axis + 0.07
        for knots in [6.0, 12, 20] {
            let tws = metresPerSecond(knots: knots)
            let wind: (Vec2) -> GroundWind? = { _ in GroundWind(direction: direction, speed: tws) }
            for (index, best) in [(CourseLayout.windwardIndex, polar.bestUpwind(tws: tws).twa),
                                  (CourseLayout.gateIndex, polar.bestDownwind(tws: tws).twa)] {
                let leg = CourseLayout.Leg.round(index)
                let segments = LaylineCue.segments(for: leg, in: course, polar: polar, wind: wind)
                let coincide = abs(best - .pi) < 1e-9
                #expect(segments.count == (coincide ? 1 : 2), "\(knots) kn, leg \(index)")
                var sides: [Double] = []
                for segment in segments {
                    #expect(segment.from == course.targetPosition(for: leg))
                    // The heading a boat on it arrives at the mark on, and its angle off the wind.
                    let arrival = (segment.from - segment.to).bearing
                    let off = wrapAngle(direction - arrival)
                    #expect(abs(abs(off) - best) < 1e-9, "\(knots) kn, leg \(index): \(rad2deg(abs(off)))° vs \(rad2deg(best))°")
                    #expect(abs((segment.to - segment.from).length - LaylineCue.length) < 1e-6)
                    sides.append(off)
                }
                if sides.count == 2 { #expect(sides[0] * sides[1] < 0, "one on each tack") }
            }
            // The reach and the finish have none.
            #expect(LaylineCue.segments(for: .round(CourseLayout.offsetIndex), in: course, polar: polar, wind: wind).isEmpty)
            #expect(LaylineCue.segments(for: .finish, in: course, polar: polar, wind: wind).isEmpty)
        }
        // No wind yet (online before the key): none.
        #expect(LaylineCue.segments(for: .round(CourseLayout.windwardIndex), in: course, polar: polar,
                                    wind: { _ in nil }).isEmpty)
    }

    // MARK: - Edge arrow

    /// The arrow shows iff the mark is outside the visible rect (the view inset clear of the HUD and controls),
    /// sits on that rect's edge and points from its centre straight at the mark as drawn, under course-up and
    /// boat-up both: so it turns with the view.
    @Test func edgeArrowHiddenIffMarkVisible() throws {
        let size = CameraRigTests.iPhone
        let style = BoatStyle.standard
        let visible = EdgeArrow.insets(safeArea: (top: 59, bottom: 34), showsLeaderboard: false, style: style)
            .visibleRect(sceneSize: size)
        #expect(visible.minX == CGFloat(style.edgeArrowInsetSide))
        #expect(abs(visible.maxX - (size.width - CGFloat(style.edgeArrowInsetSide))) < 1e-9)
        let isInside = { (p: CGPoint) in ViewInsets.contains(visible, p) }
        let world = CameraRigTests.world(axis: CameraRigTests.degrees(37), heading: CameraRigTests.degrees(95))
        for mode in [CameraRig.Mode.courseUp, .boatUp] {
            var rig = CameraRig(mode: mode)
            rig.advance(world, sceneSize: size, dt: 0, settled: true)
            var shown = 0, hidden = 0
            for x in stride(from: -900.0, through: 900, by: 37) {
                for y in stride(from: -900.0, through: 900, by: 41) {
                    let mark = world.myPosition + Vec2(x, y)
                    let p = rig.project(mark, sceneSize: size)
                    let placed = EdgeArrow.placement(projected: p, visible: visible)
                    #expect((placed == nil) == isInside(p), "\(mode) mark at \(p)")
                    guard let placed else { hidden += 1; continue }
                    shown += 1
                    // On the rect's edge.
                    let edge = min(abs(placed.position.x - visible.minX), abs(placed.position.x - visible.maxX),
                                   abs(placed.position.y - visible.minY), abs(placed.position.y - visible.maxY))
                    #expect(edge < 1e-6, "\(mode): \(placed.position) off the edge")
                    // Pointing at the mark as drawn, from the arrow and from the rect's centre alike.
                    let toMark = atan2(p.y - placed.position.y, p.x - placed.position.x)
                    let fromCentre = atan2(p.y - visible.midY, p.x - visible.midX)
                    #expect(abs(wrapAngle(Double(placed.angle - fromCentre))) < 1e-9, "\(mode)")
                    if hypot(p.x - placed.position.x, p.y - placed.position.y) > 1e-6 {
                        #expect(abs(wrapAngle(Double(placed.angle - toMark))) < 1e-9, "\(mode)")
                    }
                }
            }
            #expect(shown > 0 && hidden > 0, "\(mode): \(shown) shown, \(hidden) hidden")
        }

        // Boat-up turns the arrow with the view: the windward mark straight up the screen in course-up is off to a
        // side heading 95°.
        let windward = Vec2.heading(world.axis) * 800
        var courseUp = CameraRig(mode: .courseUp), boatUp = CameraRig(mode: .boatUp)
        courseUp.advance(world, sceneSize: size, dt: 0, settled: true)
        boatUp.advance(world, sceneSize: size, dt: 0, settled: true)
        let up = try #require(EdgeArrow.placement(projected: courseUp.project(windward, sceneSize: size), visible: visible))
        let turned = try #require(EdgeArrow.placement(projected: boatUp.project(windward, sceneSize: size), visible: visible))
        #expect(abs(Double(up.angle) - .pi / 2) < 0.05, "course-up: \(rad2deg(Double(up.angle)))°")
        #expect(abs(wrapAngle(Double(turned.angle - up.angle))) > 1, "boat-up didn't turn it")
    }

    /// What the arrow points at: the start line's two ends before the start, prestart and OCS on the way back
    /// alike, whatever the camera; the leg's mark racing, a gate's and the finish line's centre; nothing once
    /// finished.
    @Test func edgeArrowTargetsTheMarkYouSailFor() throws {
        let course = try Self.course()
        let line = course.startLine
        for status in [BoatStatus.prestart, .ocs] {
            #expect(EdgeArrow.targets(status: status, legIndex: 0, course: course)
                    == [line.pin.position, line.committee.position], "\(status)")
        }
        for (k, leg) in course.legs.enumerated() {
            #expect(EdgeArrow.targets(status: .racing, legIndex: k, course: course) == [course.targetPosition(for: leg)])
        }
        let gate = course.marksOfLeg(.round(CourseLayout.gateIndex)).map(\.position)
        #expect(gate.count == 2)
        #expect((course.targetPosition(for: .round(CourseLayout.gateIndex)) - (gate[0] + gate[1]) / 2).length < 1e-6)
        #expect(EdgeArrow.targets(status: .finished, legIndex: 0, course: course).isEmpty)
        #expect(EdgeArrow.targets(status: .dsq, legIndex: 0, course: course).isEmpty)

        // A line's two ends: no arrow while any of the line shows, one end on screen or neither with the line
        // across the view between them; with none of it on screen, at its nearer end.
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100)
        let project: (Vec2) -> CGPoint = { CGPoint(x: $0.x, y: $0.y) }
        #expect(EdgeArrow.placement(targets: [Vec2(20, 50), Vec2(80, 50)], project: project, visible: visible) == nil)
        #expect(EdgeArrow.placement(targets: [Vec2(50, 50), Vec2(300, 50)], project: project, visible: visible) == nil,
                "one end on screen")
        #expect(EdgeArrow.placement(targets: [Vec2(-200, 50), Vec2(300, 50)], project: project, visible: visible) == nil,
                "both ends off, the middle of the line on screen")
        #expect(EdgeArrow.placement(targets: [Vec2(-50, 120), Vec2(120, -50)], project: project, visible: visible) == nil,
                "both ends off, the line cutting a corner")
        #expect(EdgeArrow.placement(targets: [Vec2(100, 100), Vec2(300, 300)], project: project, visible: visible) == nil,
                "an end on the rect's corner")
        // Above the view, the pin up and to the left, the committee boat further off to the right: the pin's way.
        let pin = Vec2(-100, 250), committee = Vec2(400, 250)
        let bothOff = try #require(EdgeArrow.placement(targets: [pin, committee], project: project, visible: visible))
        #expect(bothOff == EdgeArrow.placement(projected: CGPoint(x: pin.x, y: pin.y), visible: visible))
        #expect(bothOff.angle > .pi / 2 && bothOff.angle < .pi, "up and left: \(rad2deg(Double(bothOff.angle)))°")
        #expect(EdgeArrow.placement(targets: [committee, pin], project: project, visible: visible) == bothOff,
                "the nearer end, whichever end is listed first")
        #expect(EdgeArrow.placement(targets: [Vec2(-90, 120), Vec2(120, 330)], project: project, visible: visible) != nil,
                "a diagonal line clear of the corner")
    }

    /// The edge arrow's clear area is the HUD's: its top under the notice line (lower with the live leaderboard
    /// on), its bottom over the controls row, both inside the safe area and `edgeArrowClearance` clear of them.
    @Test func edgeArrowInsetsFollowTheHUD() {
        var style = BoatStyle.standard
        style.edgeArrowClearance = 10
        style.edgeArrowInsetSide = 20
        for board in [false, true] {
            let insets = EdgeArrow.insets(safeArea: (top: 59, bottom: 34), showsLeaderboard: board, style: style)
            #expect(insets.top == 59 + HUDView.noticeTop(showsLeaderboard: board) + HUDView.noticeHeight + 10)
            #expect(insets.bottom == 34 + RaceControls.rowHeight + 10)
            #expect(insets.side == 20)
        }
        #expect(EdgeArrow.insets(safeArea: (0, 0), showsLeaderboard: true, style: style).top
                >= EdgeArrow.insets(safeArea: (0, 0), showsLeaderboard: false, style: style).top)
    }

    /// The cue fixtures (#62) draw every cue: laylines, ladder lines, your vane and the edge arrow, pinching at one
    /// tick and footing at the other, on the first beat with the fleet's backwind wedges (#377) in view. The arrow, the camera's child, is on screen where `EdgeArrow` places it,
    /// whatever the camera's zoom and turn.
    @Test func cueFixturesDrawTheArrowWhereItsPlaced() throws {
        let size = CameraRigTests.iPhone
        for (name, pinched) in [("cues", true), ("cues-footed", false)] {
            let (fixture, log) = try RenderFixture.load(named: name, in: RenderFixtureTests.fixtures)
            let session = try GameSession(fixture: fixture, log: log)
            let scene = session.scene
            scene.size = size
            let view = SKView(frame: CGRect(origin: .zero, size: size))
            view.presentScene(scene)
            scene.update(0)
            #expect(scene.cueSummary == "laylines=1 ladder=1 vane=1 arrow=1", "\(name): \(scene.cueSummary)")
            // Upwind with sails working: the fleet's backwind wedges show (#377).
            #expect(RenderFixtureTests.wedgesOnScreen(scene) >= 2, "\(name): \(RenderFixtureTests.wedgesOnScreen(scene)) wedges in view")

            let world = session.driver.renderWorld
            let reading = try #require(world.autohelm(ofSeat: world.myBoatIndex))
            #expect(pinched ? reading.offsetFromGroove < 0 : reading.offsetFromGroove > 0, "\(name)")
            let pose = BoatPose(world.me, ease: false, isGhost: false, boatClass: world.boatClass, autohelm: reading)
            #expect(pinched ? pose.luffLift > 0 : pose.sailFullness > 1, "\(name)")

            let me = world.me
            let rig = scene.rig
            let targets = EdgeArrow.targets(status: me.status, legIndex: me.legIndex, course: world.course)
            let placed = try #require(EdgeArrow.placement(targets: targets, project: { rig.project($0, sceneSize: size) },
                                                          visible: rig.visibleInsets.visibleRect(sceneSize: size)))
            #expect(rig.visibleInsets == EdgeArrow.insets(safeArea: (0, 0), showsLeaderboard: session.controls.showsLeaderboard,
                                                          style: scene.boatStyle), "\(name): the rig reads the HUD's insets")
            let arrow = try #require(scene.camera?.childNode(withName: "edgeArrow"))
            let inView = scene.convertPoint(toView: arrow.convert(.zero, to: scene))
            #expect(abs(inView.x - placed.position.x) < 0.5 && abs(inView.y - (size.height - placed.position.y)) < 0.5,
                    "\(name): arrow at \(inView) in the view, placed at \(placed.position)")
        }
    }

    /// Settings' layline and ladder toggles reach the race's controls, at launch and on a change; a fixture sets its
    /// own, or the app's defaults (laylines on, ladder lines off).
    @Test func cueTogglesReachTheScene() throws {
        var settings = DeviceSettings()
        let controls = ControlSettings(settings, launchOptions: LaunchOptions())
        #expect(controls.showsLaylines && !controls.showsLadderLines)
        settings.laylines = false
        settings.ladderLines = true
        controls.update(settings, launchOptions: LaunchOptions())
        #expect(!controls.showsLaylines && controls.showsLadderLines)

        let (prestart, log) = try RenderFixture.load(named: "prestart", in: RenderFixtureTests.fixtures)
        #expect(try GameSession(fixture: prestart, log: log).scene.cueOverride! == (laylines: true, ladderLines: false))
        let (cues, cuesLog) = try RenderFixture.load(named: "cues", in: RenderFixtureTests.fixtures)
        #expect(try GameSession(fixture: cues, log: cuesLog).scene.cueOverride! == (laylines: true, ladderLines: true))
    }

    // MARK: - Wind vane

    /// A boat with her boom `boom` sailing `sailingDegrees` off a northerly of 12 knots, the ground wind the same.
    static func boat(sailingDegrees: Double, boom: BoomSide = .port, id: Int = 1, isPlayer: Bool = false,
                     colorIndex: Int = 1) -> Boat {
        let side: Double = boom == .port ? 1 : -1
        var boat = BoatPoseTests.boat(id: id, isPlayer: isPlayer, colorIndex: colorIndex, twaDegrees: sailingDegrees)
        boat.boomSide = boom
        boat.heading = deg2rad(-side * sailingDegrees)
        return boat
    }

    static func reading(_ target: Autohelm.Target, isTapping: Bool = false, for boat: Boat) -> Autohelm.Reading {
        Autohelm(target: target, isTapping: isTapping).reading(tws: boat.polarWindSpeed(in: boatClass),
                                                               grooveTWS: boat.grooveWindSpeed(in: boatClass),
                                                               boatClass: boatClass)
    }

    /// On the groove the vane locks to the tick and there's no arc; pinching or footing, an arc runs from the tick
    /// across the autohelm's offset, on either tack. Hand steering shows the tick, never a lock or an arc.
    @Test func vaneLocksToGrooveTickArcSpansOffset() {
        let tws = metresPerSecond(knots: 12)
        let groove = Autohelm.grooveAngle(.upwind, tws: tws, boatClass: Self.boatClass)
        let grooveDegrees = rad2deg(groove)
        for boom in [BoomSide.port, .starboard] {
            let side: Double = boom == .port ? 1 : -1

            // On the groove.
            let onGroove = Self.boat(sailingDegrees: grooveDegrees + 0.5, boom: boom)
            #expect(abs(onGroove.sailingAngle - deg2rad(grooveDegrees + 0.5)) < 1e-9)
            let locked = VaneCue(onGroove, reading: Self.reading(.groove(.upwind), for: onGroove), isGhost: false,
                                 boatClass: Self.boatClass)
            #expect(locked?.isLocked == true, "\(boom)")
            #expect(locked?.vane == locked?.tick)
            #expect(abs((locked?.tick ?? 0) - side * groove) < 1e-9, "\(boom): tick on the boom's side")
            #expect(locked?.arcEnd == nil)

            // Holding the groove but well off it (a shift it's still turning through): no lock, the vane on the wind.
            let swung = Self.boat(sailingDegrees: grooveDegrees + 6, boom: boom)
            let unlocked = VaneCue(swung, reading: Self.reading(.groove(.upwind), for: swung), isGhost: false,
                                   boatClass: Self.boatClass)
            #expect(unlocked?.isLocked == false)
            #expect(abs((unlocked?.vane ?? 0) - side * deg2rad(grooveDegrees + 6)) < 1e-9, "\(boom): vane on the wind")
            #expect(unlocked?.arcEnd == nil)

            // Pinching and footing: an arc from the tick spanning the offset, to the angle held.
            for offsetDegrees in [-4.0, 6] {
                let angle = groove + deg2rad(offsetDegrees)
                let held = Self.boat(sailingDegrees: rad2deg(angle), boom: boom)
                let reading = Self.reading(.angle(angle), for: held)
                #expect(abs(reading.offsetFromGroove - deg2rad(offsetDegrees)) < 1e-9)
                let cue = VaneCue(held, reading: reading, isGhost: false, boatClass: Self.boatClass)
                #expect(cue?.isLocked == false, "\(boom) \(offsetDegrees)°")
                let end = cue?.arcEnd ?? .nan
                let tick = cue?.tick ?? .nan
                #expect(abs(wrapAngle(end - tick) - side * deg2rad(offsetDegrees)) < 1e-9, "\(boom) \(offsetDegrees)°")
                #expect(abs(end - (cue?.vane ?? .nan)) < 1e-9, "the arc ends at the vane in a steady wind")

                // Tacking, nothing; hand steering, the tick only.
                let tapping = VaneCue(held, reading: Self.reading(.angle(angle), isTapping: true, for: held), isGhost: false,
                                      boatClass: Self.boatClass)
                #expect(tapping?.arcEnd == nil && tapping?.isLocked == false)
                let hand = VaneCue(held, reading: nil, isGhost: false, boatClass: Self.holdingClass)
                #expect(hand?.arcEnd == nil && hand?.isLocked == false)
                #expect(abs((hand?.tick ?? 0) - side * groove) < 1e-9)
            }

            // Inside the dead band: no arc.
            let near = groove + deg2rad(0.5)
            let nearBoat = Self.boat(sailingDegrees: rad2deg(near), boom: boom)
            #expect(VaneCue(nearBoat, reading: Self.reading(.angle(near), for: nearBoat), isGhost: false,
                            boatClass: Self.boatClass)?.arcEnd == nil)
        }
        // A ghost, or no wind yet: no vane.
        let boat = Self.boat(sailingDegrees: grooveDegrees)
        #expect(VaneCue(boat, reading: nil, isGhost: true, boatClass: Self.boatClass) == nil)
        var calm = boat
        calm.windOverGround = .calm
        #expect(VaneCue(calm, reading: nil, isGhost: false, boatClass: Self.boatClass) == nil)
    }

    // MARK: - Sail shape

    /// Pinched, the sail's leading edge lifts and it flattens; footed, it's eased and full; on the groove (or hand
    /// steering) it's the base pose. The same for every boat in the same state.
    @Test func sailCueFollowsGrooveOffset() {
        let tws = metresPerSecond(knots: 12)
        let groove = Autohelm.grooveAngle(.upwind, tws: tws, boatClass: Self.boatClass)
        let boat = Self.boat(sailingDegrees: rad2deg(groove))
        func pose(_ reading: Autohelm.Reading?) -> BoatPose {
            BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass, autohelm: reading)
        }
        let base = pose(nil)
        let onGroove = pose(Self.reading(.groove(.upwind), for: boat))
        let pinched = pose(Self.reading(.angle(groove - deg2rad(5)), for: boat))
        let footed = pose(Self.reading(.angle(groove + deg2rad(6)), for: boat))

        #expect(onGroove == base)
        #expect(base.luffLift == 0 && base.sailFullness == 1)
        #expect(pinched.luffLift > 0)
        #expect(pinched.sailFullness < 1)
        #expect(pinched.sailTrim == base.sailTrim)
        #expect(footed.luffLift == 0)
        #expect(footed.sailTrim > base.sailTrim, "footed isn't eased")
        #expect(footed.sailFullness > 1, "footed isn't full")
        // More pinch, more lift, up to full.
        let harder = pose(Self.reading(.angle(groove - deg2rad(7)), for: boat))
        #expect(harder.luffLift > pinched.luffLift && harder.luffLift <= 1)
        // Tacking: no cue.
        #expect(pose(Self.reading(.angle(groove - deg2rad(5)), isTapping: true, for: boat)) == base)
        // Every boat alike: another id, colour and seat kind in the same state takes the same pose.
        let theirs = Self.boat(sailingDegrees: rad2deg(groove), id: 7, isPlayer: true, colorIndex: 4)
        #expect(BoatPose(theirs, ease: false, isGhost: false, boatClass: Self.boatClass,
                         autohelm: Self.reading(.angle(groove - deg2rad(5)), for: theirs)) == pinched)
    }

    /// The pinch and foot cues show only while she sails a groove: an angle held out on a reach reads against the
    /// downwind groove abaft the beam (or the upwind one forward of it), which would be a hard pinch (or foot), so
    /// past `grooveCueReachDegrees` towards the beam there's no sail cue and no arc. Pinching the downwind groove
    /// within it, and footing deeper than it, still show.
    @Test func reachAngleShowsNoGrooveCue() {
        let style = BoatStyle.standard
        let tws = metresPerSecond(knots: 12)
        let upwind = Autohelm.grooveAngle(.upwind, tws: tws, boatClass: Self.boatClass)
        let downwind = Autohelm.grooveAngle(.downwind, tws: tws, boatClass: Self.boatClass)
        func cues(_ angle: Double) -> (pose: BoatPose, base: BoatPose, arc: Double?, offset: Double) {
            let boat = Self.boat(sailingDegrees: rad2deg(angle))
            let reading = Self.reading(.angle(angle), for: boat)
            let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass, style: style, autohelm: reading)
            let base = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass, style: style, autohelm: nil)
            let vane = VaneCue(boat, reading: reading, isGhost: false, boatClass: Self.boatClass, style: style)
            return (pose, base, vane?.arcEnd, reading.offsetFromGroove)
        }
        // Reaches: beam on, either side of it, and footing well off the upwind groove.
        for degrees in [80.0, 95, 110, rad2deg(upwind) + style.grooveCueReachDegrees + 3,
                        rad2deg(downwind) - style.grooveCueReachDegrees - 3] {
            let reach = cues(deg2rad(degrees))
            #expect(abs(reach.offset) > deg2rad(style.grooveCueFullDegrees), "\(degrees)°: the reading's offset is large")
            #expect(reach.pose == reach.base, "\(degrees)°: a held reach shows a sail cue")
            #expect(reach.arc == nil, "\(degrees)°: a held reach shows the vane arc")
        }
        // Pinching the downwind groove, footing deeper than it, and footing the upwind one: within reach of a groove.
        let pinchedDown = cues(downwind - deg2rad(6))
        #expect(pinchedDown.pose.luffLift > 0 && pinchedDown.arc != nil, "pinching downwind")
        if downwind < .pi - deg2rad(8) {
            let deeper = cues(downwind + deg2rad(5))
            #expect(deeper.pose.sailFullness > 1 && deeper.arc != nil, "footing deeper downwind")
        }
        let footedUp = cues(upwind + deg2rad(6))
        #expect(footedUp.pose.sailFullness > 1 && footedUp.arc != nil, "footing upwind")
    }

    // MARK: - Steering by hand (#436)

    /// Steering by hand on a class whose autohelm doesn't hold a centred rudder (#434, ADR 0011), the vane and sail
    /// read her own angle against the groove: a pinch or foot runs an arc from the tick to her angle, on the groove
    /// she locks to the tick, and the sail pinches and foots as the autohelm's would. A tap (the autohelm has her)
    /// shows none; on a class whose autohelm holds, a held rudder shows the tick only, as before. The sail's angle of
    /// attack (the sim's, #377) leaves the cue out either way.
    @Test func handSteeredPinchShowsArc() {
        var hand = Self.boatClass
        hand.steering.autohelm.holdsWhenCentred = false
        let groove = Autohelm.grooveAngle(.upwind, tws: metresPerSecond(knots: 12), boatClass: hand)
        let grooveDegrees = rad2deg(groove)
        for boom in [BoomSide.port, .starboard] {
            let side: Double = boom == .port ? 1 : -1
            for offsetDegrees in [-4.0, 6, 2] {
                let boat = Self.boat(sailingDegrees: grooveDegrees + offsetDegrees, boom: boom)
                let cue = VaneCue(boat, reading: nil, isGhost: false, boatClass: hand)
                #expect(cue?.isLocked == false, "\(boom) \(offsetDegrees)°")
                let tick = cue?.tick ?? .nan, end = cue?.arcEnd ?? .nan
                #expect(abs(tick - side * groove) < 1e-9, "\(boom): the tick stays the groove")
                #expect(abs(wrapAngle(end - tick) - side * deg2rad(offsetDegrees)) < 1e-9, "\(boom) \(offsetDegrees)°")
                #expect(abs(end - (cue?.vane ?? .nan)) < 1e-9, "the arc ends at the vane in a steady wind")

                let tapping = VaneCue(boat, reading: Self.reading(.groove(.upwind), isTapping: true, for: boat),
                                      isGhost: false, boatClass: hand)
                #expect(tapping?.arcEnd == nil && tapping?.isLocked == false, "a tap's turn shows nothing")
                let held = VaneCue(boat, reading: nil, isGhost: false, boatClass: Self.holdingClass)
                #expect(held?.arcEnd == nil && held?.isLocked == false, "the autohelm on: a held rudder, the tick only")
            }
            // On the groove by hand: locked to the tick, no arc.
            let onGroove = Self.boat(sailingDegrees: grooveDegrees - 1, boom: boom)
            let locked = VaneCue(onGroove, reading: nil, isGhost: false, boatClass: hand)
            #expect(locked?.isLocked == true && locked?.vane == locked?.tick && locked?.arcEnd == nil, "\(boom)")
        }
        // The lock window and the deadband: just inside the lock, locked with no arc; just outside it, an arc.
        let style = BoatStyle.standard
        #expect(style.vaneLockDegrees >= style.grooveCueDeadbandDegrees)
        for sign in [-1.0, 1] {
            let inside = VaneCue(Self.boat(sailingDegrees: grooveDegrees + sign * (style.vaneLockDegrees - 0.1)),
                                 reading: nil, isGhost: false, boatClass: hand)
            #expect(inside?.isLocked == true && inside?.arcEnd == nil, "\(sign): inside the lock")
            let outside = VaneCue(Self.boat(sailingDegrees: grooveDegrees + sign * (style.vaneLockDegrees + 0.1)),
                                  reading: nil, isGhost: false, boatClass: hand)
            #expect(outside?.isLocked == false && outside?.arcEnd != nil, "\(sign): past the lock, past the deadband")
        }
        // The reach rule: footing past `grooveCueReachDegrees` off the upwind groove towards the beam, no arc.
        let reach = VaneCue(Self.boat(sailingDegrees: grooveDegrees + style.grooveCueReachDegrees + 3),
                            reading: nil, isGhost: false, boatClass: hand)
        #expect(reach?.isLocked == false && reach?.arcEnd == nil, "a reach by hand shows no arc")
        let inReach = VaneCue(Self.boat(sailingDegrees: grooveDegrees + style.grooveCueReachDegrees - 3),
                              reading: nil, isGhost: false, boatClass: hand)
        #expect(inReach?.arcEnd != nil, "footing within reach of the groove shows the arc")
        // Downwind by hand: pinching up from the downwind groove runs the arc the same way.
        let downwind = Autohelm.grooveAngle(.downwind, tws: metresPerSecond(knots: 12), boatClass: hand)
        for boom in [BoomSide.port, .starboard] {
            let side: Double = boom == .port ? 1 : -1
            let cue = VaneCue(Self.boat(sailingDegrees: rad2deg(downwind) - 6, boom: boom), reading: nil,
                              isGhost: false, boatClass: hand)
            #expect(cue?.isLocked == false && abs((cue?.tick ?? .nan) - wrapAngle(side * downwind)) < 1e-9, "\(boom)")
            let arc = wrapAngle((cue?.arcEnd ?? .nan) - (cue?.tick ?? .nan))
            #expect(abs(arc - side * deg2rad(-6)) < 1e-9, "\(boom): a downwind pinch by hand")
        }

        // The sail: pinched and footed by hand as by the autohelm holding that angle; on a reach, nothing.
        func pose(_ degrees: Double, _ boatClass: BoatClass, autohelm: Bool = false) -> BoatPose {
            let boat = Self.boat(sailingDegrees: degrees)
            let reading = autohelm ? Self.reading(.angle(deg2rad(degrees)), for: boat) : nil
            return BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass, autohelm: reading)
        }
        let pinched = pose(grooveDegrees - 5, hand), footed = pose(grooveDegrees + 6, hand)
        #expect(pinched.luffLift > 0 && pinched == pose(grooveDegrees - 5, Self.holdingClass, autohelm: true))
        #expect(footed.sailFullness > 1 && footed == pose(grooveDegrees + 6, Self.holdingClass, autohelm: true))
        #expect(pose(grooveDegrees + 6, Self.holdingClass).sailFullness == 1, "the autohelm on: a held rudder, no sail cue")
        #expect(pose(95, hand) == pose(95, Self.holdingClass), "a reach by hand shows no sail cue")
        #expect(pose(grooveDegrees, hand) == pose(grooveDegrees, Self.holdingClass), "on the groove, the base pose")
        // A tap on a hand class: the autohelm has her, so the sail reads its reading as on any class.
        let tapBoat = Self.boat(sailingDegrees: grooveDegrees + 6)
        let tap = Self.reading(.groove(.upwind), isTapping: true, for: tapBoat)
        #expect(BoatPose(tapBoat, ease: false, isGhost: false, boatClass: hand, autohelm: tap)
                == BoatPose(tapBoat, ease: false, isGhost: false, boatClass: Self.holdingClass, autohelm: tap))
        let footedBoat = Self.boat(sailingDegrees: grooveDegrees + 6)
        #expect(BoatPose.angleOfAttack(footedBoat, ease: false, boatClass: hand)
                == BoatPose.angleOfAttack(footedBoat, ease: false, boatClass: Self.holdingClass))
    }

    // MARK: - Ladder lines

    /// The ladder lines lie across the course axis, `spacing` apart from the windward mark, whatever the live wind
    /// (they take none); on the reach, across the leg.
    @Test func ladderLinesLieAcrossTheAxis() throws {
        let course = try Self.course()
        let up = course.upwind
        let windward = course.targetPosition(for: .round(CourseLayout.windwardIndex))
        for leg in [CourseLayout.Leg.round(CourseLayout.windwardIndex), .round(CourseLayout.gateIndex)] {
            let lines = LadderCue.segments(for: leg, in: course, centre: windward + up * -230, radius: 400, spacing: 100)
            #expect(lines.count >= 7, "\(leg): \(lines.count)")
            for line in lines {
                #expect(abs((line.to - line.from).normalized.dot(up)) < 1e-9, "\(leg): not across the axis")
                // A whole number of spacings up the axis from the windward mark.
                let rungs = (line.from - windward).dot(up) / 100
                #expect(abs(rungs - rungs.rounded()) < 1e-9)
            }
        }
        // The reach: across the leg, from its mark.
        let reach = CourseLayout.Leg.round(CourseLayout.offsetIndex)
        let step = LadderCue.step(for: reach, in: course)
        let offsetMark = course.targetPosition(for: reach)
        let run = offsetMark - windward
        if abs(run.dot(up.rightPerp)) > abs(run.dot(up)) {
            #expect((step.along - run.normalized).length < 1e-9 && step.anchor == offsetMark)
            for line in LadderCue.segments(for: reach, in: course, centre: offsetMark, radius: 300, spacing: 100) {
                #expect(abs((line.to - line.from).normalized.dot(run.normalized)) < 1e-9)
            }
        } else {
            #expect((step.along - up).length < 1e-9)
        }
        #expect(LadderCue.segments(for: reach, in: course, centre: offsetMark, radius: 1000, spacing: 1).count
                <= LadderCue.maxLines)
    }
}
