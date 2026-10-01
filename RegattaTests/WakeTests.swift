import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// A boat's wake (#15, #220, #121): its length is her speed through the water, and 16 boats' wakes are sprites
/// sized each frame, never a path rebuilt.
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

    /// 16 boats (#57's fleet) sail on for many frames: the effects layer holds no `SKShapeNode`, so no path is ever
    /// rebuilt, and after the first frame its nodes and their textures stay the same ones; only sizes, positions and
    /// alphas change. Prints the effects' node count for the PR.
    @Test func noShapePathRebuildsAfterFirstFrame() throws {
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
        #expect(shapes == 0)

        var drawnWakes = 0
        for frame in 1...240 {
            session.scene.update(Double(frame) / 60)
            let now = snapshot()
            #expect(now.map(\.0) == first.map(\.0), "frame \(frame): the effects' nodes changed")
            #expect(zip(now, first).allSatisfy { $0.1 === $1.1 }, "frame \(frame): an effect's texture changed")
            #expect(!Self.descendants(of: effects).contains { $0.1 is SKShapeNode }, "frame \(frame)")
            drawnWakes = session.scene.boatWedges.filter { !$0.isHidden && $0.size.height > 1 }.count
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
        #expect(effects.shape?.alpha == 0 && effects.wedge.isHidden)
    }
}

extension GameScene {
    /// Every boat's wake V in the effects layer.
    var boatWedges: [SKSpriteNode] {
        guard let effects = childNode(withName: "//effects") else { return [] }
        return WakeTests.descendants(of: effects).compactMap { $0.1 as? SKSpriteNode }
            .filter { $0.parent?.parent === effects && $0.zPosition == BoatEffects.Layer.wedge }
    }
}
