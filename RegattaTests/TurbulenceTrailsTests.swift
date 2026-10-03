import Foundation
import Metal
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The app's turbulence ribbons (#376 follow-on A) are the prototype's (`TurbulenceRibbons` in
/// `TurbulenceTrailPrototypeTests`, RegattaCore's tests, the reference): the same scene gives the same factors, printed
/// from the prototype once. And the layer draws each unbroken run as one strip, alpha = strength / peak.
@MainActor @Suite struct TurbulenceTrailsTests {
    typealias R = TurbulenceRibbons

    /// Printed from the prototype's `TrailScene.run` on its "tack at t=2" with the warm-up (default parameters):
    /// (probe, seconds, factor).
    static let prototype: [(probe: Int, seconds: Int, factor: Double)] = [
        (0, 0, 0.7580929552922151), (0, 6, 0.68281999487032663), (1, 6, 0.81160100310441541),
        (2, 8, 0.72594514564129708), (3, 8, 0.88764498484913923), (5, 2, 0.75214529488490056),
        (5, 10, 0.95262520307814524), (6, 12, 0.9984005869185798), (0, 8, 1),
    ]
    /// The same with `extraTurnDegrees` 5.
    static let prototypeTurned: [(probe: Int, seconds: Int, factor: Double)] = [
        (0, 6, 0.63530947194774212), (1, 6, 0.76023583542515549), (5, 2, 0.80111472010530738),
        (6, 2, 0.97285132215606318),
    ]

    @Test func factorsMatchThePrototype() {
        let plain = TrailParity.tack(parameters: .init())
        for want in Self.prototype {
            let got = plain[want.probe][want.seconds * Race.tickRate]
            #expect(abs(got - want.factor) < 1e-9, "probe \(want.probe) at \(want.seconds) s: \(got) vs \(want.factor)")
        }
        var turned = R.Parameters()
        turned.extraTurnDegrees = 5
        let turnedRun = TrailParity.tack(parameters: turned)
        for want in Self.prototypeTurned {
            let got = turnedRun[want.probe][want.seconds * Race.tickRate]
            #expect(abs(got - want.factor) < 1e-9, "turned probe \(want.probe) at \(want.seconds) s: \(got) vs \(want.factor)")
        }
    }

    /// The standard style's sliders are the prototype's defaults, so the game's ribbons are the reference's.
    @Test func standardSlidersAreThePrototypeDefaults() {
        let shadow = Race.defaultBoatClass.windShadow
        var style = BoatStyle.standard
        let p = R.Parameters(style: style, shadow: shadow), d = R.Parameters()
        #expect(p.emitSeconds == d.emitSeconds && p.stoppedSpeed == d.stoppedSpeed && p.lengthCap == d.lengthCap)
        #expect(p.extraTurnDegrees == 0 && p.buildSeconds == style.trailBuildSeconds)
        #expect(p.startScale == shadow.coneWidthAtBoat / 2 && p.endScale == shadow.coneWidthAtEnd / 2)
        #expect(p.peak == shadow.lossCloseIn && p.life(apparent: 4.2, shadow: shadow) == shadow.coneLength / 4.2)
        style.trailLifeScale = 2
        style.trailEmitSeconds = 1
        let changed = R.Parameters(style: style, shadow: shadow)
        #expect(changed.life(apparent: 4.2, shadow: shadow) == 2 * shadow.coneLength / 4.2)
        // A live change: `every` follows, the points already shed keep theirs.
        var ribbons = R(shadow: shadow)
        ribbons.step(boats: [TrailParity.fleet(boatClass: Race.defaultBoatClass)[0]], tick: 0)
        let before = ribbons.points[0]
        ribbons.parameters = changed
        #expect(ribbons.every == Race.tickRate && ribbons.points[0].map(\.life) == before.map(\.life))
    }

    /// A stopped boat (under `stoppedSpeed`) and a ghost shed nothing.
    @Test func stoppedBoatEmitsNothing() {
        var boat = TrailParity.fleet(boatClass: Race.defaultBoatClass)[0]
        boat.speed = 0.1
        TrailParity.refresh(&boat)
        var ribbons = R(shadow: Race.defaultBoatClass.windShadow)
        for tick in 0..<(4 * Race.tickRate) { ribbons.step(boats: [boat], tick: tick) }
        #expect(ribbons.pointCount == 0 && ribbons.pointMap(of: 0, tick: 4 * Race.tickRate).isEmpty)
        boat.speed = 3
        TrailParity.refresh(&boat)
        ribbons.step(boats: [boat], tick: 4 * Race.tickRate)
        #expect(ribbons.pointCount == 1)
    }

    /// The emission multiplier: 0 sheds a point with no strength and no scale (it joins nothing); a half halves its
    /// peak, scale and growth, its life and drift unchanged.
    @Test func scaleShrinksAndWeakensWhatABoatSheds() {
        let shadow = Race.defaultBoatClass.windShadow
        let fleet = TrailParity.fleet(boatClass: Race.defaultBoatClass)
        var full = R(shadow: shadow), half = R(shadow: shadow), none = R(shadow: shadow)
        full.step(boats: fleet, tick: 0)
        half.step(boats: fleet, tick: 0, scales: [0.5, 0.5])
        none.step(boats: fleet, tick: 0, scales: [0, 1])
        #expect(full.pointCount == 2 && half.pointCount == 2)
        for (h, f) in zip(half.points.joined(), full.points.joined()) {
            #expect(abs(h.peak - f.peak / 2) < 1e-12 && abs(h.scale - f.scale / 2) < 1e-12)
            #expect(abs(h.growth - f.growth / 2) < 1e-12 && h.life == f.life && h.drift == f.drift)
        }
        #expect(none.points[0].allSatisfy { $0.peak == 0 && $0.scale == 0 })
        #expect(none.points[1].map(\.peak) == full.points[1].map(\.peak))
    }

    /// The level builds back: an ease drops a boat's level at once; sheeted in again it rises linearly over
    /// `buildSeconds` (half way at half the time), so the first points shed after the release are small.
    @Test func trailBuildsBackAfterAnEase() throws {
        let shadow = Race.defaultBoatClass.windShadow
        let boat = TrailParity.fleet(boatClass: Race.defaultBoatClass)[0]
        let build = 2.0
        var parameters = R.Parameters()
        parameters.buildSeconds = build
        var ribbons = R(shadow: shadow, parameters: parameters)
        let full = Race.tickRate, eased = 2 * Race.tickRate
        for tick in 0..<full { ribbons.step(boats: [boat], tick: tick, scales: [1]) }
        #expect(ribbons.levels == [1])
        ribbons.step(boats: [boat], tick: full, scales: [0])
        #expect(ribbons.levels == [0])
        for tick in full + 1..<eased { ribbons.step(boats: [boat], tick: tick, scales: [0]) }
        #expect(ribbons.points[0].filter { $0.born > full }.allSatisfy { $0.peak == 0 })
        // Released at `eased`: after half of `build` the level is a half.
        let half = Int(build / 2 * Double(Race.tickRate))
        for tick in eased..<eased + half { ribbons.step(boats: [boat], tick: tick, scales: [1]) }
        #expect(abs(ribbons.levels[0] - 0.5) < 1e-9)
        let first = try #require(ribbons.points[0].first { $0.born >= eased })
        #expect(first.born == eased && first.scale < 0.05 * shadow.coneWidthAtBoat / 2)
        for tick in eased + half..<eased + 2 * half + 1 { ribbons.step(boats: [boat], tick: tick, scales: [1]) }
        #expect(ribbons.levels == [1])
        // A tack's head to wind (scale 0) drops it again at once.
        ribbons.step(boats: [boat], tick: eased + 2 * half + 1, scales: [0])
        #expect(ribbons.levels == [0])
    }

    /// A boat that eases, then sheets in, draws as two strips: one shed before the ease, ending in a round cap, and
    /// one building back in from nothing after it (no cap at its oldest end), nothing bridging the gap.
    @Test func runBreaksAtAnEase() throws {
        let boatClass = Race.defaultBoatClass
        let shadow = boatClass.windShadow
        var boat = TrailParity.fleet(boatClass: boatClass)[0]
        var parameters = R.Parameters()
        parameters.buildSeconds = 1
        var ribbons = R(shadow: shadow, parameters: parameters)
        // At shares of a point's life, so the points shed before the ease are still alive at the end.
        let life = shadow.coneLength / boat.apparentWind.speed
        // On emission ticks, so the first point after the release is shed at the level's first step up.
        let ticks = { (share: Double) in Int(share * life * Double(Race.tickRate)) / ribbons.every * ribbons.every }
        let ease = ticks(0.3), sheet = ticks(0.5), end = ticks(0.85)
        for tick in 0...end {
            boat.position += boat.velocity * Race.dt
            TrailParity.refresh(&boat)
            ribbons.step(boats: [boat], tick: tick, scales: [tick >= ease && tick < sheet ? 0 : 1])
        }
        let runs = ribbons.ribbons(of: 0, tick: end)
        let strips = runs.filter { $0.count >= 2 }
        #expect(strips.count == 2)
        // The eased points: lone, with nothing.
        #expect(runs.filter { $0.count == 1 }.allSatisfy { $0[0].strength == 0 && $0[0].scale == 0 })
        let after = try #require(strips.last)
        #expect(after[0].strength < 0.1 * ribbons.peak && after[after.count - 1].strength > 0.9 * ribbons.peak)
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        layer.update(runs: runs, peak: ribbons.peak, style: .standard)
        #expect(layer.visibleCount == 2)
        let feather = TurbulenceTrailLayer.featherSteps.count
        let before = TurbulenceTrailLayer.columns(along: strips[0], peak: ribbons.peak)
        let building = TurbulenceTrailLayer.columns(along: after, peak: ribbons.peak)
        let sub = TurbulenceTrailLayer.subColumns + 1
        // Before the ease: capped at its newest end, where the ease cut it off (shed at full strength, faded since).
        #expect(before.last?.u == 0 && before[before.count - 1 - feather].u > TurbulenceTrailLayer.taperShare)
        // Building back: tapers in from nothing at its oldest end, capped at the boat.
        #expect(building.count == (after.count - 1) * sub + 1 + feather)
        #expect(building[0].u < TurbulenceTrailLayer.taperShare && building.last?.u == 0)
    }

    /// The strip's vertex alpha (its source u) is strength / peak at every point, the sub-columns linear between, and
    /// its rows sit the point's scale either side of the centre; a lone point is a disc; the rest hidden.
    @Test func stripAlphaIsStrengthOverPeak() throws {
        let peak = 0.4
        func live(_ x: Double, _ strength: Double, _ scale: Double) -> R.Live {
            R.Live(position: Vec2(x, 0), strength: strength, scale: scale)
        }
        // A run fading out at its oldest end, strong at its newest; a lone point; an empty point.
        let run = [live(0, 0.01, 4), live(4, 0.2, 3), live(8, 0.4, 2)]
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        layer.update(runs: [run, [live(20, 0.2, 2)], [live(30, 0, 0)]], peak: peak, style: .standard)
        #expect(layer.visibleCount == 2)
        let strip = layer.sprites[0]
        #expect(strip.texture === TurbulenceTrailLayer.strip && strip.shader === TurbulenceTrailLayer.shimmer)
        #expect(abs(Double(strip.alpha) - BoatStyle.standard.coneAlpha) < 1e-6)
        #expect(abs(strip.zPosition - BoatEffects.Layer.cones) < 1e-6)
        let grid = try #require(strip.warpGeometry as? SKWarpGeometryGrid)
        let sub = TurbulenceTrailLayer.subColumns + 1, feather = TurbulenceTrailLayer.featherSteps.count
        // No cap at the faded end, a cap at the strong one.
        let columns = 2 * sub + 1 + feather
        #expect(grid.numberOfColumns == columns - 1 && grid.numberOfRows == 2)
        for (i, point) in run.enumerated() {
            for row in 0..<3 {
                #expect(abs(Double(grid.sourcePosition(at: row * columns + i * sub).x) - point.strength / peak) < 1e-6)
            }
        }
        // Half way between the first two points: linear.
        #expect(abs(Double(grid.sourcePosition(at: 2).x) - (0.01 + 0.2) / 2 / peak) < 1e-6)
        func point(_ index: Int) -> CGPoint {
            let p = grid.destPosition(at: index)
            return CGPoint(x: strip.position.x + CGFloat(p.x) * strip.size.width,
                           y: strip.position.y + CGFloat(p.y) * strip.size.height)
        }
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(a.x - x) < 1e-3 && abs(a.y - y) < 1e-3 }
        // The middle point's edges ± its scale across the track, in points (8 a metre).
        #expect(near(point(sub), 32, -24) && near(point(2 * columns + sub), 32, 24) && near(point(columns + sub), 32, 0))
        // The cap: a scale past the newest point, closed and clear.
        #expect(near(point(columns - 1), 80, 0) && grid.sourcePosition(at: columns - 1).x == 0)
        let disc = layer.sprites[1]
        #expect(disc.warpGeometry == nil && disc.texture === TurbulenceTrailLayer.disc)
        #expect(abs(Double(disc.alpha) - BoatStyle.standard.coneAlpha * 0.5) < 1e-6)
        // Fewer runs: the pool stays, the rest hide.
        layer.update(runs: [run], peak: peak, style: .standard)
        #expect(layer.sprites.count == 2 && layer.visibleCount == 1)
        layer.update(runs: [], peak: peak, style: .standard)
        #expect(layer.visibleCount == 0)
    }

    /// Each caster's ribbons carry her own fleck seed, so where boats' ribbons overlap their flecks don't move in step
    /// (owner, #376 A); a run without a caster gets seed 0.
    @Test func castersSeedTheirOwnFlecks() throws {
        func live(_ x: Double, _ y: Double) -> R.Live { R.Live(position: Vec2(x, y), strength: 0.3, scale: 2) }
        let a = [live(0, 0), live(4, 0)], b = [live(0, 1), live(4, 1)], lone = [live(10, 0)]
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        layer.update(runs: [a, b, lone], casters: [0, 5, 5], peak: 0.4, style: .standard)
        #expect(layer.visibleCount == 3)
        let seeds = try layer.sprites.prefix(3).map { try #require($0.value(forAttributeNamed: "a_seed")).floatValue }
        #expect(seeds == [0, 5, 5])
        layer.update(runs: [b], peak: 0.4, style: .standard)
        #expect(try #require(layer.sprites[0].value(forAttributeNamed: "a_seed")).floatValue == 0)
    }

    /// The shimmer's frame (`pixelFrame`, `setView`) puts a world point where the nodes draw it, through a camera
    /// that's moved, zoomed and turned, on a 3× drawable, in a scene under a moved layer: a shader disc around each
    /// of three world points lands on a node disc there within a pixel. Rendered through Metal (`SKRenderer`, like the
    /// screen: `gl_FragCoord` from the top left), not `texture(from:)`, which counts from the bottom.
    @Test func shimmerFrameSitsOnTheWater() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let viewSize = CGSize(width: 100, height: 200), pixelScale: CGFloat = 3, ppm: CGFloat = 8
        let width = Int(viewSize.width * pixelScale), height = Int(viewSize.height * pixelScale)
        let scene = SKScene(size: viewSize)
        scene.scaleMode = .aspectFit
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.backgroundColor = .clear
        let layer = SKNode()
        layer.position = CGPoint(x: 7, y: -3)
        scene.addChild(layer)
        let camera = SKCameraNode()
        camera.position = CGPoint(x: 40, y: -25)
        camera.setScale(1.6)
        camera.zRotation = 0.5
        scene.addChild(camera)
        scene.camera = camera
        let target = SKUniform(name: "u_target", vectorFloat2: .zero)
        let shaderDisc = SKSpriteNode(color: .white, size: CGSize(width: 2000, height: 2000))
        shaderDisc.shader = SKShader(source: """
        void main() {
            vec2 d = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y - u_target;
            d -= \(TurbulenceTrailLayer.period) * floor(d / \(TurbulenceTrailLayer.period) + 0.5);
            float a = length(d) < 0.6 ? 1.0 : 0.0;
            gl_FragColor = vec4(a, a, a, a);
        }
        """, uniforms: TurbulenceTrailLayer.frameUniforms + [target])
        let nodeDisc = SKShapeNode(circleOfRadius: 0.6 * ppm)
        nodeDisc.fillColor = .white
        nodeDisc.strokeColor = .clear
        layer.addChild(nodeDisc)
        camera.addChild(shaderDisc)

        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        // The centroid, pixels from the top left, of what draws; nil when nothing does (the shader compiles in the
        // background: a frame drawn before it's ready draws nothing at all).
        func render() throws -> CGPoint? {
            renderer.update(atTime: CACurrentMediaTime())
            let frame = TurbulenceTrailLayer.pixelFrame(viewSize: viewSize, pixelScale: pixelScale, sceneSize: scene.size,
                                                        camera: camera, layer: layer, metresPerPoint: 1 / Double(ppm))
            TurbulenceTrailLayer.setView(pixel: frame, time: 0)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            let buffer = try #require(queue.makeCommandBuffer())
            renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: buffer,
                            renderPassDescriptor: pass)
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            var sum = CGPoint.zero, count = 0.0
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
                    sum.x += CGFloat(x) + 0.5; sum.y += CGFloat(y) + 0.5; count += 1
                }
            }
            return count > 20 ? CGPoint(x: sum.x / count, y: sum.y / count) : nil
        }
        func renderWhenReady() async throws -> CGPoint {
            for _ in 0..<200 {
                if let centroid = try render() { return centroid }
                try await Task.sleep(for: .milliseconds(20))
            }
            return try #require(nil as CGPoint?, "nothing drew")
        }
        // Points around the screen, in the camera's own points (the frame wraps by the shimmer's period).
        for local in [CGPoint(x: -20, y: 30), CGPoint(x: 25, y: -40), CGPoint(x: 0, y: 0)] {
            let at = layer.convert(local, from: camera)
            nodeDisc.position = at
            target.vectorFloat2Value = vector_float2(Float(at.x / ppm), Float(at.y / ppm))
            nodeDisc.isHidden = false; shaderDisc.isHidden = true
            let node = try await renderWhenReady()
            nodeDisc.isHidden = true; shaderDisc.isHidden = false
            let shader = try await renderWhenReady()
            print("shimmer frame at \(local): node \(node), shader \(shader)")
            #expect(hypot(node.x - shader.x, node.y - shader.y) < 1, "\(local): node \(node), shader \(shader)")
        }
    }

    /// The backwind stripes show what the sim does (#376 B): at the header-and-lull model a boat's backwind is scaled by
    /// her sail multiplier, so her stripes' alpha takes the scene's ribbon level for her seat (none eased, head to wind,
    /// building back after a tack); at the box, and before a level is known, they draw as before.
    @Test func backwindStripesFollowTheSail() {
        #expect(GameScene.backwindSail(model: .box, levels: [0, 0.5], seat: 1) == 1)
        #expect(GameScene.backwindSail(model: .headerAndLull, levels: [0, 0.5], seat: 1) == 0.5)
        #expect(GameScene.backwindSail(model: .headerAndLull, levels: [0, 0.5], seat: 0) == 0)
        #expect(GameScene.backwindSail(model: .headerAndLull, levels: nil, seat: 0) == 1)
        #expect(GameScene.backwindSail(model: .headerAndLull, levels: [0.5], seat: 3) == 1)
        let boatClass = ShadowConeTests.boatClass
        let boat = ShadowConeTests.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        func stripes(_ sail: Double) -> (alpha: CGFloat, hidden: Bool) {
            let effects = BoatEffects(seat: 2, boatClass: boatClass, pointsPerMeter: ShadowConeTests.ppm, style: .standard)
            effects.update(with: boat, pose: BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass),
                           style: .standard, quality: .full, time: 0, dt: 0, settled: true, isFlogging: false,
                           backwindSail: sail)
            return (effects.backwind.alpha, effects.backwind.isHidden)
        }
        let full = stripes(1), half = stripes(0.5), none = stripes(0)
        #expect(!full.hidden && full.alpha > 0)
        #expect(!half.hidden && abs(half.alpha - full.alpha / 2) < 1e-6)
        #expect(none.hidden, "no working sail: no stripes")
    }

    /// The sail's angle to her apparent wind, as drawn: about the default full angle sailing the upwind groove (so
    /// she sheds her full turbulence there), none with the sheets out on a beat or head to wind, full on a run.
    @Test func sailAngleScalesTheTurbulence() {
        let boatClass = Race.defaultBoatClass
        let style = BoatStyle.standard
        let sail = R.Parameters(style: style, shadow: boatClass.windShadow)
        let groove = TrailParity.fleet(boatClass: boatClass)[0]
        let aoa = rad2deg(BoatPose.angleOfAttack(groove, ease: false, boatClass: boatClass, style: style))
        #expect(abs(aoa - style.trailFullAngleDegrees) < 1)
        #expect(BoatPose.angleOfAttack(groove, ease: true, boatClass: boatClass, style: style) == 0)
        #expect(abs(R.scale(of: groove, ease: false, boatClass: boatClass, parameters: sail) - 1) < 0.02)
        var head = groove
        head.heading = 0
        TrailParity.refresh(&head)
        #expect(R.scale(of: head, ease: false, boatClass: boatClass, parameters: sail) == 0)
        var run = groove
        run.heading = .pi * 0.9
        TrailParity.refresh(&run)
        #expect(R.scale(of: run, ease: false, boatClass: boatClass, parameters: sail) == 1)
        var half = style
        half.trailFullAngleDegrees = 2 * aoa
        #expect(abs(R.scale(of: groove, ease: false, boatClass: boatClass, parameters: R.Parameters(style: half, shadow: boatClass.windShadow)) - 0.5) < 1e-9)
    }

    /// Core's emission target (`TurbulenceRibbons.angleOfAttack`, which the sim's wake reads, #376 B) is the drawn
    /// sail's angle (`BoatPose.angleOfAttack`) on a grid of true wind angles, both sides, eased or not, head to wind
    /// and by the lee: the two can't drift apart.
    @Test func sailMultiplierMatchesTheDrawnAngle() {
        let boatClass = Race.defaultBoatClass
        var styles = [BoatStyle.standard]
        var other = BoatStyle.standard
        other.trimPerApparentAngle = 0.4
        other.minTrimDegrees = 6
        other.maxTrimDegrees = 80
        other.headToWindMarginDegrees = 4
        styles.append(other)
        var checked = 0, headToWind = 0, byTheLee = 0
        for style in styles {
            let sail = R.Parameters(style: style, shadow: boatClass.windShadow)
            for twaDegrees in stride(from: 20.0, through: 185, by: 2.5) {
                for side in [-1.0, 1.0] {
                    for ease in [false, true] {
                        // Sailing at the twa, the boom on her leeward side; past 180 the boom stays: by the lee.
                        var boat = TrailParity.boat(0, .zero, heading: side * deg2rad(twaDegrees), speed: 3)
                        if twaDegrees > 180 { boat.boomSide = side > 0 ? .starboard : .port }
                        let drawn = BoatPose.angleOfAttack(boat, ease: ease, boatClass: boatClass, style: style)
                        let core = R.angleOfAttack(boat, ease: ease, boatClass: boatClass, parameters: sail)
                        #expect(abs(drawn - core) < 1e-12, "twa \(twaDegrees) side \(side) ease \(ease): \(drawn) vs \(core)")
                        let full = deg2rad(style.trailFullAngleDegrees)
                        #expect(abs(R.scale(of: boat, ease: ease, boatClass: boatClass, parameters: sail)
                                    - (drawn / full).clamped(to: 0...1)) < 1e-12)
                        checked += 1
                        if drawn == 0 && !ease { headToWind += 1 }
                        if boat.isByTheLee { byTheLee += 1 }
                    }
                }
            }
        }
        #expect(checked > 200 && headToWind > 0 && byTheLee > 0)
    }

    /// A style saved before the ribbon sliders loads with the prototype's defaults.
    @Test func savedStyleLoadsTheRibbonDefaults() throws {
        let style = try JSONDecoder().decode(BoatStyle.self, from: Data(#"{"trailBuildSeconds": 3}"#.utf8))
        #expect(style.trailBuildSeconds == 3 && style.trailTuning.dropLast() == BoatStyle.standard.trailTuning.dropLast())
        var tuned = BoatStyle.standard
        tuned.trailExtraTurnDegrees = 5
        tuned.trailLengthCap = 9
        let back = try JSONDecoder().decode(BoatStyle.self, from: JSONEncoder().encode(tuned))
        #expect(back.trailExtraTurnDegrees == 5 && back.trailLengthCap == 9)
    }

    #if DEBUG
    /// `-shadowDrawing cones|trails|both` (Debug builds): a value of its own, a bad one rejected.
    @Test func launchArgumentPicksTheDrawing() {
        func parse(_ arguments: String...) -> LaunchOptions { LaunchOptions(arguments: ["Regatta"] + arguments) }
        #expect(parse().shadowDrawing == nil)
        #expect(parse("-shadowDrawing", "trails").shadowDrawing == .trails)
        #expect(parse("-autostart", "-shadowDrawing", "both", "-demo").shadowDrawing == .both)
        let bad = parse("-shadowDrawing", "boxes")
        #expect(bad.shadowDrawing == nil && bad.problems == ["-shadowDrawing boxes: expected cones, trails or both"])
        #expect(parse("-shadowDrawing", "-demo").problems == ["-shadowDrawing needs a value"])
    }

    /// A saved tuning from before the drawing loads as the cones.
    @Test func savedTuningsLoadAsTheRibbons() throws {
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data("{}".utf8))
        #expect(tuning.shadowDrawing == .trails && ShadowDrawing.standard == .trails)
        var cones = Tuning()
        cones.shadowDrawing = .cones
        #expect(try JSONDecoder().decode(Tuning.self, from: cones.jsonData()).shadowDrawing == .cones)
    }

    /// `-shadowModel boxes|ribbons|both` and `-backwindModel box|headerAndLull` (#376 B, Debug builds).
    @Test func launchArgumentsPickTheSimModels() {
        func parse(_ arguments: String...) -> LaunchOptions { LaunchOptions(arguments: ["Regatta"] + arguments) }
        #expect(parse().shadowModel == nil && parse().backwindModel == nil)
        let both = parse("-shadowModel", "ribbons", "-backwindModel", "headerAndLull", "-demo")
        #expect(both.shadowModel == .ribbons && both.backwindModel == .headerAndLull && both.demo && both.problems.isEmpty)
        let bad = parse("-shadowModel", "cones", "-backwindModel", "header")
        #expect(bad.shadowModel == nil && bad.backwindModel == nil)
        #expect(bad.problems == ["-shadowModel cones: expected boxes, ribbons or both",
                                 "-backwindModel header: expected box or headerAndLull"])
        #expect(parse("-backwindModel", "-demo").problems == ["-backwindModel needs a value"])
    }

    /// A tuning saved before the sim's models loads them at the defaults, today's sim; a saved choice comes back; and
    /// the defaults make `ShadowSettings()`'s models, header and lull.
    @Test func savedTuningsLoadAsTheDefaultSettings() throws {
        let old = try JSONDecoder().decode(Tuning.self, from: Data(#"{"shadowDrawing": "cones"}"#.utf8))
        #expect(old.simShadow == SimShadowTuning() && !old.isTuned)
        let boatClass = Race.defaultBoatClass
        let settings = old.simShadow.settings(style: .standard, boatClass: boatClass)
        let d = ShadowSettings()
        #expect(settings.shadowModel == .boxes && settings.backwindModel == .box && settings.lullLoss == d.lullLoss)
        #expect(settings.headerDegrees == d.headerDegrees && settings.headerCapDegrees == d.headerCapDegrees
                && settings.headerTimeConstant == d.headerTimeConstant)
        #expect(settings.ribbons == R.Parameters(style: .standard, shadow: boatClass.windShadow))
        var tuned = Tuning()
        tuned.simShadow.shadowModel = .both
        tuned.simShadow.backwindModel = .headerAndLull
        tuned.simShadow.lullShare = 0.5
        let back = try JSONDecoder().decode(Tuning.self, from: tuned.jsonData())
        #expect(back.simShadow == tuned.simShadow && !back.isTuned)
        #expect(back.simShadow.settings(style: .standard, boatClass: boatClass).lullLoss == 0.5 * boatClass.windShadow.backwindLoss)
        let partial = try JSONDecoder().decode(SimShadowTuning.self, from: Data(#"{"backwindModel": "headerAndLull", "shadowModel": "fog"}"#.utf8))
        #expect(partial.backwindModel == .headerAndLull && partial.shadowModel == .boxes && partial.headerDegrees == d.headerDegrees)
    }
    #endif
}

@MainActor enum TrailParity {
    /// A steady 10 kn from 0 in still water (the prototype's `TrailScene`).
    static let wind = Wind(direction: 0, speed: metresPerSecond(knots: 10))

    static func refresh(_ b: inout Boat) {
        b.apparentWind = BoatWinds.resolve(ground: wind, current: .zero, velocityThroughWater: b.velocity).apparent
        b.boomSide = b.relativeWind > 0 ? .port : .starboard
    }

    static func boat(_ id: Int, _ position: Vec2, heading: Double, speed: Double) -> Boat {
        var b = Boat(id: id, isPlayer: false, colorIndex: id, position: position, heading: heading, speed: speed)
        b.windOverGround = wind
        b.sailingWind = wind
        refresh(&b)
        return b
    }

    /// Two boats on the upwind groove: seat 0 at the origin, seat 1 3 hull lengths down her shadow.
    static func fleet(boatClass: BoatClass) -> [Boat] {
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        let caster = boat(0, .zero, heading: -best.twa, speed: best.speed)
        let other = ShadowCone(caster: caster, shadow: boatClass.windShadow).axis * (3 * boatClass.hull.length)
        return [caster, boat(1, other, heading: -best.twa, speed: best.speed)]
    }

    /// The prototype's `TrailScene.run` on its "tack at t=2" in the default class, warmed up: the ribbon factor at each
    /// of its seven probes (in its order), every tick for `seconds`.
    static func tack(parameters: TurbulenceRibbons.Parameters, seconds: Double = 15) -> [[Double]] {
        let boatClass = Race.defaultBoatClass
        let shadow = boatClass.windShadow, hull = boatClass.hull.length
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        let twa = best.twa, fast = best.speed
        func smooth(_ x: Double) -> Double { let t = x.clamped(to: 0...1); return t * t * (3 - 2 * t) }
        func steer(_ t: Double) -> (heading: Double, speed: Double) {
            let k = smooth((t - 2) / 3)
            let dip = 1 - 0.45 * Foundation.sin(Double.pi * ((t - 2) / 7).clamped(to: 0...1))
            return (-twa + k * 2 * twa, fast * dip)
        }
        var caster = boat(0, .zero, heading: steer(0).heading, speed: steer(0).speed)
        let start = ShadowCone(caster: caster, shadow: shadow)
        let v0 = caster.velocity
        let downwind = Vec2.heading(.pi)
        let apparentLine = -Vec2.heading(start.apparentWindDirection)
        let probes: [(offset: Vec2, sailsOn: Bool)] = [
            (start.axis * (3 * hull), true), (apparentLine * (3 * hull), true),
            (start.axis * (6 * hull), true), (apparentLine * (6 * hull), true),
            (start.axis * (6 * hull), false), (downwind * (3 * hull), false), (downwind * (6 * hull), false),
        ]
        var series = probes.map { _ in [Double]() }
        var ribbons = TurbulenceRibbons(shadow: shadow, parameters: parameters)
        let apparent = max(caster.apparentWind.speed, 0.5)
        let warm = 1.2 * (parameters.life(apparent: apparent, shadow: shadow))
        let ticks = Int((warm * Double(Race.tickRate)).rounded(.up))
        caster.position = v0 * (-Double(ticks) * Race.dt)
        for tick in -ticks..<0 {
            caster.position += caster.velocity * Race.dt
            refresh(&caster)
            ribbons.step(boats: [caster], tick: tick)
        }
        caster.position = .zero
        for tick in 0..<Int(seconds * Double(Race.tickRate)) {
            let t = Double(tick) * Race.dt
            let (h, s) = steer(t)
            caster.heading = h
            caster.speed = s
            caster.position += caster.velocity * Race.dt
            refresh(&caster)
            ribbons.step(boats: [caster], tick: tick)
            for (i, p) in probes.enumerated() {
                series[i].append(ribbons.factor(at: p.offset + (p.sailsOn ? v0 * t : .zero), tick: tick, receiver: 1))
            }
        }
        return series
    }
}
