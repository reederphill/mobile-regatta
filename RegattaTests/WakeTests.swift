import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// A boat's wake (#15, #220, #121): its shape's length is her speed through the water, and what the scene draws is
/// her stern's track, one string a boat.
@MainActor @Suite struct WakeTests {
    static let boatClass = Race.defaultBoatClass

    /// A boat sailing `speed` m/s through the water at `position`, carried by `current`.
    static func boat(speed: Double, position: Vec2 = Vec2(10, 20), current: Vec2 = .zero, planing: Bool = false) -> Boat {
        var boat = Boat(id: 1, isPlayer: false, colorIndex: 1, position: position, heading: deg2rad(-45), speed: speed,
                        boomSide: .port)
        boat.status = .racing
        boat.sailingWind = Wind(direction: 0, speed: 6)
        boat.apparentWind = Wind(direction: deg2rad(-15), speed: 8)
        boat.averagedWindSpeed = 6
        boat.current = current
        boat.isPlaning = planing
        return boat
    }

    /// Her wake grows with her speed through the water, in both tiers, planing or not, up to its longest at
    /// `BoatStyle.wakeFullSpeed`; and nothing but that speed moves it: not the current that carries her (#11), so
    /// not her ground speed, nor where she is.
    @Test func lengthMonotonicInSpeedThroughWater() {
        let style = BoatStyle.standard
        for quality in [WakeQuality.full, .short] {
            for planing in [false, true] {
                var last = -1.0
                for speed in stride(from: 0.0, through: 12, by: 0.25) {
                    let length = WakeShape(Self.boat(speed: speed, planing: planing), boatClass: Self.boatClass,
                                           style: style, quality: quality).length
                    if speed <= style.wakeFullSpeed {
                        #expect(length > last, "\(quality), planing \(planing): \(length) m at \(speed) m/s after \(last)")
                    } else {
                        #expect(length >= last, "\(quality), planing \(planing): \(length) m at \(speed) m/s after \(last)")
                    }
                    last = length

                    // The same speed through the water in a current, elsewhere on the course: the same wake.
                    for current in [Vec2(1.5, 0), Vec2(-0.8, 1.2), Vec2(0, -2)] {
                        let drifting = Self.boat(speed: speed, position: Vec2(-300, 450), current: current,
                                                 planing: planing)
                        #expect(drifting.velocityOverGround != Self.boat(speed: speed).velocityOverGround)
                        let drifted = WakeShape(drifting, boatClass: Self.boatClass, style: style, quality: quality)
                        #expect(drifted.length == length, "\(quality): current \(current) at \(speed) m/s")
                    }
                }
                #expect(last > 0)
            }
        }
        // The short tier is shorter, still speed-scaled (#127), and drops the streak.
        let fast = Self.boat(speed: 6)
        let full = WakeShape(fast, boatClass: Self.boatClass, style: style, quality: .full)
        let short = WakeShape(fast, boatClass: Self.boatClass, style: style, quality: .short)
        #expect(short.length < full.length)
        #expect(short.streakAlpha == 0 && full.streakAlpha > 0)
    }

    /// The shipped wake is short (#220): 1.5 to 2.5 hull lengths at full speed, planing or not. And a saved
    /// planing boost under 1 never shortens a planing wake (the lenient decoder takes any value).
    @Test func wakeIsShortAndPlaningNeverShortensIt() throws {
        let style = BoatStyle.standard
        let hull = Self.boatClass.hull.length
        for planing in [false, true] {
            let shape = WakeShape(Self.boat(speed: style.wakeFullSpeed, planing: planing), boatClass: Self.boatClass,
                                  style: style, quality: .full)
            #expect((1.5 * hull...2.5 * hull).contains(shape.length), "planing \(planing): \(shape.length / hull) hulls")
        }
        var odd = style
        odd.wakePlaningBoost = 0.5
        let saved = try JSONDecoder().decode(BoatStyle.self, from: JSONEncoder().encode(odd))
        let planing = WakeShape(Self.boat(speed: 6, planing: true), boatClass: Self.boatClass, style: saved, quality: .full)
        let plain = WakeShape(Self.boat(speed: 6), boatClass: Self.boatClass, style: saved, quality: .full)
        #expect(planing == plain)
    }

