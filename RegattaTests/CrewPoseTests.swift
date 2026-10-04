import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The skiff's two sailors (#120): out on the wire when powered, in when light or eased, across the boat on every
/// tack and gybe and ducking under the boom on a gybe, all from sim state only and the same for every boat.
@MainActor @Suite struct CrewPoseTests {
    static let style = BoatStyle.standard
    static let boatClass = Race.defaultBoatClass

    /// A boat at `twa` degrees off a northerly of `knots`, her boom on `boom` (to leeward: heading to port of the
    /// wind with the boom to port).
    static func boat(id: Int = 1, colorIndex: Int = 1, twa: Double, boom: BoomSide = .port, knots: Double = 16,
                     planing: Bool = false, tacking: Bool = false, crossingTick: Int? = nil) -> Boat {
        var boat = BoatPoseTests.boat(id: id, colorIndex: colorIndex, twaDegrees: twa, windKnots: knots)
        boat.heading = deg2rad(boom == .port ? -twa : twa)
        boat.boomSide = boom
        boat.apparentWind = Wind(direction: deg2rad(boom == .port ? -twa : twa) * 0.7,
                                 speed: metresPerSecond(knots: knots * 1.2))
        boat.isPlaning = planing
        boat.isTacking = tacking
        boat.tackCrossingTick = crossingTick
        return boat
    }

    static func target(_ boat: Boat, ease: Bool = false, isGhost: Bool = false) -> CrewTarget {
        CrewTarget(boat, pose: BoatPose(boat, ease: ease, isGhost: isGhost, boatClass: boatClass, style: style),
                   style: style)
    }

    /// A posture's name, for comparing sequences.
    static func kind(_ posture: CrewPosture) -> String {
        switch posture {
        case .out: "out"
        case .sittingIn: "in"
        case .ducking: "duck"
        case .crossing: "cross"
        }
    }

    /// A tack: out to windward, in as she comes head to wind, across the boat from her boom's crossing, then out on
    /// the new side once close-hauled, though the race still has her tacking.
    @Test func tackCrossesTheBoat() {
        var timer = CrewTimer()
        let steps: [(time: Double, boat: Boat)] = [
            (0, Self.boat(twa: 45)),
            (1, Self.boat(twa: 10)),
            (1.5, Self.boat(twa: 3, boom: .starboard, tacking: true, crossingTick: 45)),
            (1.9, Self.boat(twa: 20, boom: .starboard, tacking: true, crossingTick: 45)),
            (1.5 + Self.style.crewCrossSeconds + 0.1, Self.boat(twa: 42, boom: .starboard, tacking: true, crossingTick: 45)),
        ]
        let poses = steps.map { timer.advance(Self.target($0.boat), time: $0.time, style: Self.style) }
        #expect(poses.map { Self.kind($0.posture) } == ["out", "in", "cross", "cross", "out"])
        #expect(poses.map(\.side) == [.starboard, .starboard, .port, .port, .port])
        #expect(timer.manoeuvre == nil)
    }

    /// A gybe: out on the run on the plane, then ducking under the boom, then across, then out on the new side.
    @Test func gybeDucksThenCrosses() {
        var timer = CrewTimer()
        let duck = Self.style.crewDuckSeconds, cross = Self.style.crewCrossSeconds
        let before = Self.boat(twa: 160, planing: true)
        let after = Self.boat(twa: 160, boom: .starboard, planing: true)
        let steps: [(time: Double, boat: Boat)] = [
            (0, before), (0.5, before), (1, after), (1 + duck / 2, after), (1 + duck + cross / 2, after),
            (1 + duck + cross + 0.1, after),
        ]
        let poses = steps.map { timer.advance(Self.target($0.boat), time: $0.time, style: Self.style) }
        #expect(poses.map { Self.kind($0.posture) } == ["out", "out", "duck", "duck", "cross", "out"])
        #expect(poses.map(\.side) == [.starboard, .starboard, .port, .port, .port, .port])
        // Ducking, they crouch on the old side; crossing, they go over to the new.
        let ducked = SailorPlacement.placements(poses[3], beam: 1.8, length: 4.9, heel: 0, style: Self.style)
        #expect(ducked.allSatisfy { $0.hip.x > 0 && $0.reach == Self.style.crewDuckReach })
        let out = SailorPlacement.placements(poses[5], beam: 1.8, length: 4.9, heel: 0, style: Self.style)
        #expect(out.allSatisfy { $0.hip.x < 0 && $0.facing == -1 })
    }

