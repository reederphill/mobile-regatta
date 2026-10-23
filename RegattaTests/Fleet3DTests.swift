import SceneKit
import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The standing fleet (#596, #597): every boat's hull, rig and sail, the buoys and the committee boat, in one
/// SceneKit scene. Pure checks on the SCN nodes' state.
@MainActor @Suite struct Fleet3DTests {
    static let style = BoatStyle.standard

    static func boat3D() -> Boat3D {
        Boat3D(geometry: Boat3D.Geometry(boatClass: WakeTests.boatClass, ppm: 8), color: .red, seat: 1)
    }

    /// A ghost (#30) draws every material at `ghostAlpha` with her sail hanging limp (`ghostSailBelly`); seated
    /// again she is opaque.
    @Test func aGhostFadesWithALimpSail() {
        let boat = WakeTests.boat(speed: 6)
        var pose = BoatPose(boat, ease: false, isGhost: true, boatClass: WakeTests.boatClass, style: Self.style)
        pose.flutter = 1
        let drawn = Self.boat3D()
        drawn.update(pose: pose, style: Self.style, x: 0, z: 0, yaw: 0, time: 2, dt: 0, settled: true)
        #expect(drawn.transparency.allSatisfy { abs($0 - CGFloat(Self.style.ghostAlpha)) < 1e-6 }, "\(drawn.transparency)")
        #expect(abs(abs(drawn.sailLook.belly) - Float(Self.style.ghostSailBelly)) < 1e-5)
        pose.isGhost = false
        drawn.update(pose: pose, style: Self.style, x: 0, z: 0, yaw: 0, time: 2, dt: 0, settled: true)
        #expect(drawn.transparency.allSatisfy { $0 == 1 })
        // A ghost never drops sail detail, however far.
        pose.isGhost = true
        let far = Self.boat3D()
        far.update(pose: pose, style: Self.style, x: 0, z: 0, yaw: 0, sailDetail: .farReduced, hullsFromYou: 50,
                   time: 2, dt: 0, settled: true)
        #expect(far.sailDetailShare == 1)
    }

    /// At the serious tier (`SailDetail.farReduced`) the boats far from yours draw no sail detail, yours and the near
    /// ones all of it; at nominal every boat does. Nothing else the fleet draws moves with the tier.
    @Test func farBoatsDropTheirSailDetailAndNothingElse() throws {
        let (scene, session) = try GameSceneTests.scene(fixture: "fleet")
        let fleet = try #require(scene.standingFleet)
        let world = session.driver.renderWorld
        let hull = world.boatClass.hull.length
        let distances = world.boats.map { ($0.position - world.me.position).length / hull }
        let nominal = fleet.fleet.map(\.standingLook)
        #expect(fleet.fleet.allSatisfy { $0.sailDetailShare == 1 })

        scene.apply(RenderQualityPolicy(thermalState: .serious, lowPower: false, maxFPS: 60))
        scene.update(0)
        for (seat, boat) in fleet.fleet.enumerated() {
            let far = seat != world.myBoatIndex && distances[seat] > Self.style.farBoatHulls && !world.isGhost(ofSeat: seat)
            #expect(boat.sailDetailShare == (far ? 0 : 1), "seat \(seat) at \(distances[seat]) hulls")
        }
        #expect(distances.contains { $0 > Self.style.farBoatHulls }, "the fleet fixture has no far boat")
        #expect(fleet.fleet.map(\.standingLook) == nominal, "the hulls, heel or rig moved with the tier")
    }

    /// `-cuesOnly` (#127's UI test) hides every sail and boom; the hulls still stand.
    @Test func cuesOnlyHidesEverySail() throws {
        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let fleet = try #require(scene.standingFleet)
        #expect(fleet.fleet.allSatisfy { !$0.sailLook.isHidden && !$0.sailLook.boomIsHidden })
        scene.drawsCuesOnly = true
        scene.update(0)
        #expect(fleet.fleet.allSatisfy { $0.sailLook.isHidden && $0.sailLook.boomIsHidden })
    }

    /// With the sails hidden (`-cuesOnly`) the boom is hidden too and sits at its trim with no flutter or luff
    /// shiver, so a far boat at `.farReduced` draws her rig the same as a near one or the full tier: nothing hidden
    /// moves with the thermal tier (#597).
    @Test func hiddenSailsDrawTheSameRigAtEveryTier() {
        let boat = WakeTests.boat(speed: 6)
        var pose = BoatPose(boat, ease: false, isGhost: false, boatClass: WakeTests.boatClass, style: Self.style)
        pose.flutter = 1
        pose.luffLift = 1
        func drawn(_ detail: SailDetail, hulls: Double, hidesSail: Bool) -> Boat3D {
            let drawn = Self.boat3D()
            drawn.update(pose: pose, style: Self.style, x: 0, z: 0, yaw: 0, sailDetail: detail, hullsFromYou: hulls,
                         hidesSail: hidesSail, time: 1.3, dt: 0, settled: true)
            return drawn
        }
        let side: Float = pose.sailSide == .port ? -1 : 1
        let trim = Float(pose.sailTrim) * side
        // Shown, the near boat flutters and the far one doesn't: the tier shows.
        #expect(abs(drawn(.farReduced, hulls: 2, hidesSail: false).sailLook.boom
                    - drawn(.farReduced, hulls: 20, hidesSail: false).sailLook.boom) > 1e-3)

        let far = drawn(.farReduced, hulls: 20, hidesSail: true)
        #expect(far.sailLook.isHidden && far.sailLook.boomIsHidden)
        #expect(abs(far.sailLook.boom - trim) < 1e-5)
        for near in [drawn(.farReduced, hulls: 2, hidesSail: true), drawn(.full, hulls: 20, hidesSail: true),
                     drawn(.farReduced, hulls: 0, hidesSail: true)] {
            #expect(near.sailLook.boom == far.sailLook.boom, "the hidden boom's turn moved with the tier")
            #expect(near.standingLook == far.standingLook)
        }
    }

    /// The buoys take the chart's tones each frame (#15): the active leg's marks orange, the rest grey, the pin
    /// with the line; the committee boat is white. `-hideScene` hides the whole SK3DNode.
    @Test func buoysTakeTheChartsTones() throws {
        let (scene, session) = try GameSceneTests.scene(fixture: "cues")
        let fleet = try #require(scene.standingFleet)
        let world = session.driver.renderWorld
        let me = world.me, course = world.course
        let leg = ChartMarks.leg(in: course, status: me.status, legIndex: me.legIndex)
        let expected = ChartMarks.buoys(of: course).map {
            ChartMarks.tone(of: $0.mark, in: course, status: me.status, legIndex: me.legIndex).uiColor
        } + [ChartMarks.tone(isActive: ChartMarks.isLineActive(status: me.status, leg: leg)).uiColor]
        #expect(fleet.buoyTones == expected)
        #expect(fleet.buoyTones.contains(CuePalette.orange.uiColor) || fleet.buoyTones.contains(ChartMarks.tone(isActive: true).uiColor))
        var white: CGFloat = 0
        #expect(fleet.committeeColor?.getWhite(&white, alpha: nil) == true && white > 0.9)

        let node = try #require(scene.camera?.childNode(withName: "fleet3D"))
        #expect(!node.isHidden)
        scene.paintsWorld = false
        #expect(node.isHidden)
    }
}
