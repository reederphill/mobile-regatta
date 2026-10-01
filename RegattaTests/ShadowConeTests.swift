import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The wind-shadow cone and backwind zone are drawn where core's `ShadowCone` slows boats (#10, #298, #121): from
/// the same class file, checked at sample points through the sprites' own transforms, not only `ShadowShapes`.
@MainActor @Suite struct ShadowConeTests {
    static let boatClass = Race.defaultBoatClass
    static let ppm: CGFloat = 8

    /// A boat heading `headingDegrees` with her boom on `boomSide`, her apparent wind `apparentDegrees` (bent off the
    /// sailing wind's north).
    static func boat(headingDegrees: Double, boomSide: BoomSide, apparentDegrees: Double) -> Boat {
        var boat = Boat(id: 2, isPlayer: false, colorIndex: 2, position: Vec2(40, -25), heading: deg2rad(headingDegrees),
                        speed: 5, boomSide: boomSide)
        boat.status = .racing
        boat.sailingWind = Wind(direction: 0, speed: 6)
        boat.apparentWind = Wind(direction: deg2rad(apparentDegrees), speed: 9)
        return boat
    }

    /// Both tacks, upwind, reaching and running, with the apparent wind bent forward of the true.
    static let cases: [(heading: Double, boom: BoomSide, apparent: Double)] = [
        (-45, .port, -18), (45, .starboard, 18), (-100, .port, -55), (100, .starboard, 55),
        (-160, .port, -120), (160, .starboard, 120),
    ]