    /// Light air, eased sheets and a ghost all sit in; eased sits in even on the plane.
    @Test func sitsInWhenLightEasedOrAGhost() {
        let poses = [
            CrewTimer.settled(Self.target(Self.boat(twa: 45, knots: 7)), time: 0, style: Self.style),
            CrewTimer.settled(Self.target(Self.boat(twa: 45), ease: true), time: 0, style: Self.style),
            CrewTimer.settled(Self.target(Self.boat(twa: 140, planing: true), ease: true), time: 0, style: Self.style),
            CrewTimer.settled(Self.target(Self.boat(twa: 90), isGhost: true), time: 0, style: Self.style),
        ]
        #expect(poses.allSatisfy { $0.posture == .sittingIn })
        #expect(Self.kind(CrewTimer.settled(Self.target(Self.boat(twa: 90)), time: 0, style: Self.style).posture) == "out")
    }

    /// Heel is nothing dead downwind, so planing counts as power: a planing skiff's crew stays out on a run.
    @Test func planingKeepsThemOutOnARun() {
        let slow = CrewTimer.settled(Self.target(Self.boat(twa: 178)), time: 0, style: Self.style)
        let planing = CrewTimer.settled(Self.target(Self.boat(twa: 178, planing: true)), time: 0, style: Self.style)
        #expect(slow.posture == .sittingIn)
        #expect(Self.kind(planing.posture) == "out")
    }

    /// Power between the in and out thresholds never flickers them: out stays out, in stays in.
    @Test func hysteresisDoesNotFlicker() {
        var timer = CrewTimer()
        var target = Self.target(Self.boat(twa: 45))
        let between = (Self.style.crewInPower + Self.style.crewOutPower) / 2
        var kinds: [String] = []
        for (i, power) in [0.3, between, 0.05, between, Self.style.crewOutPower + 0.01].enumerated() {
            target.power = power
            kinds.append(Self.kind(timer.advance(target, time: Double(i), style: Self.style).posture))
        }
        #expect(kinds == ["out", "out", "in", "in", "out"])
    }

