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
        // A wake and her stern-corner wakes (#492) each.
        #expect(shapes == 32)

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
    // MARK: Stern-corner wakes (#492)

    static let skiffNine = try! BoatClassFile.bundled(id: "skiff", version: 9).content

    /// What the corner wakes settle at: nothing off the plane, their shortest (`cornerWakeMinShare`) at the edge of
    /// it, their longest at a full margin, straight between and rising all the way; and scaled by how far on the plane
    /// she is drawn.
    @Test func cornerWakeLengthIsTheMarginOverAFloor() {
        let style = BoatStyle.standard
        let floor = style.cornerWakeMinShare
        #expect(floor > 0.2 && floor < 0.5, "a stub under a quarter read as gone in the prototype (#485)")
        #expect(CornerWakes.target(margin: 0, level: 1, style: style) == floor)
        #expect(CornerWakes.target(margin: 1, level: 1, style: style) == 1)
        #expect(abs(CornerWakes.target(margin: 0.5, level: 1, style: style) - (floor + 1) / 2) < 1e-12)
        #expect(CornerWakes.target(margin: 1, level: 0, style: style) == 0)
        #expect(abs(CornerWakes.target(margin: 0.4, level: 0.5, style: style) - CornerWakes.target(margin: 0.4, level: 1, style: style) / 2) < 1e-12)
        var last = -1.0
        for step in 0...20 {
            let next = CornerWakes.target(margin: Double(step) / 20, level: 1, style: style)
            #expect(next > last)
            last = next
        }
        #expect(CornerWakes.target(margin: 3, level: 2, style: style) == 1 && CornerWakes.target(margin: -1, level: 1, style: style) == floor)
        // As she is: on the plane at her margin, off it nothing; and seconds of track and alpha from the share.
        let on = CornerWakes(margin: 1, isPlaning: true, level: 1, style: style)
        let edge = CornerWakes(margin: 0, isPlaning: true, level: 1, style: style)
        let off = CornerWakes(margin: 1, isPlaning: false, level: 0, style: style)
        #expect(on.share == 1 && edge.share == floor && off.share == 0)
        #expect(on.seconds(wakeSeconds: style.wakeTrailSeconds, style: style) == style.wakeTrailSeconds * style.cornerWakeLengthShare)
        #expect(edge.seconds(wakeSeconds: style.wakeTrailSeconds, style: style) > 0.5, "the edge's stretch of track, seconds")
        #expect(off.seconds(wakeSeconds: style.wakeTrailSeconds, style: style) == 0)
        // Shorter, thinner and fainter than the middle wake, on the plane.
        let middle = WakeShape(Self.boat(speed: 7, planing: true), boatClass: Self.boatClass, style: style, quality: .full)
        #expect(on.alpha(style: style) == style.cornerWakeAlpha && edge.alpha(style: style) == style.cornerWakeAlpha && off.alpha(style: style) == 0)
        #expect(style.cornerWakeAlpha < middle.alpha && style.cornerWakeWidth < style.wakeTrailWidth && style.cornerWakeLengthShare < 1)
    }

    /// No jump and no flicker: whatever her margin and flag do (a margin sawing between 0 and 1, a fall at a full
    /// margin, getting back on, a flag flickering every frame), a frame moves the corner wakes no more than the ease's
    /// step; a fall draws them in to nothing and nothing else does; a flickering flag leaves them where they were.
    @Test func cornerWakesNeverJumpOrFlicker() {
        let style = BoatStyle.standard
        for dt in [1.0 / 120, 1.0 / 60, 1.0 / 30] {
            let most = 1 - exp(-dt * style.cornerWakeEaseRate) + 1e-12
            var ease = PlaningEase(isPlaning: true)
            var wakes = CornerWakes(margin: 1, isPlaning: true, level: 1, style: style)
            var last = wakes.share, lastAlpha = wakes.alpha(style: style)
            func sail(seconds: Double, _ state: (Int) -> (margin: Double, planing: Bool), _ check: (Double) -> Void = { _ in }) {
                for frame in 0..<Int((seconds / dt).rounded()) {
                    let (margin, planing) = state(frame)
                    ease.advance(isPlaning: planing, dt: dt, seconds: style.wakePlaningSeconds)
                    // Off the plane the margin reads 0, as core's does.
                    wakes.advance(margin: planing ? margin : 0, isPlaning: planing, level: ease.level, dt: dt, style: style)
                    #expect((0...1).contains(wakes.share))
                    #expect(abs(wakes.share - last) <= most, "dt \(dt): \(last) to \(wakes.share)")
                    #expect(abs(wakes.alpha(style: style) - lastAlpha) <= style.cornerWakeAlpha * most / style.cornerWakeMinShare + 1e-12)
                    last = wakes.share
                    lastAlpha = wakes.alpha(style: style)
                    check(last)
                }
            }
            // On the plane, her margin sawing from full to nothing and back each frame: never under their shortest.
            sail(seconds: 2, { ($0.isMultiple(of: 2) ? 1 : 0, true) }) { #expect($0 >= style.cornerWakeMinShare - 1e-9) }
            // Running deeper: the margin runs down to the edge over four seconds, and they only ever shorten.
            sail(seconds: 4) { _ in (1, true) }
            #expect(last > 0.9999)
            var previous = last
            let frames = Int((4 / dt).rounded())
            sail(seconds: 4, { (1 - Double($0 + 1) / Double(frames), true) }) {
                #expect($0 <= previous + 1e-9, "the wakes grew as her margin ran out")
                previous = $0
            }
            #expect(last < style.cornerWakeMinShare + 0.1 && last >= style.cornerWakeMinShare, "at the edge, their shortest: \(last)")
            #expect(wakes.alpha(style: style) == style.cornerWakeAlpha, "and still at their full alpha")
            // She falls: drawn in to nothing, only ever shortening, gone well inside three seconds.
            previous = last
            sail(seconds: 3, { _ in (0, false) }) {
                #expect($0 <= previous + 1e-12)
                previous = $0
            }
            #expect(last < 0.002 && wakes.alpha(style: style) < 0.005)
            // Back on at a thin margin that fills: only ever growing.
            previous = last
            sail(seconds: 3, { (min(1, 0.15 + Double($0) * dt), true) }) {
                // (The last of the fall's ease is still running out under a thousandth as she starts.)
                #expect($0 >= previous - 1e-3, "the wakes shrank as she lifted")
                previous = $0
            }
            #expect(last > 0.98)
            // A fall at a full margin (headed up past the rule's angle): from full, with no step.
            sail(seconds: 0.25) { _ in (0, false) }
            #expect(last > 0.6, "a quarter of a second after the fall they are still most of their length: \(last)")
            sail(seconds: 3) { _ in (1, true) }
            // Held on the edge of the plane, her flag flipping every frame: where they were.
            sail(seconds: 2) { _ in (0.5, true) }
            let before = last
            sail(seconds: 2, { (0.5, !$0.isMultiple(of: 2)) }) {
                #expect(abs($0 - before) < 0.05, "a flickering flag flickered her corner wakes: \(before) to \($0)")
            }
        }
        // No ease: straight to her margin.
        var snap = BoatStyle.standard
        snap.cornerWakeEaseRate = 0
        var wakes = CornerWakes(margin: 1, isPlaning: true, level: 1, style: snap)
        wakes.advance(margin: 0, isPlaning: true, level: 1, dt: 1.0 / 60, style: snap)
        #expect(abs(wakes.share - snap.cornerWakeMinShare) < 1e-12)
    }

    /// The length of a path's bounding box diagonal, points.
    private static func reach(_ node: SKShapeNode) -> CGFloat {
        guard let box = node.path?.boundingBox, !box.isNull else { return 0 }
        return hypot(box.width, box.height)
    }

    /// Drawn (`BoatEffects.cornerTrail`): a planing boat trails two lines from her stern corners, half a beam either
    /// side of her wake, shorter, thinner and fainter than it; a boat off the plane, a ghost, and a class that never
    /// planes trail none. On skiff@9 they are as long as her plane margin: full on a fast reach, shorter run deep with
    /// little apparent wind, their shortest at the edge. A class before it has no margin to read: full while she planes.
    @Test func planingBoatTrailsHerSternCornerWakes() throws {
        let style = BoatStyle.standard
        let ppm: CGFloat = 8
        func drawn(_ boat: Boat, boatClass: BoatClass = Self.skiffNine, ghost: Bool = false, quality: WakeQuality = .full) -> BoatEffects {
            let effects = BoatEffects(seat: 1, boatClass: boatClass, pointsPerMeter: ppm, style: style)
            let pose = BoatPose(boat, ease: false, isGhost: ghost, boatClass: boatClass)
            effects.update(with: boat, pose: pose, style: style, quality: quality, time: 100, dt: 0, settled: true)
            return effects
        }
        /// A boat on port gybe at `twa` degrees in a northerly of `tws` knots, sailing `knots`.
        func boat(twa: Double, knots boatKnots: Double, tws: Double, planing: Bool = true) -> Boat {
            var boat = Self.boat(speed: metresPerSecond(knots: boatKnots), planing: planing)
            boat.heading = deg2rad(twa)
            boat.sailingWind = Wind(direction: 0, speed: metresPerSecond(knots: tws))
            return boat
        }
        let reach = boat(twa: 135, knots: 15, tws: 14), deep = boat(twa: 160, knots: 12.5, tws: 14)
        let edge = boat(twa: 172, knots: 11, tws: 14)
        #expect(PlaneMargin.of(reach, boatClass: Self.skiffNine, style: style) == 1)
        let thin = PlaneMargin.of(deep, boatClass: Self.skiffNine, style: style)
        #expect(thin > 0.1 && thin < 0.7, "\(thin)")
        #expect(PlaneMargin.of(edge, boatClass: Self.skiffNine, style: style) == 0)
        #expect(PlaneMargin.of(boat(twa: 135, knots: 15, tws: 14, planing: false), boatClass: Self.skiffNine, style: style) == 0)

        let full = drawn(reach)
        #expect(!full.cornerTrail.isHidden && full.corners?.share == 1)
        #expect(abs(full.cornerTrail.alpha - CGFloat(style.cornerWakeAlpha)) < 1e-6 && full.cornerTrail.alpha < full.trail.alpha)
        #expect(full.cornerTrail.lineWidth == CGFloat(style.cornerWakeWidth) && full.cornerTrail.lineWidth < full.trail.lineWidth)
        // Two lines, a beam apart at her stern, each shorter than her wake.
        let box = try #require(full.cornerTrail.path?.boundingBox), wake = try #require(full.trail.path?.boundingBox)
        let beam = CGFloat(Self.skiffNine.hull.beam) * ppm
        let trackLength = CGFloat(reach.speed * style.wakeTrailSeconds * style.cornerWakeLengthShare) * ppm
        // Sailing 135°: her track runs along one diagonal and her beam across the other, so the box's diagonal is
        // their sum.
        #expect(abs(hypot(box.width, box.height) - (trackLength + beam)) < 3, "\(box) for a track of \(trackLength) pt")
        #expect(Self.reach(full.cornerTrail) < Self.reach(full.trail) && wake.width > box.width - beam)
        var subpaths = 0
        full.cornerTrail.path?.applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
        #expect(subpaths == 2)

        // Her margin is their length: deep, with little apparent wind, shorter; at the edge, their shortest, still seen.
        let shorter = drawn(deep), shortest = drawn(edge)
        let perSecond = { (effects: BoatEffects, boat: Boat) in Self.reach(effects.cornerTrail) / CGFloat(boat.speed) }
        #expect(perSecond(shorter, deep) < perSecond(full, reach) * 0.85 && perSecond(shortest, edge) < perSecond(shorter, deep))
        #expect(shortest.corners?.share == style.cornerWakeMinShare && !shortest.cornerTrail.isHidden)
        #expect(Self.reach(shortest.cornerTrail) > 20, "\(Self.reach(shortest.cornerTrail)) pt at the edge")
        #expect(abs(shortest.cornerTrail.alpha - CGFloat(style.cornerWakeAlpha)) < 1e-6)

        // Off the plane, a ghost: none.
        for effects in [drawn(boat(twa: 135, knots: 7, tws: 14, planing: false)), drawn(reach, ghost: true)] {
            #expect(effects.cornerTrail.isHidden && effects.corners?.share == 0)
        }
        // The short tier (#127) shortens them with her wake, by the same share.
        let short = drawn(reach, quality: .short)
        #expect(!short.cornerTrail.isHidden)
        #expect(abs(Self.reach(short.cornerTrail) / Self.reach(full.cornerTrail) - CGFloat(style.wakeShortShare)) < 0.1)
        // The default class is skiff@9's rule: her margin is read in every default race.
        #expect(Self.boatClass.planing?.stayOnSpeedShare != nil && Self.boatClass.planing?.apparentWind != nil)
        #expect(drawn(deep, boatClass: Self.boatClass).corners?.share == shorter.corners?.share)
        // A class before it (skiff@8) has no margin to read: full while she planes, none off the plane.
        let skiffEight = try BoatClassFile.bundled(id: "skiff", version: 8).content
        #expect(skiffEight.planing != nil && skiffEight.planing?.stayOnSpeedShare == nil)
        #expect(drawn(deep, boatClass: skiffEight).corners?.share == 1)
        #expect(drawn(boat(twa: 160, knots: 7, tws: 14, planing: false), boatClass: skiffEight).cornerTrail.isHidden)
        // The plane the race seats her on (`TickFrame.isJustSeated`) draws none, frozen or sailing.
        let seated = BoatEffects(seat: 1, boatClass: Self.skiffNine, pointsPerMeter: ppm, style: style)
        let pose = BoatPose(reach, ease: false, isGhost: false, boatClass: Self.skiffNine)
        seated.update(with: reach, pose: pose, style: style, quality: .full, time: 100, dt: 0, settled: true, justSeated: true)
        #expect(seated.cornerTrail.isHidden && seated.corners?.share == 0 && !seated.trail.isHidden)
    }

    /// The seated fleet (#492): for the seconds the frame calls her just seated a boat with the flag on trails no
    /// corner wakes at all, while her wake takes its planing look as before (#462: the flag's); once the seating is
    /// behind her and she is still on the plane they come in, eased as getting on the plane is, with no step.
    @Test func seatedBoatTrailsNoCornerWakesUntilTheSeatingIsBehindHer() throws {
        let style = BoatStyle.standard
        let boatClass = Self.skiffNine
        let dt = 1.0 / 60
        let effects = BoatEffects(seat: 1, boatClass: boatClass, pointsPerMeter: 8, style: style)
        var boat = Self.boat(speed: metresPerSecond(knots: 11), planing: true)
        boat.heading = deg2rad(95)
        boat.sailingWind = Wind(direction: 0, speed: metresPerSecond(knots: 11))
        #expect(PlaneMargin.of(boat, boatClass: boatClass, style: style) == 1)
        let most = 1 - exp(-dt * style.cornerWakeEaseRate) + 1e-12
        var time = 0.0, last = 0.0
        while time < PlaningCue.seatedSeconds + 4 {
            time += dt
            boat.position = boat.position + boat.forward * (boat.speed * dt)
            let justSeated = time < PlaningCue.seatedSeconds
            let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass)
            effects.update(with: boat, pose: pose, style: style, quality: .full, time: time, dt: dt, settled: false,
                           justSeated: justSeated)
            let share = try #require(effects.corners).share
            if justSeated {
                #expect(share == 0 && effects.cornerTrail.isHidden, "\(time) s: \(share)")
            } else {
                #expect(share >= last && share - last <= most, "\(time) s: \(last) to \(share)")
            }
            last = share
        }
        #expect(try #require(effects.planing).level == 1, "her wake's planing look is the flag's")
        #expect(last > 0.99 && !effects.cornerTrail.isHidden)
    }

    /// A boat bears away on the plane until she falls off it, on skiff@9 through `BoatEffects`: her corner wakes
    /// shorten as her margin runs out, never lengthen on the way, never step, and are gone after the fall.
    @Test func bearingAwayUntilSheFallsShortensHerCornerWakes() throws {
        let style = BoatStyle.standard
        let boatClass = Self.skiffNine
        let rule = try #require(boatClass.planing)
        let dt = 1.0 / 60
        let effects = BoatEffects(seat: 1, boatClass: boatClass, pointsPerMeter: 8, style: style)
        var boat = Self.boat(speed: metresPerSecond(knots: 13), planing: true)
        boat.sailingWind = Wind(direction: 0, speed: metresPerSecond(knots: 14))
        var time = 0.0, last: Double?, fellAt: Double?, shares: [Double] = []
        let most = 1 - exp(-dt * style.cornerWakeEaseRate) + 1e-12
        // 1.5° a second from 135° at the polar's speed for her angle, her apparent wind thinning as she goes deeper;
        // the sim's own rule says when she falls.
        while time < 40 {
            time += dt
            let twa = min(135 + 1.5 * time, 178)
            boat.heading = deg2rad(twa)
            boat.position = boat.position + boat.forward * (boat.speed * dt)
            boat.speed = boatClass.polar.speed(twa: boat.twa, tws: boat.sailingWind.speed)
            boat.isPlaning = fellAt == nil && rule.isPlaning(was: boat.isPlaning, twa: boat.twa, speed: boat.speed,
                                                             tws: boat.sailingWind.speed, rudder: 0, polar: boatClass.polar)
            if !boat.isPlaning, fellAt == nil { fellAt = time }
            let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass)
            effects.update(with: boat, pose: pose, style: style, quality: .full, time: time, dt: dt, settled: false)
            let share = try #require(effects.corners).share
            if let last {
                #expect(abs(share - last) <= most, "\(time) s: \(last) to \(share)")
                #expect(share <= last + 1e-9, "\(time) s: her corner wakes grew as she bore away")
            }
            last = share
            shares.append(share)
            if let fellAt, time > fellAt + 3 { break }
        }
        let fell = try #require(fellAt)
        #expect(fell > 8 && fell < 35, "she fell at \(fell) s")
        #expect(shares[0] == 1)
        // A second before the fall they are well short of full but still there; at the fall, near their shortest.
        let before = shares[Int(((fell - 1) / dt).rounded())], at = shares[Int((fell / dt).rounded()) - 1]
        #expect(before < 0.8 && before > style.cornerWakeMinShare, "\(before) a second before the fall")
        #expect(at < 0.6 && at >= style.cornerWakeMinShare, "\(at) at the fall")
        #expect(effects.cornerTrail.isHidden && (last ?? 1) < 0.01, "gone three seconds after the fall")
    }
}

extension GameScene {
    /// Every boat's wake string in the effects layer.
    var boatTrails: [SKShapeNode] {
        guard let effects = childNode(withName: "//effects") else { return [] }
        return WakeTests.descendants(of: effects).compactMap { $0.1 as? SKShapeNode }.filter { $0.name == "wake" }
    }
}
