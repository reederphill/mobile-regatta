import CoreGraphics
import SceneKit
import Testing
import RegattaCore
@testable import Regatta

/// The skiff's spinnaker (#311): its pose is a pure read of the sim's public state (`Boat.spinnaker`,
/// `Boat.isSpinnakerCollapsed(in:)`), with no timing or threshold of its own; its node draws that pose with the pole
/// running out with the hoist, hidden on a ghost, on a class without a kite and with `-cuesOnly`, and snapping on a
/// settled frame. A skiff draws two more nodes than before, any other class none.
@MainActor struct SpinnakerPoseTests {
    static let boatClass = Race.defaultBoatClass

    static func tuning() throws -> BoatClass.SpinnakerTuning { try #require(boatClass.spinnaker) }

    /// A boat running at `twaDegrees` with her kite in `spinnaker`; `byTheLee` puts the boom on the windward side, so
    /// she is `180 − twa` degrees by the lee.
    static func boat(twaDegrees: Double = 150, spinnaker: Spinnaker = .up, byTheLee: Bool = false, shadow: Double = 1,
                     id: Int = 1, isPlayer: Bool = false, colorIndex: Int = 1) -> Boat {
        var boat = BoatPoseTests.boat(id: id, isPlayer: isPlayer, colorIndex: colorIndex, twaDegrees: twaDegrees,
                                      windKnots: 14, shadow: shadow, averageKnots: 14)
        boat.spinnaker = spinnaker
        if byTheLee { boat.boomSide = .starboard }
        return boat
    }

    static func pose(_ boat: Boat, isGhost: Bool = false, boatClass: BoatClass = boatClass) -> SpinnakerPose {
        SpinnakerPose(boat, isGhost: isGhost, boatClass: boatClass)
    }

    static func ilca() throws -> BoatClass { try BoatClassFile.bundled(id: "ilca-dinghy", version: 5).content }

    // MARK: The pose

    @Test func downDrawsNothing() {
        let kite = Self.pose(Self.boat(spinnaker: .down))
        #expect(kite == .hidden && kite.hoisted == 0)
    }

    @Test func hoistProgressIsTheSimsTimeLeft() throws {
        let t = try Self.tuning().transitionTime
        var last = -1.0
        for step in 0...20 {
            let remaining = t * (1 - Double(step) / 20)
            guard remaining > 0 else { continue }
            let kite = Self.pose(Self.boat(spinnaker: .hoisting(remaining: remaining)))
            #expect(kite.phase == .hoisting)
            #expect(abs(kite.hoisted - (1 - remaining / t)) < 1e-12, "\(remaining) s left")
            #expect(kite.hoisted > last)
            last = kite.hoisted
        }
        #expect(Self.pose(Self.boat(spinnaker: .up)).hoisted == 1)
    }

    @Test func dropProgressRunsBackToNothing() throws {
        let t = try Self.tuning().transitionTime
        var last = 2.0
        for step in 0..<20 {
            let remaining = t * (1 - Double(step) / 20)
            let kite = Self.pose(Self.boat(spinnaker: .dropping(remaining: remaining)))
            #expect(kite.phase == .dropping)
            #expect(abs(kite.hoisted - remaining / t) < 1e-12)
            #expect(kite.hoisted < last)
            last = kite.hoisted
        }
    }

    /// A head-up mid-hoist turns it into a drop with the time it had run (`Spinnaker.next`): the drawn progress never
    /// jumps more than a step's share of the transition.
    @Test func reversalMidHoistKeepsItsProgress() throws {
        let tuning = try Self.tuning()
        let dt = 1.0 / 30
        var spinnaker = Spinnaker.down
        var last = 0.0
        var reversed = false
        for step in 0..<400 {
            // Bear away until half-way up, then head up.
            let headingUp = step > 0 && (reversed || spinnaker.remaining.map { $0 < tuning.transitionTime / 2 } == true)
            let twa = headingUp ? tuning.dropBelowTWA - 0.1 : tuning.hoistAboveTWA + 0.1
            let before = spinnaker
            spinnaker = spinnaker.next(twa: twa, dt: dt, tuning: tuning)
            if case .hoisting = before, case .dropping = spinnaker { reversed = true }
            let hoisted = Self.pose(Self.boat(spinnaker: spinnaker)).hoisted
            #expect(abs(hoisted - last) <= dt / tuning.transitionTime + 1e-9, "step \(step): \(last) → \(hoisted)")
            last = hoisted
            if reversed, spinnaker == .down { break }
        }
        #expect(reversed && spinnaker == .down)
    }

    /// Swept 0–20° by the lee: collapsed exactly when the sim says so, never on a threshold of its own.
    @Test func collapsedExactlyWhenTheSimSaysSo() {
        var collapsed = 0
        for tenth in stride(from: 0, through: 200, by: 5) {
            let boat = Self.boat(twaDegrees: 180 - Double(tenth) / 10, byTheLee: true)
            let kite = Self.pose(boat)
            #expect((kite.phase == .collapsed) == boat.isSpinnakerCollapsed(in: Self.boatClass), "\(Double(tenth) / 10)°")
            if kite.phase == .collapsed { collapsed += 1 }
        }
        #expect(collapsed > 0 && collapsed < 41)
    }

    /// The kite flies on the boom's side, by the lee included (to windward there).
    @Test func sideIsTheBoomSide() {
        for (twa, byTheLee) in [(150.0, false), (175, false), (172, true), (165, true)] {
            for side in [BoomSide.port, .starboard] {
                var boat = Self.boat(twaDegrees: twa, byTheLee: byTheLee)
                boat.boomSide = side
                #expect(Self.pose(boat).side == side, "\(twa) \(side)")
            }
        }
    }

    /// The soft kite: its depth falls with the plane margin, from full at a comfortable margin to its softest at the
    /// edge, never under the floor.
    @Test func softensWithThePlaneMargin() throws {
        let style = BoatStyle.standard
        var drawn: [(margin: Double, fill: Double)] = []
        for knots in stride(from: 8.0, through: 30, by: 2) {
            for speed in stride(from: 0.0, through: 14, by: 0.5) {
                var boat = Self.boat()
                boat.isPlaning = true
                boat.sailingWind.speed = metresPerSecond(knots: knots)
                boat.windOverGround = boat.sailingWind
                boat.speed = speed
                let kite = Self.pose(boat)
                #expect(kite.phase == .up && kite.fill >= style.kiteDepthFloor)
                drawn.append((PlaneMargin.of(boat, boatClass: Self.boatClass, style: style), kite.fill))
            }
        }
        drawn.sort { $0.margin < $1.margin }
        #expect(zip(drawn, drawn.dropFirst()).allSatisfy { $0.fill <= $1.fill + 1e-12 }, "\(drawn)")
        let edge = try #require(drawn.first), full = try #require(drawn.last)
        #expect(edge.margin < 0.2 && full.margin == 1, "\(edge.margin) to \(full.margin)")
        #expect(full.fill > edge.fill)
        // Off the plane it draws at its softest, as at a margin of 0.
        var off = Self.boat()
        off.isPlaning = false
        var onTheEdge = Self.boat()
        onTheEdge.isPlaning = true
        onTheEdge.speed = 0
        #expect(PlaneMargin.of(onTheEdge, boatClass: Self.boatClass, style: style) == 0)
        #expect(Self.pose(off).fill == Self.pose(onTheEdge).fill)
    }

    /// Shadow is turbulence: on skiff@9, whose shadow is a speed loss, a shadowed kite still flogs, read from the
    /// shadowed felt wind.
    @Test func flutterReadsTheShadowedWind() {
        #expect(Self.pose(Self.boat(shadow: 1)).flutter == 0)
        #expect(Self.pose(Self.boat(shadow: 0.6)).flutter > 0.3)
    }

    @Test func ghostDrawsNoKite() {
        #expect(Self.pose(Self.boat(), isGhost: true) == .hidden)
        let pose = BoatPose(Self.boat(), ease: false, isGhost: true, boatClass: Self.boatClass)
        #expect(pose.spinnaker == .hidden)
    }

    @Test func classWithoutSpinnakerNeverShows() throws {
        let ilca = try Self.ilca()
        #expect(ilca.spinnaker == nil)
        for state: Spinnaker in [.up, .hoisting(remaining: 1), .dropping(remaining: 1)] {
            #expect(Self.pose(Self.boat(spinnaker: state), boatClass: ilca) == .hidden)
        }
    }

    /// Two boats in the same state take the same kite, whatever their seat, colour or whether one is yours.
    @Test func sameBoatSameKiteNoLiveryInput() {
        for state: Spinnaker in [.up, .hoisting(remaining: 1.3), .dropping(remaining: 2.1)] {
            for (twa, lee) in [(140.0, false), (168, true)] {
                let mine = Self.boat(twaDegrees: twa, spinnaker: state, byTheLee: lee, id: 0, isPlayer: true, colorIndex: 0)
                let theirs = Self.boat(twaDegrees: twa, spinnaker: state, byTheLee: lee, id: 7, colorIndex: 9)
                #expect(Self.pose(mine) == Self.pose(theirs))
                #expect(BoatPose(mine, ease: false, isGhost: false, boatClass: Self.boatClass)
                        == BoatPose(theirs, ease: false, isGhost: false, boatClass: Self.boatClass))
            }
        }
    }

