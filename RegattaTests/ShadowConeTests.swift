import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The backwind zone is drawn where core's `ShadowCone` casts it (#10, #298, #121): from the same class file, checked at
/// sample points through the sprite's own transforms, not only `ShadowShapes`. The wind shadow is the sim's ribbons
/// since #377 (`TurbulenceTrailsTests`), drawn as one faint layer under the fleet's effects.
@MainActor @Suite struct ShadowConeTests {
    static let boatClass = Race.defaultBoatClass
    static let ppm: CGFloat = 8
    /// How near a sprite's `zRotation` lands on an exact angle: SpriteKit keeps it in single precision, so an angle
    /// reads back up to half a float ulp off (about 1e-7 near pi), not within 1e-9 (#354).
    static let rotationTolerance: CGFloat = 1e-6

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

    /// A ghost casts no backwind (#30), so draws none; her wake string drains away as before.
    @Test func ghostDrawsNoBackwind() {
        let boat = Self.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        let effects = BoatEffects(seat: 2, boatClass: Self.boatClass, pointsPerMeter: Self.ppm, style: .standard)
        effects.update(with: boat, pose: BoatPose(boat, ease: false, isGhost: true, boatClass: Self.boatClass),
                       style: .standard, quality: .full, time: 0, dt: 0, settled: true, isFlogging: false)
        #expect(effects.backwind.isHidden && !effects.trail.isHidden)
        #expect(effects.nodes.count == 2, "her backwind and wake string; no cone (#377)")
    }

    /// The fleet's wind shadow draws as one faint layer (#15, #377): the sim's ribbons (`TickFrame.wake`) in the scene's
    /// one `TurbulenceTrailLayer`, at the effects layer's origin with no turn or scale, each sprite no brighter than
    /// `BoatStyle.coneAlpha`, all sharing one shader (#354, #361: a shader per sprite cost the CI simulator a frame's
    /// time over the fleet), and as many drawn as the frame's ribbons have runs that show.
    @Test func ribbonsDrawAsOneFaintLayer() throws {
        let (scene, boats) = try DrawOrderTests.scene(fixture: "prestart")
        let effects = try #require(scene.childNode(withName: "//effects"))
        let layers = effects.children.compactMap { $0 as? TurbulenceTrailLayer }
        let layer = try #require(layers.first)
        #expect(layers.count == 1 && boats > 1)
        #expect(layer.position == .zero && layer.zRotation == 0 && layer.xScale == 1 && layer.yScale == 1)
        let wake = try #require(scene.driver.currentFrame.wake, "a replayed race carries its wake")
        let runs = wake.points.indices.flatMap { wake.ribbons(of: $0, time: scene.driver.renderWorld.time) }
        let showing = runs.filter { run in run.contains { $0.strength > 0 && $0.scale > 0 } }
        #expect(!showing.isEmpty, "the prestart fixture's boats shed ribbons")
        #expect(layer.visibleCount == showing.count)
        let drawn = layer.sprites.filter { !$0.isHidden }
        #expect(drawn.allSatisfy { $0.shader === TurbulenceTrailLayer.shimmer })
        #expect(drawn.allSatisfy { TurbulenceTrailLayer.paint(of: $0).alpha <= BoatStyle.standard.coneAlpha + 1e-6 })
        #expect(BoatStyle.standard.coneAlpha <= 0.4, "faint (#15), though seen: it is only this strong at a ribbon's peak")
    }

