import Foundation
import Metal
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The wind shadow drawn (#376 follow-on A, #377): the sim's own ribbons (`Race.wake`), carried on each `TickFrame`, so
/// the scene draws exactly what the sim sails; each unbroken run one strip, alpha = strength / peak, with a shimmer
/// fixed in the water. The backwind stripes take the sim's backwind level and held side. The ribbon model's own tests
/// are RegattaCore's (`WakeRibbonsTests`).
@MainActor @Suite struct TurbulenceTrailsTests {
    typealias R = TurbulenceRibbons

    /// The frames the app draws and the sim agree through a tack (#377): a practice race's frames (`PracticeDriver`,
    /// the app's own path, `TickFrame(race:)`) carry, tick by tick, the wake and backwind levels and sides that the race
    /// replayed from its log holds at the same tick. Through the tack her stripes fade on the side they were cast on
    /// past her boom crossing before building on the new one, and the layer draws a strip for every run that shows.
    /// On skiff@7, whose autohelm sails the tap that tacks her here (the default, skiff@8, has none, #458).
    @Test func sceneAndSimAgreeOverATack() throws {
        var config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 377, windSeed: RaceConfig.windSeed(pinnedTo: 377))
        config.files.boatClass = try BoatClassFile.bundled(id: "skiff", version: 7).ref
        let driver = PracticeDriver(config: config)
        let me = driver.myBoatIndex
        let dt = 1 / Double(Race.tickRate)
        for _ in 0..<(8 * Race.tickRate) { driver.tick(dt) }
        let before = driver.currentFrame.boats[me].tack
        #expect(driver.tap(.tackGybe))
        var frames: [TickFrame] = []
        for _ in 0..<(8 * Race.tickRate) { frames += driver.tick(dt) }
        let frame = driver.currentFrame
        #expect(frames.last?.tick == frame.tick)
        #expect(frame.boats[me].tack != before, "she tacked")

        // The race the log replays to, at the frame's tick: the same wake and backwind, exactly.
        let race = try Replayer.replay(driver.log, requireMatchingVersion: false)
        #expect(race.tick == frame.tick)
        let wake = try #require(frame.wake)
        #expect(wake == race.wake)
        #expect(wake.pointCount > 0, "the fleet sheds ribbons")
        #expect(frame.backwindSails == race.boats.indices.map { race.backwindSail(ofSeat: $0) })
        #expect(frame.backwindSides == race.boats.indices.map { race.backwindSide(ofSeat: $0) })

        // Her stripes through the tack: never a jump across at the boom crossing (her side held while it shows).
        var heldPastTheCrossing = false
        for f in frames {
            let world = RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: me, previous: f,
                                    current: f, alpha: 1)
            let stripes = world.backwind(ofSeat: me)
            #expect(stripes.sail >= 0 && stripes.sail <= 1)
            if stripes.sail > 0, let side = stripes.side, side != f.boats[me].tack { heldPastTheCrossing = true }
        }
        #expect(frames.map { $0.backwindSails[me] }.min() ?? 1 < 1, "her backwind faded through the tack")
        if !heldPastTheCrossing {
            // Faded to nothing before her boom crossed: then the side changes only once it has gone.
            for f in frames where f.backwindSides[me] != nil && f.backwindSides[me] != f.boats[me].tack {
                #expect(f.backwindSails[me] == 0)
            }
        }

        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        layer.update(wake: frame.wake, time: frame.time, style: .standard)
        let runs = wake.points.indices.flatMap { wake.ribbons(of: $0, time: frame.time) }
        #expect(layer.visibleCount == runs.filter { run in run.contains { $0.strength > 0 && $0.scale > 0 } }.count)
        layer.update(wake: nil, time: frame.time, style: .standard)
        #expect(layer.visibleCount == 0)
    }

    /// A boat that eases, then sheets in, draws as two strips: one shed before the ease, ending in a round cap, and
    /// one building back in from nothing after it (no cap at its oldest end), nothing bridging the gap.
    @Test func runBreaksAtAnEase() throws {
        let boatClass = Race.defaultBoatClass
        let shadow = boatClass.windShadow
        var boat = TrailParity.fleet(boatClass: boatClass)[0]
        var ribbons = R(shadow: shadow)
        // At shares of a point's life, so the points shed before the ease are still alive at the end.
        let life = shadow.ribbons.life(apparent: boat.apparentWind.speed, coneLength: shadow.coneLength)
        // On emission ticks, so the first point after the release is shed at the level's first step up.
        let ticks = { (share: Double) in Int(share * life * Double(Race.tickRate)) / ribbons.every * ribbons.every }
        let ease = ticks(0.2), sheet = ticks(0.4), end = ticks(0.85)
        #expect(Double(end - sheet) * Race.dt > shadow.ribbons.buildSeconds, "built back to full by the end")
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
        #expect(abs(TurbulenceTrailLayer.paint(of: strip).alpha - BoatStyle.standard.coneAlpha) < 1e-6 && strip.alpha == 1)
        #expect(abs(strip.zPosition - BoatEffects.Layer.ribbons) < 1e-6, "the pool's first slot")
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
        #expect(abs(TurbulenceTrailLayer.paint(of: disc).alpha - BoatStyle.standard.coneAlpha * 0.5) < 1e-6)
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
        let seeds = layer.sprites.filter { !$0.isHidden }.map { TurbulenceTrailLayer.paint(of: $0).seed }
        #expect(seeds == [0, 5, 5])
        layer.update(runs: [b], peak: 0.4, style: .standard)
        #expect(TurbulenceTrailLayer.paint(of: layer.sprites[0]).seed == 0)
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

    /// A fleet's ribbons draw through Metal (`SKRenderer`, like the screen): many long strips and discs, changing
    /// frame to frame, in one batch. The app crashed in a race copying a per-sprite shader attribute (the seed) for
    /// the warped strips (#377's first CI run: `SKAttributeValue copyValueTo` in SpriteKit's batching; it didn't
    /// reproduce here), so each caster's seed rides on the sprite's colour instead (`paint`): the same strip drawn for
    /// another caster draws other flecks.
    @Test func fleetRibbonsRenderThroughMetal() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let ppm: CGFloat = 8
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.backgroundColor = .clear
        let layer = TurbulenceTrailLayer(pointsPerMeter: ppm)
        scene.addChild(layer)
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        func live(_ x: Double, _ y: Double, _ strength: Double) -> R.Live {
            R.Live(position: Vec2(x, y), strength: strength, scale: 1.5)
        }
        // 16 casters, each long wavy strips (their lengths changing frame to frame) and discs, all over the view; the
        // mix of strips and discs changes every frame.
        func fleet(_ frame: Int) -> (runs: [[R.Live]], casters: [Int]) {
            let shift = Double(frame) * 0.1
            var runs: [[R.Live]] = [], casters: [Int] = []
            for c in 0..<16 {
                for k in 0..<(1 + (c + frame) % 3) {
                    let y = Double(c) * 1.5 - 12 + Double(k) * 0.7
                    let count = (c + k + frame) % 4 == 0 ? 1 : 10 + (7 * c + 13 * k + frame) % 110
                    runs.append((0..<count).map { i in
                        live(Double(i) * 0.3 - 15 + shift, y + sin(Double(i) * 0.4 + shift),
                             0.1 + 0.3 * Double(i) / Double(max(1, count - 1)))
                    })
                    casters.append(c)
                }
                runs.append([live(Double(c) - 8, 10, 0.4)])
                casters.append(c)
            }
            return (runs, casters)
        }
        // The pixels drawn; nil when nothing does (the shader compiles in the background).
        func render() throws -> [UInt8]? {
            renderer.update(atTime: CACurrentMediaTime())
            TurbulenceTrailLayer.setView(pixel: { x, y in Vec2((x - 100) / Double(ppm), (100 - y) / Double(ppm)) },
                                         time: 3)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 200, height: 200,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            let buffer = try #require(queue.makeCommandBuffer())
            renderer.render(withViewport: CGRect(x: 0, y: 0, width: 200, height: 200), commandBuffer: buffer,
                            renderPassDescriptor: pass)
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixels = [UInt8](repeating: 0, count: 200 * 200 * 4)
            texture.getBytes(&pixels, bytesPerRow: 200 * 4, from: MTLRegionMake2D(0, 0, 200, 200), mipmapLevel: 0)
            return pixels.contains { $0 > 0 } ? pixels : nil
        }
        func renderWhenReady() async throws -> [UInt8] {
            for _ in 0..<200 {
                if let pixels = try render() { return pixels }
                try await Task.sleep(for: .milliseconds(20))
            }
            return try #require(nil as [UInt8]?, "nothing drew")
        }
        let peak = 0.4
        for frame in 0..<120 {
            let f = fleet(frame)
            layer.update(runs: f.runs, casters: f.casters, peak: peak, style: .standard)
            _ = try await renderWhenReady()
        }
        // One strip, drawn for caster 0 and then for caster 5: the same envelope, other flecks.
        let strip = (0..<20).map { i in live(Double(i) - 10, 0, peak) }
        layer.update(runs: [strip], casters: [0], peak: peak, style: .standard)
        let a = try await renderWhenReady()
        layer.update(runs: [strip], casters: [5], peak: peak, style: .standard)
        let b = try await renderWhenReady()
        let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count
        #expect(differing > 100, "\(differing) bytes differ between casters' flecks")
    }

    /// The backwind stripes show what the sim does (#377): a boat's stripes' alpha is her backwind level
    /// (`RenderWorld.backwind(ofSeat:)`, from the frame), none with no working sail, on the side it is held on.
    @Test func backwindStripesFollowTheSail() {
        let port = ShadowConeTests.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        let full = Self.stripes(port, sail: 1, side: nil), half = Self.stripes(port, sail: 0.5, side: nil)
        let none = Self.stripes(port, sail: 0, side: nil)
        #expect(!full.hidden && full.alpha > 0)
        #expect(!half.hidden && abs(half.alpha - full.alpha / 2) < 1e-6)
        #expect(none.hidden, "no working sail: no stripes")
        let held = Self.stripes(port, sail: 1, side: port.tack == .starboard ? .port : .starboard)
        #expect(held.xScale == -full.xScale, "on the side it was cast on")
        // A frame with no backwind levels (the help legend's) draws them full, on her side now.
        let race = PracticeDriver(config: RaceConfig(opponents: 1, seed: 377, windSeed: RaceConfig.windSeed(pinnedTo: 377)))
        let frame = TickFrame(tick: 0, boats: [port], standings: [0], wind: race.currentFrame.wind, isOver: false)
        let world = RenderWorld(course: race.course, boatClass: ShadowConeTests.boatClass, myBoatIndex: 0,
                                previous: frame, current: frame, alpha: 1)
        #expect(world.backwind(ofSeat: 0) == (1, nil) && world.backwind(ofSeat: 3) == (1, nil))
    }

    /// Below the class's floor speed she casts no backwind, so draws none; it builds in over the span above it (#377).
    @Test func backwindStripesFadeInAboveTheFloor() throws {
        let shadow = ShadowConeTests.boatClass.windShadow
        let floor = try #require(shadow.backwindFloorSpeed)
        var boat = ShadowConeTests.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        let full = Self.stripes(boat, sail: 1, side: nil)
        boat.speed = floor * 0.9
        #expect(Self.stripes(boat, sail: 1, side: nil).hidden)
        boat.speed = floor + shadow.backwindFloorSpan / 2
        let half = Self.stripes(boat, sail: 1, side: nil)
        #expect(!half.hidden && abs(half.alpha - full.alpha / 2) < 1e-6)
    }

    /// `boat`'s backwind stripes drawn settled with `sail` and `side`: their alpha, whether hidden, and their side
    /// (the sprite's x scale, 1 on starboard tack's windward side).
    static func stripes(_ boat: Boat, sail: Double, side: Tack?) -> (alpha: CGFloat, hidden: Bool, xScale: CGFloat) {
        let boatClass = ShadowConeTests.boatClass
        let effects = BoatEffects(seat: 2, boatClass: boatClass, pointsPerMeter: ShadowConeTests.ppm, style: .standard)
        effects.update(with: boat, pose: BoatPose(boat, ease: false, isGhost: false, boatClass: boatClass),
                       style: .standard, quality: .full, time: 0, dt: 0, settled: true,
                       backwindSail: sail, backwindSide: side)
        return (effects.backwind.alpha, effects.backwind.isHidden, effects.backwind.xScale)
    }

    /// Through a tack the stripes fade out on the side they were cast on, never jumping across at the boom crossing, and
    /// once gone build on the new side (#376 B, the owner: "it disappears too abruptly"): `BackwindSails`, the sim's,
    /// stepped through a luff, a boom crossing and the new tack at the class's build and fade, drawn each tick.
    @Test func backwindStripesFadeOnTheirSideThroughATack() {
        let shadow = ShadowConeTests.boatClass.windShadow
        let starboard = ShadowConeTests.boat(headingDegrees: -45, boomSide: .port, apparentDegrees: -18)
        let port = ShadowConeTests.boat(headingDegrees: 45, boomSide: .starboard, apparentDegrees: 18)
        #expect(starboard.tack == .starboard && port.tack == .port)
        var sails = BackwindSails()
        let build = shadow.ribbons.buildSeconds, fade = shadow.backwindFadeSeconds
        #expect(build == 2 && fade == 1.5, "the owner's placeholders")
        func step(_ boat: Boat, _ scale: Double) -> (alpha: CGFloat, hidden: Bool, xScale: CGFloat, level: Double) {
            sails.step(boats: [boat], scales: [scale], buildSeconds: build, fadeSeconds: fade)
            let drawn = Self.stripes(boat, sail: sails.levels[0], side: sails.sides[0])
            return (drawn.alpha, drawn.hidden, drawn.xScale, sails.levels[0])
        }
        let trimmed = step(starboard, 1)
        #expect(!trimmed.hidden && trimmed.xScale == 1)
        // Head to wind for 0.5 s, then the boom crosses: the stripes have faded a third and stay on starboard's side.
        var last = trimmed
        for _ in 0..<(Race.tickRate / 2) {
            let now = step(starboard, 0)
            #expect(now.alpha < last.alpha && now.xScale == 1)
            last = now
        }
        var ticks = 0, sides: [CGFloat] = []
        while last.level > 0 && ticks < 3 * Race.tickRate {
            // On port now, trimmed in again, but the old zone fades out first, where it was.
            last = step(port, 1)
            ticks += 1
            if last.level > 0 { sides.append(last.xScale) }
        }
        #expect(last.level == 0 && last.hidden)
        #expect(!sides.isEmpty && sides.allSatisfy { $0 == 1 }, "faded on the old side past the boom crossing")
        #expect(abs(Double(ticks + Race.tickRate / 2) * Race.dt - fade) <= 2 * Race.dt, "gone over 1.5 s: \(ticks) ticks after the crossing")
        // Then it builds on the new side over 2 s.
        let first = step(port, 1)
        #expect(!first.hidden && first.xScale == -1 && first.alpha < trimmed.alpha / 10)
        var up = 1
        while step(port, 1).level < 1 && up < 3 * Race.tickRate { up += 1 }
        #expect(abs(Double(up + 1) * Race.dt - build) <= 2 * Race.dt, "full on port in 2 s: \(up) ticks")
    }

    /// The sim's working sail (`SailTrim.standard`, which sets the ribbons' emission and the backwind) is the drawn
    /// sail's angle (`BoatPose.angleOfAttack` at `BoatStyle.standard`) on a grid of true wind angles, both sides, eased or
    /// not, head to wind and by the lee, to 1e-12: the two can't drift apart. About the class's full angle on the
    /// upwind groove.
    @Test func sailMultiplierMatchesTheDrawnAngle() {
        let boatClass = Race.defaultBoatClass
        let style = BoatStyle.standard
        let trim = SailTrim.standard
        #expect(style.trimPerApparentAngle == trim.perApparentAngle && style.minTrimDegrees == trim.minTrimDegrees)
        #expect(style.maxTrimDegrees == trim.maxTrimDegrees && style.headToWindMarginDegrees == trim.headToWindMarginDegrees)
        var checked = 0, headToWind = 0, byTheLee = 0
        for twaDegrees in stride(from: 20.0, through: 185, by: 2.5) {
            for side in [-1.0, 1.0] {
                for ease in [false, true] {
                    // Sailing at the twa, the boom on her leeward side; past 180 the boom stays: by the lee.
                    var boat = TrailParity.boat(0, .zero, heading: side * deg2rad(twaDegrees), speed: 3)
                    if twaDegrees > 180 { boat.boomSide = side > 0 ? .starboard : .port }
                    let drawn = BoatPose.angleOfAttack(boat, ease: ease, boatClass: boatClass, style: style)
                    let core = trim.angleOfAttack(boat, ease: ease, boatClass: boatClass)
                    #expect(abs(drawn - core) < 1e-12, "twa \(twaDegrees) side \(side) ease \(ease): \(drawn) vs \(core)")
                    let full = boatClass.windShadow.ribbons.fullAngle
                    #expect(abs(trim.workingScale(of: boat, ease: ease, boatClass: boatClass)
                                - (drawn / full).clamped(to: 0...1)) < 1e-12)
                    checked += 1
                    if drawn == 0 && !ease { headToWind += 1 }
                    if boat.isByTheLee { byTheLee += 1 }
                }
            }
        }
        #expect(checked > 200 && headToWind > 0 && byTheLee > 0)
        let groove = TrailParity.fleet(boatClass: boatClass)[0]
        let aoa = BoatPose.angleOfAttack(groove, ease: false, boatClass: boatClass)
        #expect(abs(rad2deg(aoa) - rad2deg(boatClass.windShadow.ribbons.fullAngle)) < 1)
    }
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

    /// Two boats on the upwind groove: seat 0 at the origin, seat 1 3 hull lengths down her apparent wind.
    static func fleet(boatClass: BoatClass) -> [Boat] {
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        let caster = boat(0, .zero, heading: -best.twa, speed: best.speed)
        let other = ShadowCone(caster: caster, shadow: boatClass.windShadow).axis * (3 * boatClass.hull.length)
        return [caster, boat(1, other, heading: -best.twa, speed: best.speed)]
    }
}