    /// `boat`'s effects drawn in a scene, settled, in `boatClass`.
    static func drawn(_ boat: Boat, boatClass: BoatClass) -> (scene: SKScene, effects: BoatEffects) {
        let scene = SKScene(size: CGSize(width: 400, height: 800))
        let effects = BoatEffects(seat: boat.id, boatClass: boatClass, pointsPerMeter: ppm, style: .standard)
        effects.nodes.forEach(scene.addChild)
        scene.addChild(effects.cone) // in a race, a mask in the `ConeLayer` at the effects layer's origin
        let pose = BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass)
        effects.update(with: boat, pose: pose, style: .standard, quality: .full, time: 0, dt: 0, settled: true,
                       isFlogging: false)
        return (scene, effects)
    }

    /// Whether world point `p` (metres) lands inside `sprite`'s drawn outline (`local`, metres in the art's frame),
    /// through the sprite's own position, rotation and scale; and inside the texture the sprite draws.
    static func draws(_ sprite: SKSpriteNode, local: [Vec2], at p: Vec2, in scene: SKScene) -> Bool {
        let point = scene.convert(CGPoint(x: p.x * ppm, y: p.y * ppm), to: sprite)
        // The texture's rect in the sprite's own space, from its size and anchor: the outline must be inside it.
        let rect = CGRect(x: -sprite.anchorPoint.x * sprite.size.width, y: -sprite.anchorPoint.y * sprite.size.height,
                          width: sprite.size.width, height: sprite.size.height)
        let inside = contains(local.map { Vec2($0.x * Double(ppm), $0.y * Double(ppm)) }, Vec2(point.x, point.y))
        return inside && rect.insetBy(dx: -0.01, dy: -0.01).contains(point)
    }

    static func contains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Points just inside and just outside each corner and edge midpoint of `corners`: (point, inside).
    static func samples(_ corners: [Vec2], nudge: Double = 0.15) -> [(Vec2, Bool)] {
        let centre = corners.reduce(Vec2.zero, +) / Double(corners.count)
        var points: [(Vec2, Bool)] = []
        for (i, corner) in corners.enumerated() {
            let next = corners[(i + 1) % corners.count]
            let mid = (corner + next) / 2
            for anchor in [corner, mid] {
                let toward = (centre - anchor).normalized
                points.append((anchor + toward * nudge, true))
                points.append((anchor - toward * nudge, false))
            }
        }
        return points
    }

    /// The cone's sprite covers exactly where core's shadow slows a boat: its corners where `ShadowShapes` puts
    /// them, and at points just inside and outside each corner and edge, the sprite draws where `factor(at:)` is
    /// under 1 and nowhere it is 1, on both tacks with the apparent wind bent.
    @Test func coneGeometryMatchesCoreShadow() {
        let shadow = Self.boatClass.windShadow
        for c in Self.cases {
            let boat = Self.boat(headingDegrees: c.heading, boomSide: c.boom, apparentDegrees: c.apparent)
            let core = ShadowCone(caster: boat, shadow: shadow)
            let (scene, effects) = Self.drawn(boat, boatClass: Self.boatClass)
            let local = ShadowShapes.coneLocal(shadow)

            // The corners through the sprite land on the world corners.
            for (l, world) in zip(local, ShadowShapes.coneCorners(core)) {
                let p = scene.convert(CGPoint(x: l.x * Double(Self.ppm), y: l.y * Double(Self.ppm)), from: effects.cone)
                #expect(abs(p.x / Self.ppm - world.x) < 1e-3 && abs(p.y / Self.ppm - world.y) < 1e-3, "\(c)")
            }
            // Its apex corners are core's half-width at the boat either side of the apex.
            #expect((ShadowShapes.coneCorners(core)[0] - (core.apex - core.axis.rightPerp * core.halfWidth(at: 0))).length < 1e-9)

            var checked = 0
            for (p, inside) in Self.samples(ShadowShapes.coneCorners(core)) where !core.isInBackwind(p) {
                let slowed = core.factor(at: p) < 1
                #expect(slowed == inside, "\(c): core at \(p)")
                #expect(Self.draws(effects.cone, local: local, at: p, in: scene) == slowed, "\(c): sprite at \(p)")
                checked += 1
            }
            #expect(checked >= 12, "\(c)")
            #expect(!effects.cone.isHidden && effects.cone.alpha > 0)
        }
        // A ghost casts none (#30), so draws none.
        let boat = Self.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        let effects = BoatEffects(seat: 2, boatClass: Self.boatClass, pointsPerMeter: Self.ppm, style: .standard)
        effects.update(with: boat, pose: BoatPose(boat, ease: false, isGhost: true, boatClass: Self.boatClass),
                       style: .standard, quality: .full, time: 0, dt: 0, settled: true, isFlogging: false)
        #expect(effects.cone.isHidden && effects.backwind.isHidden && !effects.trail.isHidden)
    }

    /// The fleet's cones draw as one faint layer (#15): every boat's cone a mask in the scene's one `ConeLayer`,
    /// at the effects layer's origin with no turn or scale, so each lands where its own transform puts it, and
    /// one sheet shows through them all at `BoatStyle.coneAlpha`, so overlapping cones darken no line.
    @Test func conesDrawAsOneFaintLayer() throws {
        let (scene, boats) = try DrawOrderTests.scene(fixture: "prestart")
        let effects = try #require(scene.childNode(withName: "//effects"))
        let layers = effects.children.compactMap { $0 as? ConeLayer }
        let layer = try #require(layers.first)
        #expect(layers.count == 1)
        #expect(layer.cones.count == boats && layer.cones.allSatisfy { $0 is SKSpriteNode && $0.alpha == 1 })
        for node in [layer, layer.maskNode] as [SKNode?] {
            #expect(node?.position == .zero && node?.zRotation == 0 && node?.xScale == 1 && node?.yScale == 1)
        }
        #expect(abs(layer.sheet.alpha - CGFloat(BoatStyle.standard.coneAlpha)) < 1e-6) // SpriteKit's Float alpha
        #expect(BoatStyle.standard.coneAlpha <= 0.2, "faint (#15), though seen")
    }

    /// The backwind's sprite covers exactly core's trapezoid (#298) on her windward quarter: at points just inside
    /// and outside each corner and edge, on both tacks, it draws where `isInBackwind` is true and nowhere else, and
    /// it flips side with her tack. A class with #79's band draws none.
    @Test func backwindZoneMatchesCoreZone() throws {
        let shadow = Self.boatClass.windShadow
        #expect(shadow.backwindInnerLength != nil, "the default class casts #298's trapezoid")
        var sides: Set<Bool> = []
        for c in Self.cases {
            let boat = Self.boat(headingDegrees: c.heading, boomSide: c.boom, apparentDegrees: c.apparent)
            let core = ShadowCone(caster: boat, shadow: shadow)
            let (scene, effects) = Self.drawn(boat, boatClass: Self.boatClass)
            let local = try #require(ShadowShapes.backwindLocal(shadow))
            let corners = try #require(ShadowShapes.backwindCorners(core))
            // Running (skiff@5): she casts none, so nothing is drawn and core slows no one.
            #expect(effects.backwind.isHidden == core.isRunning, "\(c)")
            guard !core.isRunning else {
                let inside = corners.reduce(Vec2.zero, +) / 4
                #expect(!core.isInBackwind(inside), "\(c): running, no backwind")
                continue
            }

            for (l, world) in zip(local, corners) {
                let p = scene.convert(CGPoint(x: l.x * Double(Self.ppm), y: l.y * Double(Self.ppm)), from: effects.backwind)
                #expect(abs(p.x / Self.ppm - world.x) < 1e-3 && abs(p.y / Self.ppm - world.y) < 1e-3, "\(c)")
            }
            for (p, inside) in Self.samples(corners, nudge: 0.05) {
                #expect(core.isInBackwind(p) == inside, "\(c): core at \(p)")
                #expect(Self.draws(effects.backwind, local: local, at: p, in: scene) == inside, "\(c): sprite at \(p)")
            }
            // On her windward side, astern.
            let centre = corners.reduce(Vec2.zero, +) / 4 - core.apex
            #expect(centre.dot(core.windward) > 0 && centre.dot(core.forward) < 0, "\(c)")
            sides.insert(effects.backwind.xScale > 0)
        }
        #expect(sides == [true, false], "drawn on both sides")

        // #79's band (no inner length): core has no trapezoid, and nothing is drawn.
        var banded = Self.boatClass
        banded.windShadow.backwindInnerLength = nil
        let boat = Self.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        #expect(ShadowShapes.backwindCorners(ShadowCone(caster: boat, shadow: banded.windShadow)) == nil)
        #expect(Self.drawn(boat, boatClass: banded).effects.backwind.isHidden)
    }
}
