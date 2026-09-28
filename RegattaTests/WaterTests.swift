import CoreGraphics
import Foundation
import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The water (#116): the ripple fainter than any visible puff or lull, whitecaps by the conditions' mean wind
/// alone, streaks along the local wind (puff fans included).
@MainActor @Suite struct WaterTests {
    /// Every bundled conditions file: the four conditions (#10) at each version.
    static let conditions: [ConditionsFile] = ["light-and-patchy", "classic-oscillating", "sea-breeze", "gusty-offshore"]
        .flatMap { id in (1...3).compactMap { try? ConditionsFile.bundled(id: id, version: $0) } }

    /// iPhone 17's scene at the default zoom (0.8): what the boat camera shows.
    static func view(centeredOn center: Vec2, scale: CGFloat = 1.25) -> WaterView {
        WaterView(center: CGPoint(x: center.x * 8, y: center.y * 8), sceneSize: CGSize(width: 402, height: 874), scale: scale)
    }

    /// A race on dev-venue@3 in `conditions`@3 (the fun-pass files, #233), run with no one steering to `tick`.
    static func race(_ conditions: String, to tick: Int, seed: UInt64 = 1) throws -> Race {
        let venue = try VenueFile.bundled(id: "dev-venue", version: 3)
        let file = try ConditionsFile.bundled(id: conditions, version: 3)
        let defaults = RaceFiles.defaults
        let files = try RaceFiles(boatClass: defaults.boatClass, venue: venue, conditions: file,
                                  rulesConfiguration: defaults.rulesConfiguration)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: [.human, .bot], venue: venue.ref, conditions: file.ref)
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: WindSeed(seed &* 7919)))
        while race.tick < tick { race.step() }
        return race
    }

    static func world(of race: Race) -> RenderWorld {
        let frame = TickFrame(race: race)
        return RenderWorld(course: race.course, boatClass: race.boatClass, myBoatIndex: 0, previous: frame, current: frame, alpha: 1)
    }

    // MARK: - Acceptance

    /// The ripple is always fainter than a puff or lull (#22): its lightness change on open water is under the
    /// faintest any visible puff or lull makes at its peak (the conditions' weakest puff and weakest lull), in
    /// every conditions file, and under `docs/palette.md`'s 0.12.
    @Test func rippleContrastBelowPuffContrast() throws {
        let style = WaterStyle.standard
        let ripple = WaterTone.rippleDelta(style: style)
        #expect(ripple > 0.02, "the ripple should still show: ΔL \(ripple)")
        #expect(abs(ripple) < ChartPalette.toneDelta)
        #expect(Set(Self.conditions.map(\.id)).count == 4)
        for file in Self.conditions {
            let faintest = WaterTone.faintestPeakDelta(of: file.content, style: style)
            #expect(abs(ripple) < faintest, "\(file.id)@\(file.version): ripple ΔL \(ripple) vs faintest puff or lull \(faintest)")
        }
        // A full-tone puff and lull are the palette's own tokens: ±0.12.
        #expect(abs(WaterTone.puffDelta(intensity: style.fullTonePuffGain, style: style) + ChartPalette.toneDelta) < 0.01)
        #expect(abs(WaterTone.puffDelta(intensity: -style.fullToneLullLoss, style: style) - ChartPalette.toneDelta) < 0.01)
    }

    /// Whitecaps are mood (#22): their share of the water comes from the conditions' mean wind alone. Any patch
    /// of water carries the same share, and the same view draws the same whitecaps whatever the wind where they
    /// are, puff or lull.
    @Test func whitecapDensityIndependentOfPosition() throws {
        let style = WaterStyle.standard
        let shares = Self.conditions.filter { $0.version == 3 }.map { Whitecaps.share(in: $0.content, style: style) }
        // Light and patchy (6-9 kn) has none; the rest rise with their mean wind, gusty offshore (14-20 kn) most.
        #expect(shares.first == 0)
        #expect(shares == shares.sorted() && Set(shares).count == shares.count, "\(shares)")

        let origins = [(0, 0), (4000, -2500), (-12_345, 678), (31, 9999)]
        for share in shares where share > 0 {
            for (x, y) in origins {
                var hits = 0
                for i in x..<x + 60 {
                    for j in y..<y + 60 where Whitecaps.breaks(at: .init(i: i, j: j), cycle: 3, share: share) { hits += 1 }
                }
                let fraction = Double(hits) / 3600
                #expect(abs(fraction - share) < 0.03, "share \(share) at (\(x), \(y)): \(fraction)")
            }
        }

        let gusty = try ConditionsFile.bundled(id: "gusty-offshore", version: 3).content
        let view = Self.view(centeredOn: Vec2(20, -40))
        func whitecaps(windSpeed: Double) -> [RippleLattice.Index] {
            let water = WaterNode(pointsPerMeter: 8)
            let wind = GroundWind(direction: 0.1, speed: windSpeed)
            water.update(WaterWorld(wind: { _ in wind }, courseWind: GroundWind(direction: 0.1, speed: 8), puffs: [],
                                    conditions: gusty, time: 12.5), view: view, dt: 0)
            return water.whitecaps
        }
        let underPuff = whitecaps(windSpeed: 12), underLull = whitecaps(windSpeed: 5)
        #expect(!underPuff.isEmpty)
        #expect(underPuff == underLull)
    }

    /// A streak lies along the wind where it is (#224): inside a puff, turned by the puff's fan, veered on the
    /// puff's right-hand side looking downwind and backed on its left; outside every puff, on the fleet-wide
    /// wind (the mean direction turned by the shift) as the venue bends it.
    @Test func streakInsidePuffAngledByPuffFan() throws {
        // A strong puff clear of every other, so its fan alone turns the wind inside it.
        let race = try Self.race("gusty-offshore", to: -1200)
        var found: Puff?
        while found == nil, race.tick < 1800 {
            for _ in 0..<60 { race.step() }
            let alive = race.wind.activePuffs(atTick: race.tick)
            found = alive.filter { $0.intensity > 0.15 }.first { puff in
                alive.allSatisfy { $0.center == puff.center || ($0.center - puff.center).length > $0.radius + puff.radius }
            }
        }
        let puff = try #require(found, "no puff clear of the others")
        let world = Self.world(of: race)
        let wind = race.wind
        let puffs = world.puffs
        let water = WaterNode(pointsPerMeter: 8)
        water.update(WaterWorld(world), view: Self.view(centeredOn: puff.center), dt: 0)
        #expect(!water.streaks.isEmpty)

        let shift = try wind.shift(atTick: race.tick)
        let downwind = -Vec2.heading(wind.setup.meanDirection)
        var veered = 0, backed = 0, outside = 0
        for streak in water.streaks {
            let local = try #require(world.groundWind(at: streak.position))
            #expect(streak.windDirection == local.direction, "a streak isn't on the wind where it is")
            let venue = wind.setup.pairing.geographicGrid.sample(streak.position).directionDelta
            let fan = wrapAngle(local.direction - (wind.setup.meanDirection + shift + venue))
            let within = puffs.filter { ($0.center - streak.position).length < $0.radius }
            if within.isEmpty {
                #expect(abs(fan) < 1e-9, "a streak outside every puff is turned \(rad2deg(fan))°")
                outside += 1
                continue
            }
            // Only this puff, well off its centre line: its fan alone turns the streak.
            guard within.count == 1, within[0].center == puff.center else { continue }
            let across = (streak.position - puff.center).dot(downwind.rightPerp) / puff.radius
            guard abs(across) > 0.2, (streak.position - puff.center).length < 0.8 * puff.radius else { continue }
            if across > 0 {
                #expect(fan > deg2rad(0.2), "right of the puff: \(rad2deg(fan))°")
                veered += 1
            } else {
                #expect(fan < -deg2rad(0.2), "left of the puff: \(rad2deg(fan))°")
                backed += 1
            }
        }
        #expect(veered > 0 && backed > 0, "streaks veered \(veered), backed \(backed) inside the puff")
        #expect(outside > 0 || puffs.count > 3, "no streak outside a puff to compare")
    }

    // MARK: - The rest of #116

    /// A puff fades in from its key (ADR 0001): no tone at spawn, its intensity's tone at mid-life.
    @Test func puffToneFadesInFromSpawn() {
        let style = WaterStyle.standard
        var puff = Puff(center: .zero, radius: 50, strength: 0.3, age: 0, lifetime: 60)
        #expect(WaterTone.puffOverlay(intensity: puff.intensity, style: style).alpha == 0)
        puff.age = 5
        let early = WaterTone.puffOverlay(intensity: puff.intensity, style: style).alpha
        puff.age = 30
        let peak = WaterTone.puffOverlay(intensity: puff.intensity, style: style)
        #expect(early > 0 && early < peak.alpha)
        #expect(peak.token == ChartPalette.puff && abs(peak.alpha - 1) < 1e-9)
        let lull = WaterTone.puffOverlay(intensity: -0.1, style: style)
        #expect(lull.token == ChartPalette.lull && abs(lull.alpha - 0.5) < 1e-9)
    }

    /// The minimap shows the wind off screen as well as on (#224): the HUD carries every puff and lull alive,
    /// each where it is, its size and its tone.
    @Test func hudCarriesThePuffsForTheMinimap() throws {
        let race = try Self.race("gusty-offshore", to: -600)
        let world = Self.world(of: race)
        let hud = HUDState(world: world)
        #expect(!hud.puffs.isEmpty)
        #expect(hud.puffs.map(\.center) == world.puffs.map(\.center))
        #expect(hud.puffs.map(\.radius) == world.puffs.map(\.radius))
        #expect(hud.puffs.map(\.intensity) == world.puffs.map(\.intensity))
        #expect(hud.puffs.contains { $0.intensity > 0 } && hud.puffs.contains { $0.intensity < 0 })
    }

    /// The minimap's wind is one field, summed the way the race sums puffs: a puff and a lull of one strength in one
    /// place cancel, where two discs would be drawn one over the other. A puff shows over its centre, and nothing
    /// shows well clear of it, however the noise pushes the sampling.
    @Test func minimapWindSumsThePuffs() {
        let puff = MiniPuff(center: Vec2(100, 200), radius: 60, intensity: 0.3)
        let lull = MiniPuff(center: puff.center, radius: 60, intensity: -0.3)
        #expect(MinimapWind.speedChange(at: puff.center, puffs: [puff, lull]) == 0)
        let center = MinimapWind.speedChange(at: puff.center, puffs: [puff])
        #expect(center > 0 && center <= 0.3)
        let clear = puff.radius + MinimapWind.warp * 2
        #expect(MinimapWind.speedChange(at: puff.center + Vec2(clear, 0), puffs: [puff]) == 0)

        // Its pixels, 10 m each over a 400 m square: toned over its centre, clear well away from it.
        let bytes = MinimapWind.pixels(puffs: [puff], world: CGRect(x: 0, y: 0, width: 400, height: 400),
                                       width: 40, height: 40, style: .standard)
        func alpha(at p: Vec2) -> UInt8 { bytes[(Int((400 - p.y) / 10) * 40 + Int(p.x / 10)) * 4 + 3] }
        #expect(alpha(at: puff.center) > 0)
        #expect(alpha(at: Vec2(350, 350)) == 0)
        #expect(MinimapWind.pixels(puffs: [puff, lull], world: CGRect(x: 0, y: 0, width: 400, height: 400),
                                   width: 40, height: 40, style: .standard).allSatisfy { $0 == 0 })
    }

    /// The cheap tier (#127) freezes the ripple and thins the whitecaps; the puff shading is a race cue, drawn the
    /// same in every tier (#27).
    @Test func cheapTierKeepsTheRaceCues() throws {
        let race = try Self.race("gusty-offshore", to: -600)
        let world = WaterWorld(Self.world(of: race))
        let me = race.boats[0].position
        let full = WaterNode(pointsPerMeter: 8), cheap = WaterNode(pointsPerMeter: 8)
        cheap.quality = .cheap
        let conditions = world.conditions
        #expect(Whitecaps.share(in: conditions, style: .standard, quality: .cheap)
            == Whitecaps.share(in: conditions, style: .standard) * WaterStyle.standard.cheapWhitecapShare)

        // The full tier drifts the ripple downwind at its share of the conditions' mean wind; the cheap one holds it.
        let view = Self.view(centeredOn: me)
        full.update(world, view: view, dt: 2)
        cheap.update(world, view: view, dt: 2)
        #expect(cheap.drift == .zero)
        let course = try #require(world.courseWind)
        let expected = -Vec2.heading(course.direction) * (WaterStyle.standard.rippleDrift * Whitecaps.meanWind(of: conditions) * 8 * 2)
        #expect(abs(Double(full.drift.x) - expected.x) < 1e-6 && abs(Double(full.drift.y) - expected.y) < 1e-6)
        // Every cheap streak lies on the course wind.
        #expect(cheap.streaks.allSatisfy { $0.windDirection == course.direction })
    }

    /// A frozen render fixture draws the same pixels on every launch (#62). The view ignores sibling order, so
    /// sprites sharing a z draw in an order of SpriteKit's choosing, which can change between launches: the
    /// streak tiles, in four textures at one z, did, moving a few overlapping pixels a level. So every sprite the
    /// water draws has a z of its own, and the same world through the same view draws the same sprites: on a
    /// fresh node, on one whose pools grew on a wider view first, and again when redrawn settled (dt 0).
    @Test func waterDrawsTheSameEveryTime() throws {
        let race = try Self.race("gusty-offshore", to: -600)
        let world = WaterWorld(Self.world(of: race))
        let me = race.boats[0].position
        var caps = 0, streaks = 0
        for dy in stride(from: -200.0, through: 200, by: 25) {
            let view = Self.view(centeredOn: me + Vec2(0, dy))
            let fresh = WaterNode(pointsPerMeter: 8), used = WaterNode(pointsPerMeter: 8)
            used.update(world, view: Self.view(centeredOn: me, scale: 1 / 0.45), dt: 0)
            fresh.update(world, view: view, dt: 0)
            used.update(world, view: view, dt: 0)
            let water = DrawnSprite.all(under: fresh)
            #expect(water == DrawnSprite.all(under: used), "the pools' history moved the water")
            fresh.update(world, view: view, dt: 0)
            #expect(DrawnSprite.all(under: fresh) == water, "redrawn settled, the water moved")
            let zs = water.map(\.z)
            #expect(Set(zs).count == zs.count, "\(zs.count - Set(zs).count) water sprites share a z")
            caps += fresh.whitecaps.count
            streaks += fresh.streaks.count
        }
        #expect(caps > 0 && streaks > 0, "whitecaps \(caps), streaks \(streaks)")
        #expect(!world.puffs.isEmpty)
    }

    /// The race's water samples the wind through one sampler for the tick (`RenderWorld.windSampler`), which
    /// places the puffs once and bins them, not through `groundWind(at:)` at every tile: in a Debug build that
    /// was over half the frame, and the iOS 27 simulator's main thread didn't keep up at 8× (#232). It draws the
    /// same water, sprite for sprite, at every zoom, drifting or settled.
    @Test func waterSampledOnceATickDrawsTheSameWater() throws {
        let race = try Self.race("gusty-offshore", to: -300)
        let world = Self.world(of: race)
        let sampled = WaterWorld(world)
        var direct = sampled
        direct.wind = world.groundWind(at:)
        let me = race.boats[0].position
        var inPuffs = 0
        for scale in [1.25, 1 / 0.45, 6] as [CGFloat] {
            for dy in stride(from: -300.0, through: 300, by: 100) {
                let view = Self.view(centeredOn: me + Vec2(dy / 2, dy), scale: scale)
                let fast = WaterNode(pointsPerMeter: 8), slow = WaterNode(pointsPerMeter: 8)
                for dt in [0, 0.5] {
                    fast.update(sampled, view: view, dt: dt)
                    slow.update(direct, view: view, dt: dt)
                    #expect(fast.streaks == slow.streaks)
                    #expect(DrawnSprite.all(under: fast) == DrawnSprite.all(under: slow), "scale \(scale), dy \(dy), dt \(dt)")
                }
                inPuffs += fast.streaks.filter { streak in
                    world.puffs.contains { ($0.center - streak.position).length < $0.radius }
                }.count
            }
        }
        #expect(inPuffs > 20, "\(inPuffs) streaks in a puff")
    }

    /// The puffs still read through every colour-vision and viewing filter (#22, #111): the faintest visible puff
    /// and lull stay further from the water than the ripple is, in filtered lightness.
    @Test func puffsStillReadThroughEveryVisionFilter() {
        let style = WaterStyle.standard
        let faintestPuff = WaterTone.puffOverlay(intensity: 0.2, style: style)
        let faintestLull = WaterTone.puffOverlay(intensity: -0.15, style: style)
        for vision in VisionFilter.allCases {
            func lightness(_ rgb: [Double]) -> Double { OKLCH(srgb: vision.apply(rgb)).L }
            let water = lightness(ChartPalette.water.components)
            let ripple = abs(lightness(WaterTone.blend(ChartPalette.lull, alpha: style.rippleAlpha)) - water)
            let puff = abs(lightness(WaterTone.blend(faintestPuff.token, alpha: faintestPuff.alpha)) - water)
            let lull = abs(lightness(WaterTone.blend(faintestLull.token, alpha: faintestLull.alpha)) - water)
            #expect(puff > ripple && lull > ripple, "\(vision): puff \(puff), lull \(lull), ripple \(ripple)")
        }
    }

    /// Every look the water has is data (#229, #232): the style round-trips through JSON, and a scene takes a new
    /// one live.
    @Test func waterStyleIsData() throws {
        var style = WaterStyle.standard
        style.rippleAlpha = 0.3
        style.catspaw = 0.1
        let decoded = try JSONDecoder().decode(WaterStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded == style)
        let session = try GameSession(fixture: RenderFixture(log: "prestart.racelog.json", freezeTick: -1500, camera: .boat, vision: .none),
                                      log: RenderFixture.load(named: "prestart", in: RenderFixtureTests.fixtures).log)
        session.scene.waterStyle = style
        #expect(session.scene.waterStyle == style)
        session.scene.waterQuality = .cheap
        #expect(session.scene.waterQuality == .cheap)
    }

    /// The water's frame cost (#27): the full tier samples the wind at every ripple tile, every frame. Timed over
    /// a busy gusty view at the default zoom, pinched all the way out, and on the course camera, and printed. Held
    /// to a loose budget only in an optimised build (check.sh's): CI's unoptimised Debug build just reports it.
    /// Whatever the scale, the tiles stay about a screen's worth: the course camera is past
    /// `RippleLattice.finestScale`, where the lattice spreads out rather than covering the course tile by tile,
    /// and so is a view far further out, as a bigger course's would be.
    @Test func waterUpdateStaysCheap() throws {
        let race = try Self.race("gusty-offshore", to: -300)
        let world = WaterWorld(Self.world(of: race))
        let me = race.boats[0].position
        let sceneSize = CGSize(width: 402, height: 874)
        let course = try #require(GameScene.courseFraming(race.course, sceneSize: sceneSize, zoom: GameScene.defaultZoom))
        #expect(Double(course.scale) > RippleLattice.finestScale, "course camera scale \(course.scale)")
        #expect(RippleLattice.forView(style: .standard, cameraScale: Double(course.scale)).tileScale > 1)

        // The most tiles any view can take: a view at the finest scale over the finest lattice (a coarser scale
        // spreads the lattice at least as much), with a tile to spare all round and rounding at each end.
        let spacing = WaterStyle.standard.rippleSpacing, finest = RippleLattice.finestScale
        let bound = (Int(Double(sceneSize.width) * finest / spacing) + 5)
            * (Int(Double(sceneSize.height) * finest / (spacing * 0.8)) + 5)
        let courseView = WaterView(center: course.center, sceneSize: sceneSize, scale: course.scale)
        let unspread = RippleLattice(spacing: spacing).indices(covering: courseView.rect, drift: .zero)
        #expect(unspread.columns.count * unspread.rows.count > bound,
                "unspread, the course camera would cover more than the bound of the finest lattice")
        let farOut = WaterView(center: course.center, sceneSize: sceneSize, scale: CGFloat(finest * 8))

        for view in [Self.view(centeredOn: me), Self.view(centeredOn: me, scale: 1 / 0.45), courseView, farOut] {
            let water = WaterNode(pointsPerMeter: 8)
            water.update(world, view: view, dt: 0)
            let frames = 60
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<frames { water.update(world, view: view, dt: 1.0 / 60) }
            }
            let perFrame = elapsed / frames
            let ms = Double(perFrame.components.attoseconds) / 1e15 + Double(perFrame.components.seconds) * 1000
            print("WaterTests: water update at scale \(view.scale): \(String(format: "%.3f", ms)) ms/frame, "
                + "\(water.streaks.count) tiles sampled (at most \(bound)), \(world.puffs.count) puffs alive")
            #expect(!water.streaks.isEmpty && water.streaks.count <= bound,
                    "\(water.streaks.count) tiles at scale \(view.scale), bound \(bound)")
            if !_isDebugAssertConfiguration() {
                #expect(ms < 4, "water update \(ms) ms/frame at scale \(view.scale)")
            }
        }
    }
}

