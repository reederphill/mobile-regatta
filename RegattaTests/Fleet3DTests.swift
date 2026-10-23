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

    /// `-cuesOnly` (#127's UI test) hides every sail; the hulls still stand.
    @Test func cuesOnlyHidesEverySail() throws {
        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let fleet = try #require(scene.standingFleet)
        #expect(fleet.fleet.allSatisfy { !$0.sailLook.isHidden })
        scene.drawsCuesOnly = true
        scene.update(0)
        #expect(fleet.fleet.allSatisfy { $0.sailLook.isHidden })
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