    /// The backwind's sprite covers exactly core's zone: on skiff@6 (#377) the header's upwash beside her sail, from her
    /// mast back past her stern to 1.5 L astern of it on her windward side (#298's trapezoid on her windward quarter
    /// before it): at points just
    /// inside and outside each corner and edge, on both tacks, it draws where `isInBackwind` is true and nowhere else,
    /// and it flips side with her tack. A class with #79's band draws none.
    @Test func backwindZoneMatchesCoreZone() throws {
        let shadow = Self.boatClass.windShadow
        #expect(shadow.backwindInnerLength != nil && shadow.backwindUpwash != nil, "the default class casts the upwash zone")
        var sides: Set<Bool> = []
        for c in Self.cases {
            let boat = Self.boat(headingDegrees: c.heading, boomSide: c.boom, apparentDegrees: c.apparent)
            let core = ShadowCone(caster: boat, shadow: shadow)
            let (scene, effects) = Self.drawn(boat, boatClass: Self.boatClass)
            // The sprite's origin is the centre of her stern line, and it is scaled by her speed from there: its own space
            // holds the unscaled outline.
            let local = try #require(ShadowShapes.backwindLocal(shadow)).map { Vec2($0.x, $0.y - shadow.sternCorner.y) }
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
            // On her windward side, from her mast back past her stern to the zone's aft end (#377, the owner's
            // lengthening).
            let centre = corners.reduce(Vec2.zero, +) / 4 - core.apex
            #expect(centre.dot(core.windward) > 0 && centre.dot(core.forward) < 0, "\(c)")
            let extent = try #require(shadow.upwashExtent)
            #expect(extent.aft < shadow.sternCorner.y, "\(c): it runs on astern of her stern")
            #expect(corners.allSatisfy { ($0 - core.apex).dot(core.forward) >= extent.aft - 1e-9
                && ($0 - core.apex).dot(core.forward) <= extent.fore + 1e-9 }, "\(c): from its aft end to her mast")
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

    /// Her backwind trails her (`BoatStyle.shadowFollowSeconds`): after she turns it turns after her, over the time
    /// constant, the short way round, and settles on hers; a settled fixture, or no time constant, draws it at hers.
    @Test func backwindTrailsHerTurn() {
        let boatClass = Self.boatClass
        let before = Self.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        var after = before
        after.heading = deg2rad(-100)
        after.apparentWind = Wind(direction: deg2rad(-55), speed: 9)
        func draw(_ effects: BoatEffects, _ boat: Boat, dt: Double, settled: Bool = false, style: BoatStyle = .standard) {
            effects.update(with: boat, pose: BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass), style: style,
                           quality: .full, time: 0, dt: dt, settled: settled, isFlogging: false)
        }
        let effects = BoatEffects(seat: 2, boatClass: boatClass, pointsPerMeter: Self.ppm, style: .standard)
        draw(effects, before, dt: 0) // the first frame draws at hers
        let backwind0 = effects.backwind.zRotation
        #expect(abs(backwind0 - CGFloat(-before.heading)) < Self.rotationTolerance)

        draw(effects, after, dt: 0.1)
        let backwind1 = effects.backwind.zRotation
        #expect(abs(backwind1 - backwind0) > 1e-3 && abs(backwind1 - CGFloat(-after.heading)) > 1e-3, "partway: the backwind")
        // Towards hers, not away: each step closes on the target.
        let target = CGFloat(-after.heading)
        var last = abs(backwind1 - target)
        // 12 s, 10 time constants (`shadowFollowSeconds` 1.2 s): 0.96 rad left after the first step is 4e-5 then.
        for _ in 0..<120 {
            draw(effects, after, dt: 0.1)
            let now = abs(effects.backwind.zRotation - target)
            #expect(now <= last + Self.rotationTolerance)
            last = now
        }
        #expect(last < 1e-3, "settles on hers")