/// A sprite as the water draws it: everything its pixels depend on, its z summed down from the node it's under.
private struct DrawnSprite: Equatable {
    var z: CGFloat
    var position: CGPoint
    var rotation: CGFloat
    var scale: CGSize
    var size: CGSize
    var alpha: CGFloat
    var color: [CGFloat]
    var texture: ObjectIdentifier?
    var textureRect: CGRect?

    /// The visible sprites under `node`, in z order.
    @MainActor static func all(under node: SKNode) -> [DrawnSprite] {
        visible(under: node, z: 0).sorted { $0.z < $1.z }
    }

    @MainActor private static func visible(under node: SKNode, z: CGFloat) -> [DrawnSprite] {
        node.children.filter { !$0.isHidden }.flatMap { child -> [DrawnSprite] in
            let z = z + child.zPosition
            var drawn = visible(under: child, z: z)
            if let sprite = child as? SKSpriteNode {
                drawn.append(DrawnSprite(z: z, position: sprite.position, rotation: sprite.zRotation,
                                         scale: CGSize(width: sprite.xScale, height: sprite.yScale), size: sprite.size,
                                         alpha: sprite.alpha, color: sprite.color.cgColor.components ?? [],
                                         texture: sprite.texture.map(ObjectIdentifier.init),
                                         textureRect: sprite.texture?.textureRect()))
            }
            return drawn
        }
    }
}