    /// A ghost fades as one flat image (#30), her body and her wake each: their effect nodes are on, at her ghost
    /// alpha; a live boat's are off and draw straight through.
    @Test func ghostsFadeAsOneImage() {
        let style = BoatStyle.standard
        let boat = Self.boat(speed: 6)
        for ghost in [false, true] {
            let node = BoatNode(boat: boat, isMine: false, color: .red, boatClass: Self.boatClass, pointsPerMeter: 8,
                                style: style)
            let pose = BoatPose(boat, ease: false, isGhost: ghost, boatClass: Self.boatClass, style: style)
            node.update(with: boat, pose: pose, style: style, time: 0, dt: 0, settled: true)
            let alpha = ghost ? CGFloat(style.ghostAlpha) : 1
            // SpriteKit keeps alpha as a Float.
            #expect(node.fade.shouldEnableEffects == ghost && abs(node.fade.alpha - alpha) < 1e-6, "ghost \(ghost)")
            let wake = CGFloat(node.effects.shape?.alpha ?? 0) * alpha
            #expect(abs(node.effects.trail.alpha - wake) < 1e-6, "ghost \(ghost)")
        }
    }

    /// 16 boats (#57's fleet) sail on for many frames: after the first frame the effects layer's nodes stay the same
    /// ones (a wake is a path on a node of its own, rebuilt as she sails) and their textures never change. Prints the
    /// effects' node count for the PR.
    @Test func effectNodesStayTheSameAfterFirstFrame() throws {
        let config = RaceConfig(opponents: LaunchOptions.perfFleetSize - 1, prestartSeconds: 30, seed: 3,
                                windSeed: RaceConfig.windSeed(pinnedTo: 3), botSailsYourBoat: true)
        let session = GameSession(config: config, timescale: 8)
        SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
        let effects = try #require(session.scene.childNode(withName: "//effects"))
        #expect(session.driver.currentFrame.boats.count == 16)

        func snapshot() -> [(ObjectIdentifier, SKTexture?)] {
            Self.descendants(of: effects).map { ($0.0, ($0.1 as? SKSpriteNode)?.texture) }
        }
        session.scene.update(0)
        let first = snapshot()
        let shapes = Self.descendants(of: effects).filter { $0.1 is SKShapeNode }.count
        let sprites = Self.descendants(of: effects).filter { $0.1 is SKSpriteNode }.count
        print("WakeTests: 16 boats' effects: \(first.count) nodes, \(sprites) sprites, \(shapes) shape nodes")
        #expect(shapes == 16)

        var drawnWakes = 0
        for frame in 1...240 {
            session.scene.update(Double(frame) / 60)
            let now = snapshot()
            #expect(now.map(\.0) == first.map(\.0), "frame \(frame): the effects' nodes changed")
            #expect(zip(now, first).allSatisfy { $0.1 === $1.1 }, "frame \(frame): an effect's texture changed")
            drawnWakes = session.scene.boatTrails.filter { !$0.isHidden && ($0.path?.boundingBox.width ?? 0) > 1 }.count
        }
        // Not vacuous: the fleet is sailing and drawing wakes by the end.
        #expect(drawnWakes > 8, "\(drawnWakes) wakes drawn")
    }

    /// Every node under `node`, depth first.
    static func descendants(of node: SKNode) -> [(ObjectIdentifier, SKNode)] {
        node.children.flatMap { [(ObjectIdentifier($0), $0)] + descendants(of: $0) }
    }

    /// A roll, hit or missed, leaves her wake as it was (#460): no flare, and it never dies.
    @Test func aRollLeavesTheWakeAlone() {
        let style = BoatStyle.standard
        let effects = BoatEffects(seat: 1, boatClass: Self.boatClass, pointsPerMeter: 8, style: style)
        var boat = Self.boat(speed: 6)
        let calm = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
        effects.update(with: boat, pose: calm, style: style, quality: .full, time: 0, dt: 0, settled: true)
        let even = effects.shape
        #expect((even?.alpha ?? 0) > 0)
        for roll in [RollTack.hit, .missed] {
            boat.roll = roll
            let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
            effects.update(with: boat, pose: pose, style: style, quality: .full, time: 1, dt: 0, settled: true)
            #expect(effects.shape == even && !effects.trail.isHidden, "\(roll)")
        }
    }