    // MARK: The node

    static func node(boatClass: BoatClass = boatClass, seat: Int = 1) -> Boat3D {
        Boat3D(geometry: Boat3D.Geometry(boatClass: boatClass, ppm: 8), color: .red, seat: seat)
    }

    static func draw(_ node: Boat3D, _ boat: Boat, isGhost: Bool = false, boatClass: BoatClass = boatClass,
                     hidesSail: Bool = false, time: Double = 0, dt: Double = 0, settled: Bool = true) {
        let pose = BoatPose(boat, ease: false, isGhost: isGhost, boatClass: boatClass)
        node.update(pose: pose, style: .standard, x: 0, z: 0, yaw: 0, hidesSail: hidesSail, time: time, dt: dt,
                    settled: settled)
    }

    /// The pole runs out with the hoist and back in with the drop, on the centreline (it never swings), the kite's
    /// tack at its tip and the kite as big as it is hoisted; down, neither draws.
    @Test func poleRunsOutWithTheHoist() throws {
        let t = try Self.tuning().transitionTime
        let node = Self.node()
        Self.draw(node, Self.boat(spinnaker: .down))
        #expect(node.kiteLook == nil && node.poleLook == nil)

        let full = Float(BoatStyle.standard.kitePoleMetres) * 8
        var tips: [Float] = []
        for share in [0.1, 0.3, 0.5, 0.7, 0.9] {
            Self.draw(node, Self.boat(spinnaker: .hoisting(remaining: t * (1 - share))))
            let pole = try #require(node.poleLook), kite = try #require(node.kiteLook)
            #expect(pole.turn == 0 && pole.x == 0 && pole.kiteTack.x == 0, "on the centreline")
            #expect(abs(pole.kiteTack.z - pole.tipZ) < 1e-3, "the tack at the pole's tip")
            #expect(abs(kite.size - Float(share)) < 1e-6)
            tips.append(pole.tipZ)
        }
        // Forward is −z: each tip further forward.
        #expect(zip(tips, tips.dropFirst()).allSatisfy { $1 < $0 }, "\(tips)")
        #expect(abs((tips[0] - tips[4]) - full * 0.8) < 1e-3, "its length is the slider's times the hoist")
        Self.draw(node, Self.boat(spinnaker: .up))
        let up = try #require(node.poleLook)
        #expect(abs((tips[0] + full * 0.1) - up.tipZ - full) < 1e-3, "run fully out while up")
        Self.draw(node, Self.boat(spinnaker: .dropping(remaining: t * 0.5)))
        #expect(abs(try #require(node.poleLook).tipZ - tips[2]) < 1e-3, "half-way in, as half-way out")
        Self.draw(node, Self.boat(spinnaker: .down))
        #expect(node.kiteLook == nil && node.poleLook == nil)
    }