    /// A tack drawn settled at any tick (a frozen fixture) is the tack drawn live through it, frame by frame:
    /// the crossing is timed from her boom's crossing tick. Time running backwards snaps to the settled pose.
    @Test func settledTackMatchesLive() {
        var timer = CrewTimer()
        for tick in 0...120 {
            let time = Double(tick) / Double(Race.tickRate)
            let boat = tick < 30 ? Self.boat(twa: tick < 20 ? 45 : 8)
                : Self.boat(twa: 30, boom: .starboard, tacking: tick < 90, crossingTick: tick < 90 ? 30 : nil)
            let target = Self.target(boat)
            let live = timer.advance(target, time: time, style: Self.style)
            #expect(live == CrewTimer.settled(target, time: time, style: Self.style), "tick \(tick)")
        }
        let back = Self.target(Self.boat(twa: 8, boom: .starboard, tacking: true, crossingTick: 30))
        #expect(timer.advance(back, time: 1.2, style: Self.style)
                == CrewTimer.settled(back, time: 1.2, style: Self.style))
    }

    /// The same state draws the same crew whatever her seat, colour or whether she is yours (#22).
    @Test func sameForEveryBoat() {
        for twa in [10.0, 45, 90, 160] {
            for planing in [false, true] {
                let a = Self.target(Self.boat(id: 0, colorIndex: 0, twa: twa, planing: planing))
                let b = Self.target(Self.boat(id: 7, colorIndex: 9, twa: twa, planing: planing))
                #expect(a == b)
                #expect(CrewTimer.settled(a, time: 3, style: Self.style) == CrewTimer.settled(b, time: 3, style: Self.style))
            }
        }
    }

    /// The far tier (#127's seam): no sailors and a still sail, but the same heel, drop shadow and boom side and
    /// trim as the full tier. Only the skiff carries sailors.
    @Test func reducedTierKeepsHeelAndBoom() throws {
        for (twa, ease) in [(45.0, false), (90, true), (150, false)] {
            let boat = Self.boat(twa: twa)
            let pose = BoatPose(boat, ease: ease, isGhost: false, boatClass: Self.boatClass, style: Self.style)
            let nodes = [CrewDetail.full, .reduced].map { detail in
                let node = BoatNode(boat: boat, isMine: false, color: .red, boatClass: Self.boatClass,
                                    pointsPerMeter: GameScene.pointsPerMeter)
                node.update(with: boat, pose: pose, style: Self.style, crewDetail: detail, time: 1.3, dt: 0,
                            settled: true)
                return node
            }
            let full = nodes[0].heelAndBoom, reduced = nodes[1].heelAndBoom
            #expect(full.hullXScale == reduced.hullXScale && full.shadow == reduced.shadow
                    && full.shadowAlpha == reduced.shadowAlpha && full.sail == reduced.sail
                    && full.sailSide == reduced.sailSide, "twa \(twa)")
            #expect(nodes[0].sailorsShown)
            #expect(!nodes[1].sailorsShown)
        }
        let dinghy = try BoatClassFile.bundled(id: "ilca-dinghy", version: 4).content
        let node = BoatNode(boat: Self.boat(twa: 45), isMine: false, color: .red, boatClass: dinghy,
                            pointsPerMeter: GameScene.pointsPerMeter)
        #expect(node.sailorSprites.isEmpty && !node.sailorsShown)
        #expect(CrewTable.sailors(in: Self.boatClass) == 2)
    }

    /// The fleet's sailors share one aid and one helmet texture, four sprites a boat and no shapes, so 16 boats
    /// add 64 sprites that batch (#22's per-frame load).
    @Test func fleetSailorsShareTextures() throws {
        let (scene, boats) = try DrawOrderTests.scene(fixture: "fleet")
        var nodes: [BoatNode] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let boat = node as? BoatNode { nodes.append(boat) }
        }
        #expect(nodes.count == boats)
        let sprites = nodes.map(\.sailorSprites)
        #expect(sprites.allSatisfy { $0.count == 4 })
        let aid = try #require(sprites.first?.first?.texture), helmet = try #require(sprites.first?[1].texture)
        #expect(sprites.allSatisfy { $0[0].texture === aid && $0[2].texture === aid })
        #expect(sprites.allSatisfy { $0[1].texture === helmet && $0[3].texture === helmet })
    }

    /// The crew-tack render fixtures (#62) at their four ticks round seat 0's first tack in the fleet log: out on
    /// the old side, in head to wind, crossing just after the boom, out on the new side. Pinned here because logs
    /// replay with any simulation version, and a revision that moved the tack would otherwise show only as a render
    /// diff.
    @Test func crewTackFixturesShowTheTack() throws {
        var poses: [CrewPose] = []
        for n in 1...4 {
            let (fixture, log) = try RenderFixture.load(named: "crew-tack-\(n)", in: RenderFixtureTests.fixtures)
            #expect(fixture.log == "fleet.racelog.json")
            let driver = try FixtureDriver(log: log, freezeTick: fixture.freezeTick)
            let world = driver.renderWorld
            let seat = driver.myBoatIndex
            let boat = world.boats[seat]
            let pose = BoatPose(boat, ease: world.ease(ofSeat: seat), isGhost: world.isGhost(ofSeat: seat),
                                boatClass: world.boatClass, style: Self.style)
            poses.append(CrewTimer.settled(CrewTarget(boat, pose: pose, style: Self.style), time: world.time,
                                           style: Self.style))
        }
        #expect(poses.map { Self.kind($0.posture) } == ["out", "in", "cross", "out"])
        #expect(poses.map(\.side) == [.starboard, .starboard, .port, .port])
    }
}