    /// #462: how far on the plane she is drawn follows the flag over `seconds`, whatever the flag does: all the way
    /// after that long on or off, never more than `1.5 * dt / seconds` a frame, turning round where it is when the
    /// flag flips back, and held near where it was while the flag flickers (a boat on the edge of the plane).
    @Test func planingLookComesAndGoesWithoutAJump() {
        for seconds in [0.5, 1, 2.5] {
            for dt in [1.0 / 120, 1.0 / 60, 1.0 / 30, 0.1] {
                var ease = PlaningEase(isPlaning: true)
                #expect(ease.level == 1)
                // On, a fall, back on half way down, off again, a flicker every frame, then on for good.
                let flags = [(true, 1.0), (false, seconds * 2), (true, seconds * 0.5), (false, seconds * 0.25),
                             (true, seconds * 3)]
                var script = flags.flatMap { flag, time in Array(repeating: flag, count: Int((time / dt).rounded(.up))) }
                let flickerStart = script.count
                script += (0..<Int((seconds * 2 / dt).rounded(.up))).map { $0.isMultiple(of: 2) }
                let flickerEnd = script.count
                script += Array(repeating: true, count: Int((seconds / dt).rounded(.up)) + 1)

                var last = ease.level, lowest = 1.0, atFlicker = 0.0
                for (frame, isPlaning) in script.enumerated() {
                    ease.advance(isPlaning: isPlaning, dt: dt, seconds: seconds)
                    let level = ease.level
                    #expect((0...1).contains(level))
                    #expect(abs(level - last) <= 1.5 * dt / seconds + 1e-12, "\(seconds) s, dt \(dt), frame \(frame): \(last) to \(level)")
                    if isPlaning { #expect(level >= last) } else { #expect(level <= last) }
                    if frame == flickerStart - 1 { atFlicker = level }
                    if (flickerStart..<flickerEnd).contains(frame) {
                        #expect(abs(level - atFlicker) <= 1.5 * dt / seconds + 1e-12, "a flickering flag moved her wake")
                    }
                    lowest = min(lowest, level)
                    last = level
                }
                #expect(lowest == 0, "\(seconds) s on the water off the plane is all the way off")
                #expect(ease.level == 1)

                // Half way through a fall she is half way off; time standing still or running backwards moves nothing.
                var half = PlaningEase(isPlaning: true)
                half.advance(isPlaning: false, dt: seconds / 2, seconds: seconds)
                #expect(abs(half.level - 0.5) < 1e-12)
                let held = half
                half.advance(isPlaning: false, dt: 0, seconds: seconds)
                half.advance(isPlaning: true, dt: -1, seconds: seconds)
                #expect(half == held)
            }
        }
        // No time at all: with the flag, as before #462.
        var snap = PlaningEase(isPlaning: true)
        snap.advance(isPlaning: false, dt: 1.0 / 60, seconds: 0)
        #expect(snap.level == 0)
    }

    /// The wake's planing look scales with how far on the plane she is drawn: none of it off the plane, all of it
    /// on, in step between, and the frozen frame's wake is the flag's.
    @Test func wakePlaningLookFollowsItsLevel() {
        let style = BoatStyle.standard
        func shape(_ level: Double?, planing: Bool = false) -> WakeShape {
            WakeShape(Self.boat(speed: 6, planing: planing), boatClass: Self.boatClass, style: style, quality: .full,
                      planing: level)
        }
        let off = shape(nil), on = shape(nil, planing: true)
        #expect(on.alpha > off.alpha && on.length > off.length)
        // The level is what is drawn, whatever the flag says this tick.
        #expect(shape(0, planing: true) == off && shape(1) == on && shape(-1) == off && shape(2) == on)
        var last = off
        for step in 1...10 {
            let next = shape(Double(step) / 10)
            #expect(next.alpha > last.alpha && next.length > last.length && next.alpha <= on.alpha + 1e-12)
            last = next
        }
        #expect(abs(shape(0.5).alpha - (off.alpha + on.alpha) / 2) < 1e-12)
    }

    /// #462: she falls off the plane and gets back on, and her drawn wake never jumps: frame to frame its alpha
    /// moves a small share of the planing look, it is still most of the way on a quarter of a second after the
    /// fall, all the way off well after `wakePlaningSeconds`, and a flag flickering every frame leaves it steady.
    /// A frozen frame (`settled`) and her first frame draw her as she is.
    @Test func aFallOffThePlaneSettlesTheWake() throws {
        let style = BoatStyle.standard
        let dt = 1.0 / 60
        var boat = Self.boat(speed: 6, planing: true)
        let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
        let on = WakeShape(boat, boatClass: Self.boatClass, style: style, quality: .full).alpha
        let off = WakeShape(Self.boat(speed: 6), boatClass: Self.boatClass, style: style, quality: .full).alpha
        let look = on - off
        #expect(look > 0.01)

        let effects = BoatEffects(seat: 1, boatClass: Self.boatClass, pointsPerMeter: 8, style: style)
        var time = 0.0
        func frame(planing: Bool, settled: Bool = false) throws -> Double {
            boat.isPlaning = planing
            time += dt
            effects.update(with: boat, pose: pose, style: style, quality: .full, time: time, dt: dt, settled: settled)
            return try #require(effects.shape).alpha
        }
        // Her first frame: on the plane, as she is.
        var last = try frame(planing: true)
        #expect(last == on)

        // The most a frame may move it: the planing ramp's steepest, and a little for float error.
        let most = look * 1.5 * dt / style.wakePlaningSeconds + 1e-9
        func sail(planing: @escaping (Int) -> Bool, seconds: Double, _ check: (Int, Double) -> Void = { _, _ in }) throws {
            for index in 0..<Int((seconds / dt).rounded()) {
                let alpha = try frame(planing: planing(index))
                #expect(abs(alpha - last) <= most, "\(time) s: \(last) to \(alpha)")
                #expect((off - 1e-9...on + 1e-9).contains(alpha))
                last = alpha
                check(index, alpha)
            }
        }
        // A fall: still most of the look a quarter of a second in, gone by three seconds.
        try sail(planing: { _ in false }, seconds: 0.25)
        #expect(last > off + look * 0.75, "\((last - off) / look) of the look 0.25 s after the fall")
        try sail(planing: { _ in false }, seconds: 2.75)
        #expect(abs(last - off) < look * 0.01)
        // Back on: lifting, half way or less at half a second, all there by three.
        try sail(planing: { _ in true }, seconds: 0.5)
        #expect(last > off && last < off + look * 0.6)
        try sail(planing: { _ in true }, seconds: 2.5)
        #expect(abs(last - on) < look * 0.01)
        // Held on the edge: a flag flipping every frame for two seconds leaves her wake where it was.
        let before = last
        try sail(planing: { !$0.isMultiple(of: 2) }, seconds: 2) { _, alpha in
            #expect(abs(alpha - before) < look * 0.06, "a flickering flag flickered her wake")
        }
        // A fall, and back on half way down: it turns round where it is.
        try sail(planing: { _ in false }, seconds: 0.6)
        let turned = last
        try sail(planing: { _ in true }, seconds: 0.1)
        #expect(abs(last - turned) < look * 0.2)

        // A frozen frame draws the flag's wake straight.
        #expect(try frame(planing: false, settled: true) == off)
        #expect(try frame(planing: true, settled: true) == on)
    }
}

extension GameScene {
    /// Every boat's wake string in the effects layer.
    var boatTrails: [SKShapeNode] {
        guard let effects = childNode(withName: "//effects") else { return [] }
        return WakeTests.descendants(of: effects).compactMap { $0.1 as? SKShapeNode }
    }
}