        // Settled, or with no time constant, it is at hers at once.
        let rigid = BoatEffects(seat: 3, boatClass: boatClass, pointsPerMeter: Self.ppm, style: .standard)
        draw(rigid, before, dt: 0, settled: true)
        draw(rigid, after, dt: 0.1, settled: true)
        #expect(abs(rigid.backwind.zRotation - target) < Self.rotationTolerance)
        var style = BoatStyle.standard
        style.shadowFollowSeconds = 0
        let none = BoatEffects(seat: 4, boatClass: boatClass, pointsPerMeter: Self.ppm, style: style)
        draw(none, before, dt: 0, style: style)
        draw(none, after, dt: 0.1, style: style)
        #expect(abs(none.backwind.zRotation - target) < Self.rotationTolerance)
    }

    /// Across a reach the backwind fades with her true wind angle rather than blinking out: full alpha upwind, a share of
    /// it between the class's fade start and running angle, hidden from the running angle (`ShadowCone.backwindPresence`).
    @Test func backwindFadesAcrossAReach() {
        let shadow = Self.boatClass.windShadow
        var alphas: [Double: CGFloat] = [:]
        for degrees in [45.0, 90, 100, 110, 114, 120] {
            let boat = Self.boat(headingDegrees: degrees, boomSide: .starboard, apparentDegrees: degrees / 2)
            let (_, effects) = Self.drawn(boat, boatClass: Self.boatClass)
            let presence = ShadowCone(caster: boat, shadow: shadow).backwindPresence
            #expect(effects.backwind.isHidden == (presence <= 0), "\(degrees)°")
            alphas[degrees] = effects.backwind.alpha
            if presence > 0 {
                let full = CGFloat(BoatStyle.standard.coneAlpha * BoatStyle.standard.backwindShare)
                #expect(abs(effects.backwind.alpha - full * CGFloat(presence)) < 1e-6, "\(degrees)°")
            }
        }
        #expect(alphas[45] == alphas[90] && alphas[90]! > alphas[100]! && alphas[100]! > alphas[110]! && alphas[110]! > alphas[114]!)
    }

    /// The backwind's edge is soft (`BoatStyle.backwindFeather`): across her hull-side edge its alpha falls from its
    /// inside value to nothing over a few points, centred on core's edge, where with no feather it stops dead.
    @Test func backwindEdgeIsSoft() throws {
        let shadow = Self.boatClass.windShadow
        let boat = Self.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        // Mean alpha over a strip of the art a pixel wide and 24 points tall, 0.3 hull lengths forward of her stern line
        // (half way between her stern and her mast: skiff@6's upwash zone, #377; it was half a length astern of her stern
        // in #298's trapezoid) on her hull-side edge (x = her stern corner), `across` points out from it (negative:
        // outside the zone). Mid-zone, clear of its end fades.
        func alpha(_ effects: BoatEffects, across: CGFloat) throws -> Double {
            let sprite = effects.backwind
            let texture = try #require(sprite.texture)
            let image = try #require(texture.cgImage())
            let size = texture.size()
            let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
            let x = shadow.sternCorner.x * Double(Self.ppm) + Double(across) + Double(sprite.anchorPoint.x * size.width)
            let y0 = 0.3 * Self.boatClass.hull.length * Double(Self.ppm) + Double(sprite.anchorPoint.y * size.height)
            guard x >= 0, x < Double(size.width) else { return 0 }
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var total = 0.0, count = 0.0
            for dy in stride(from: -12.0, through: 12, by: 0.5) {
                let row = Double(image.height) - (y0 + dy) * Double(sy) // the bitmap's rows run top down
                let column = Int(x * Double(sx))
                guard row >= 0, Int(row) < image.height else { continue }
                total += Double(data[(Int(row) * image.width + column) * 4 + 3]) / 255
                count += 1
            }
            return count > 0 ? total / count : 0
        }
        let soft = Self.drawn(boat, boatClass: Self.boatClass).effects
        var hardStyle = BoatStyle.standard
        hardStyle.backwindFeather = 0
        let hardEffects = BoatEffects(seat: boat.id, boatClass: Self.boatClass, pointsPerMeter: Self.ppm, style: hardStyle)

        let inside = try alpha(soft, across: 10), edge = try alpha(soft, across: 0), outside = try alpha(soft, across: -8)
        #expect(inside > 0.2, "inside the zone")
        #expect(edge > outside && edge < inside, "falls across the edge: \(inside) \(edge) \(outside)")
        #expect(outside < inside * 0.4, "mostly gone a few points out")
        #expect(edge > 0.25 * inside && edge < 0.8 * inside, "about half at core's edge")
        // With no feather the same strip stops at the edge: nothing outside, the zone's own alpha just inside.
        #expect(try alpha(hardEffects, across: -2) == 0)
        #expect(try alpha(hardEffects, across: 2) > 0.2)
    }
}
