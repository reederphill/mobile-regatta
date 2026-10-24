import CoreGraphics
import Testing
import RegattaCore
@testable import Regatta

/// The kite through a gybe (#311, design gate rounds 3 and 4): one set animation with the boom. It swings on the main's
/// own clock, crossing her centreline as the boom does and landing as it lands; only its angle and depth change, its
/// length fixed. It is never a sliver (its depth never under the floor, its belly flipping sides at the centreline
/// without passing through flat) and never sheeted harder than the main.
@MainActor struct KiteGybeTests {
    static let boatClass = Race.defaultBoatClass

    private static func pose(side: BoomSide, sailTrim: Double, kiteTrim: Double, flutter: Double = 0,
                             kiteFlutter: Double = 0, fill: Double = 1) -> (Boat, BoatPose) {
        let boat = WakeTests.boat(speed: 6)
        var pose = BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass)
        pose.sailSide = side
        pose.sailTrim = sailTrim
        pose.flutter = flutter
        pose.luffLift = 0
        pose.spinnaker = SpinnakerPose(phase: .up, hoisted: 1, side: side, trim: kiteTrim, fill: fill,
                                       flutter: kiteFlutter)
        return (boat, pose)
    }

    static func node() -> Boat3D {
        Boat3D(geometry: Boat3D.Geometry(boatClass: boatClass, ppm: 8), color: .red, seat: 1)
    }

    @Test func kiteSwingsAcrossWithTheBoom() throws {
        try #require(Self.boatClass.spinnaker != nil, "the default class flies a kite")
        let sailTrim = 1.0, kiteTrim = 1.3
        let (_, port) = Self.pose(side: .port, sailTrim: sailTrim, kiteTrim: kiteTrim)
        let node = Self.node()
        node.update(pose: port, style: .standard, x: 0, z: 0, yaw: 0, time: 0, dt: 0, settled: true)
        let settled = try #require(node.kiteLook)
        #expect(abs(settled.angle + Float(kiteTrim)) < 1e-5, "settled on port")

        let (_, starboard) = Self.pose(side: .starboard, sailTrim: sailTrim, kiteTrim: kiteTrim)
        var crossed = false
        for frame in 1...90 {
            node.update(pose: starboard, style: .standard, x: 0, z: 0, yaw: 0, time: Double(frame) / 30,
                        dt: 1.0 / 30, settled: false)
            let kite = try #require(node.kiteLook), sail = node.sailLook.boom
            // The same share of the way across as the main, every frame: they start, cross and land together.
            #expect(abs(kite.angle - sail * Float(kiteTrim / sailTrim)) < 0.006, "frame \(frame)")
            #expect((kite.angle > 0) == (sail > 0), "frame \(frame): on the boom's side")
            #expect(kite.size == 1, "frame \(frame): its size never changes")
            #expect(abs(abs(kite.depth) - 1) < 1e-5, "frame \(frame): full depth through the crossing")
            #expect((kite.depth > 0) == (sail > 0), "frame \(frame): the belly faces the boom's side")
            crossed = crossed || sail > 0
        }
        #expect(crossed)
        let landed = try #require(node.kiteLook)
        #expect(abs(landed.angle - Float(kiteTrim)) < 1e-5, "landed full on starboard with the boom")
        #expect(abs(landed.depth - 1) < 1e-5)
    }

    /// Sweep: kite and main trims either way round, both gybes, flogging or not, soft to full. Every frame the kite's
    /// angle off the centreline on its side is at least the drawn main's, and its depth at least the floor.
    @Test func neverSheetedHarderThanTheMainNorASliver() throws {
        try #require(Self.boatClass.spinnaker != nil, "the default class flies a kite")
        let style = BoatStyle.standard
        let floor = Float(style.kiteDepthFloor)
        #expect(style.kiteDepthFloor >= 0.25, "the floor is well above flat")
        var frames = 0
        for (sailTrim, kiteTrim) in [(1.0, 1.3), (1.3, 1.0), (1.4, 0.4), (0.6, 0.6), (1.5, 1.5)] {
            for (from, to) in [(BoomSide.port, BoomSide.starboard), (.starboard, .port)] {
                for (flutter, kiteFlutter, fill) in [(0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.1), (1.0, 1.0, 0.5)] {
                    let (_, before) = Self.pose(side: from, sailTrim: sailTrim, kiteTrim: kiteTrim, flutter: flutter,
                                                   kiteFlutter: kiteFlutter, fill: fill)
                    let (_, after) = Self.pose(side: to, sailTrim: sailTrim, kiteTrim: kiteTrim, flutter: flutter,
                                               kiteFlutter: kiteFlutter, fill: fill)
                                let node = Self.node()
                    node.update(pose: before, style: style, x: 0, z: 0, yaw: 0, time: 0, dt: 0, settled: true)
                    for frame in 0..<150 {
                        let pose = frame < 30 ? before : after
                        node.update(pose: pose, style: style, x: 0, z: 0, yaw: 0, time: Double(frame) / 30,
                                    dt: 1.0 / 30, settled: false)
                        let kite = try #require(node.kiteLook), sail = node.sailLook.boom
                        let side: Float = kite.depth < 0 ? -1 : 1
                        let label = "sail \(sailTrim) kite \(kiteTrim) \(from)→\(to) flutter \(flutter)/\(kiteFlutter) fill \(fill) frame \(frame)"
                        #expect(kite.angle * side >= sail * side - 1e-6, "\(label): kite inside the main")
                        #expect(abs(kite.depth) >= floor - 1e-5, "\(label): a sliver")
                        #expect(kite.size == 1, "\(label)")
                        frames += 1
                    }
                }
            }
        }
        #expect(frames == 5 * 2 * 4 * 150)
    }

    /// Its depth grows the further downwind she sails, shallowest on a reach and deepest on a dead run, and no state
    /// (soft, collapsed, hoisting, dropping) takes it under the floor. Its trim stands outside the main's.
    @Test func depthBillowsDownwindAboveTheFloor() throws {
        let boatClass = Self.boatClass
        let tuning = try #require(boatClass.spinnaker)
        let style = BoatStyle.standard
        func boat(twaDegrees: Double, spinnaker: Spinnaker = .up, planing: Bool = true) -> Boat {
            var boat = WakeTests.boat(speed: 6, planing: planing)
            boat.heading = -deg2rad(twaDegrees)
            boat.spinnaker = spinnaker
            return boat
        }
        // Off the plane, so the soft kite's share is the same at every angle and only the wind angle moves it.
        func kite(_ twa: Double) -> SpinnakerPose {
            SpinnakerPose(boat(twaDegrees: twa, planing: false), isGhost: false, boatClass: boatClass, style: style)
        }
        let reach = kite(108), broad = kite(140), run = kite(175)
        #expect([reach.phase, broad.phase, run.phase] == [.up, .up, .up])
        #expect(reach.fill < broad.fill && broad.fill < run.fill, "reach \(reach.fill), broad \(broad.fill), run \(run.fill)")
        for twa in stride(from: 60.0, through: 178, by: 4) {
            for state: Spinnaker in [.up, .hoisting(remaining: tuning.transitionTime * 0.99),
                                     .dropping(remaining: tuning.transitionTime * 0.01)] {
                for planing in [true, false] {
                    let b = boat(twaDegrees: twa, spinnaker: state, planing: planing)
                    let kite = SpinnakerPose(b, isGhost: false, boatClass: boatClass, style: style)
                    #expect(kite.fill >= style.kiteDepthFloor, "twa \(twa) \(state) planing \(planing): \(kite.fill)")
                    let main = BoatPose(b, ease: false, isGhost: false, boatClass: boatClass, style: style)
                    #expect(main.spinnaker.trim >= main.sailTrim, "twa \(twa) \(state): kite inside the main")
                }
            }
        }
    }
}