    /// A ghost flies no kite; `-cuesOnly` (`hidesSail`) hides the kite and pole with the sail.
    @Test func ghostAndCuesOnlyHideTheKiteAndPole() throws {
        let boat = Self.boat()
        let ghost = Self.node()
        Self.draw(ghost, boat, isGhost: true)
        #expect(ghost.kiteLook == nil && ghost.poleLook == nil)

        let cues = Self.node()
        Self.draw(cues, boat)
        #expect(cues.kiteLook != nil && cues.poleLook != nil)
        Self.draw(cues, boat, hidesSail: true)
        #expect(cues.kiteLook == nil && cues.poleLook == nil)
    }

    /// A settled frame (a fixture) snaps every ease to the pose: the kite's angle and depth draw the pose's at once.
    @Test func settledSnapsEveryEase() throws {
        let style = BoatStyle.standard
        let node = Self.node()
        Self.draw(node, Self.boat(twaDegrees: 130))
        // A different angle, depth and side, unsettled: part-way there.
        var other = Self.boat(twaDegrees: 172, byTheLee: true)
        other.isPlaning = true
        Self.draw(node, other, time: 1, dt: 1.0 / 60, settled: false)
        let target = BoatPose(other, ease: false, isGhost: false, boatClass: Self.boatClass).spinnaker
        Self.draw(node, other, time: 1, dt: 0, settled: true)
        let kite = try #require(node.kiteLook)
        let side: Float = target.side == .port ? -1 : 1
        // Collapsed, it flogs: its angle is its trim plus the flog's swing, its depth the pose's or the floor, pumped.
        let swing = Float(deg2rad(style.kiteFlutterDegrees) * target.flutter)
        #expect(abs(kite.angle - side * Float(target.trim)) <= swing + 1e-5, "\(kite.angle) for \(target.trim)")
        #expect((kite.depth > 0) == (side > 0))
        #expect(abs(kite.depth) <= Float(target.fill) + 1e-5 && abs(kite.depth) >= Float(style.kiteDepthFloor) - 1e-5)
        #expect(kite.size == 1)
    }

