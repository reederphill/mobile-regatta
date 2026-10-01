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

    /// A roll miss kills her wake while the sail flogs and it comes back after; a hit flares it, briefly (#222).
    @Test func rollCuesFlareAndKillTheWake() {
        let style = BoatStyle.standard
        let effects = BoatEffects(seat: 1, boatClass: Self.boatClass, pointsPerMeter: 8, style: style)
        var boat = Self.boat(speed: 6)
        let calm = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
        effects.update(with: boat, pose: calm, style: style, quality: .full, time: 0, dt: 0, settled: true,
                       isFlogging: false)
        let even = effects.shape?.alpha ?? 0
        #expect(even > 0)

        boat.roll = .hit
        let hit = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
        effects.update(with: boat, pose: hit, style: style, quality: .full, time: 1, dt: 0, settled: true,
                       isFlogging: false)
        #expect((effects.shape?.length ?? 0) > WakeShape(boat, boatClass: Self.boatClass, style: style, quality: .full).length)
        effects.update(with: boat, pose: hit, style: style, quality: .full, time: 1 + style.wakeFlareSeconds + 0.1,
                       dt: 0, settled: true, isFlogging: false)
        #expect(effects.shape?.alpha == even, "the flare is over")

        boat.roll = .missed
        let miss = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass)
        effects.update(with: boat, pose: miss, style: style, quality: .full, time: 3, dt: 0, settled: true,
                       isFlogging: true)
        #expect(effects.shape?.alpha == 0 && effects.trail.isHidden)
    }
}

extension GameScene {
    /// Every boat's wake string in the effects layer.
    var boatTrails: [SKShapeNode] {
        guard let effects = childNode(withName: "//effects") else { return [] }
        return WakeTests.descendants(of: effects).compactMap { $0.1 as? SKShapeNode }
    }
}
