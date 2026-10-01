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
        let visible = EdgeArrow.visibleRect(sceneSize: size, style: style)
        #expect(visible.minY == CGFloat(style.edgeArrowInsetBottom) && visible.minX == CGFloat(style.edgeArrowInsetSide))
        #expect(abs(visible.maxY - (size.height - CGFloat(style.edgeArrowInsetTop))) < 1e-9)
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
                    #expect((placed == nil) == visible.contains(p), "\(mode) mark at \(p)")
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

    /// What the arrow points at: the start line's centre before the start, or its end that's off screen in the
    /// pre-start shot (`CameraRig.lineEndOffScreen`); the leg's mark racing, a gate's and the finish line's centre;
    /// nothing once finished.
    @Test func edgeArrowTargetsTheMarkYouSailFor() throws {
        let course = try Self.course()
        let line = course.startLine
        #expect(EdgeArrow.targets(status: .prestart, legIndex: 0, course: course, lineEndOffScreen: false) == [line.centre])
        #expect(EdgeArrow.targets(status: .ocs, legIndex: 0, course: course, lineEndOffScreen: false) == [line.centre])
        #expect(EdgeArrow.targets(status: .prestart, legIndex: 0, course: course, lineEndOffScreen: true)
                == [line.pin.position, line.committee.position])
        for (k, leg) in course.legs.enumerated() {
            #expect(EdgeArrow.targets(status: .racing, legIndex: k, course: course, lineEndOffScreen: false)
                    == [course.targetPosition(for: leg)])
        }
        let gate = course.marksOfLeg(.round(CourseLayout.gateIndex)).map(\.position)
        #expect(gate.count == 2)
        #expect((course.targetPosition(for: .round(CourseLayout.gateIndex)) - (gate[0] + gate[1]) / 2).length < 1e-6)
        #expect(EdgeArrow.targets(status: .finished, legIndex: 0, course: course, lineEndOffScreen: false).isEmpty)
        #expect(EdgeArrow.targets(status: .dsq, legIndex: 0, course: course, lineEndOffScreen: false).isEmpty)

        // Of a line's two ends, the arrow points at the one off screen; both off, at the line's middle.
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100)
        let project: (Vec2) -> CGPoint = { CGPoint(x: $0.x, y: $0.y) }
        let oneOff = EdgeArrow.placement(targets: [Vec2(50, 50), Vec2(300, 50)], project: project, visible: visible)
        #expect(oneOff?.position == CGPoint(x: 100, y: 50) && oneOff?.angle == 0)
        let bothOff = EdgeArrow.placement(targets: [Vec2(-100, 250), Vec2(200, 250)], project: project, visible: visible)
        #expect(abs(Double(bothOff?.angle ?? 0) - .pi / 2) < 1e-9)
        #expect(EdgeArrow.placement(targets: [Vec2(20, 50), Vec2(80, 50)], project: project, visible: visible) == nil)
    }

    /// The cue fixtures (#62) draw every cue: laylines, ladder lines, your vane and the edge arrow, pinching at one
    /// tick and footing at the other. The arrow, the camera's child, is on screen where `EdgeArrow` places it,
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

            let world = session.driver.renderWorld
            let reading = try #require(world.autohelm(ofSeat: world.myBoatIndex))
            #expect(pinched ? reading.offsetFromGroove < 0 : reading.offsetFromGroove > 0, "\(name)")
            let pose = BoatPose(world.me, ease: false, isGhost: false, boatClass: world.boatClass, autohelm: reading)
            #expect(pinched ? pose.luffLift > 0 : pose.sailFullness > 1, "\(name)")

            let me = world.me
            let rig = scene.rig
            let targets = EdgeArrow.targets(status: me.status, legIndex: me.legIndex, course: world.course,
                                            lineEndOffScreen: rig.lineEndOffScreen)
            let placed = try #require(EdgeArrow.placement(targets: targets, project: { rig.project($0, sceneSize: size) },
                                                          visible: EdgeArrow.visibleRect(sceneSize: size, style: .standard)))
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
                let hand = VaneCue(held, reading: nil, isGhost: false, boatClass: Self.boatClass)
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