    /// The far tier (`SailDetail.farReduced`, #127) drops only the kite's flog and pump: far away a collapsed kite
    /// still draws collapsed, at its trim and depth, with its pole out; near, the same kite flogs.
    @Test func farTierDropsOnlyTheKitesFlog() throws {
        let collapsed = Self.boat(twaDegrees: 166, byTheLee: true)
        let pose = BoatPose(collapsed, ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(pose.spinnaker.phase == .collapsed && pose.spinnaker.flutter > 0.5)
        func drawn(hulls: Double, time: Double) throws -> (angle: Float, depth: Float, size: Float) {
            let node = Self.node()
            node.update(pose: pose, style: .standard, x: 0, z: 0, yaw: 0, sailDetail: .farReduced, hullsFromYou: hulls,
                        time: time, dt: 0, settled: true)
            #expect(node.poleLook != nil)
            return try #require(node.kiteLook)
        }
        let nearA = try drawn(hulls: 2, time: 0.3), nearB = try drawn(hulls: 2, time: 1.1)
        #expect(abs(nearA.angle - nearB.angle) > 1e-3, "near, it flogs")
        let farA = try drawn(hulls: 40, time: 0.3), farB = try drawn(hulls: 40, time: 1.1)
        #expect(farA == farB, "far, it holds still")
        let side: Float = pose.spinnaker.side == .port ? -1 : 1
        #expect(abs(farA.angle - side * Float(pose.spinnaker.trim)) < 1e-5, "at its collapsed trim")
        #expect(abs(abs(farA.depth) - max(Float(pose.spinnaker.fill), Float(BoatStyle.standard.kiteDepthFloor))) < 1e-5)
    }

    /// A ghost's kite material fades with the rest of her (#30), so a kite shown the frame she turns ghost fades too.
    @Test func ghostFadesTheKiteMaterial() {
        let node = Self.node()
        Self.draw(node, Self.boat(), isGhost: true)
        #expect(node.transparency.count == 6, "the kite has a material of its own")
        #expect(node.transparency.allSatisfy { abs($0 - CGFloat(BoatStyle.standard.ghostAlpha)) < 1e-6 })
    }

    /// The node budget (#405): a skiff draws its pole and kite, two SceneKit nodes more; a class without a kite none.
    @Test func aSkiffDrawsTwoMoreNodesAnyOtherClassNone() throws {
        func count(_ node: SCNNode) -> Int { node.childNodes.reduce(0) { $0 + 1 + count($1) } }
        let ilca = try Self.ilca()
        let skiff = Self.node(), dinghy = Self.node(boatClass: ilca)
        #expect(count(skiff.root) + 1 == Boat3D.nodeCount + Boat3D.kiteNodeCount)
        #expect(count(dinghy.root) + 1 == Boat3D.nodeCount)
        #expect(skiff.drawnNodeCount == Boat3D.nodeCount + 2 && dinghy.drawnNodeCount == Boat3D.nodeCount)
        // And an ILCA with a kite state drawn still shows none.
        Self.draw(dinghy, Self.boat(), boatClass: ilca)
        #expect(dinghy.kiteLook == nil && dinghy.poleLook == nil)
    }
}
