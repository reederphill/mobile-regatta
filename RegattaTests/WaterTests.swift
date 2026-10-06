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
        // So is any pressure lane at its peak, in every file with a pressure field (#289); and the pressure is the
        // palette's tones too, at full tone ±0.12 (#289, and more sensitive, 0.10, since the lanes are finite).
        let pressureFiles = [6, 7].flatMap { version in
            ["light-and-patchy", "classic-oscillating", "sea-breeze", "gusty-offshore"]
                .map { try? ConditionsFile.bundled(id: $0, version: version) }
        }
        #expect(pressureFiles.allSatisfy { $0?.content.pressureField != nil })
        for file in pressureFiles.compactMap({ $0 }) {
            let faintest = try #require(WaterTone.faintestPressureDelta(of: file.content, style: style))
            #expect(abs(ripple) < faintest, "\(file.id)@\(file.version): ripple ΔL \(ripple) vs faintest pressure lane \(faintest)")
        }
        #expect(abs(WaterTone.pressureDelta(style.fullTonePressureGain, style: style) + ChartPalette.toneDelta) < 0.01)
        #expect(abs(WaterTone.pressureDelta(-style.fullTonePressureLoss, style: style) - ChartPalette.toneDelta) < 0.01)
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

    /// The pressure fixture (#289): dev-venue@6 and gusty-offshore@6, a pressure field with lanes, its side and
    /// the venue's geography, frozen after the gun.
    static func pressureWorld() throws -> RenderWorld {
        let (fixture, log) = try RenderFixture.load(named: "water-pressure", in: RenderFixtureTests.fixtures)
        return try FixtureDriver(log: log, freezeTick: fixture.freezeTick).renderWorld
    }

    /// The water's tone at a point follows the pressure there (#289): each sample of the tone is the model's own
    /// pressure at its point (`WindSampler.pressureFactor(at:)`), and its pixel darkens the water with more
    /// pressure and lightens it with less, by the pressure's lightness change to within a pixel's rounding. The
    /// tone lies under the puffs and covers the view, and on the fixture's water it varies.
    @Test func waterDrawsThePressure() throws {
        let world = try Self.pressureWorld()
        let sampler = try #require(world.windSampler)
        #expect(sampler.pressureReading.map { !$0.lanes.isEmpty } == true)
        let style = WaterStyle.standard
        let me = world.me.position
        var lowest = Double.infinity, highest = -Double.infinity
        for view in [Self.view(centeredOn: me), Self.view(centeredOn: me, scale: 6)] {
            let water = WaterNode(pointsPerMeter: 8)
            water.update(WaterWorld(world), view: view, dt: 0)
            let (grid, tone) = try #require(water.pressure)
            #expect(grid.rect.contains(view.rect))
            #expect(tone.columns == grid.columns.count && tone.rows == grid.rows.count && tone.boost == 1)
            let pixels = tone.pixels(style: style)
            var samples: [(pressure: Double, lightness: Double)] = []
            for (row, j) in grid.rows.enumerated() {
                for (column, i) in grid.columns.enumerated() {
                    let point = grid.position(i, j)
                    let pressure = tone.pressure(column: column, row: row)
                    #expect(pressure == sampler.pressureFactor(at: Vec2(Double(point.x), Double(point.y)) / 8) - 1)
                    // The pixel, premultiplied, over the water.
                    let k = ((tone.rows - 1 - row) * tone.columns + column) * 4
                    let alpha = Double(pixels[k + 3]) / 255
                    let rgb = (0..<3).map { Double(pixels[k + $0]) / 255 + ChartPalette.water.components[$0] * (1 - alpha) }
                    let lightness = OKLCH(srgb: rgb).L - ChartPalette.water.oklch.L
                    #expect(abs(lightness - WaterTone.pressureDelta(pressure, style: style)) < 0.01,
                            "pressure \(pressure): ΔL \(lightness)")
                    samples.append((pressure, lightness))
                    lowest = min(lowest, pressure)
                    highest = max(highest, pressure)
                }
            }
            // Darker where more, in order.
            let ordered = samples.sorted { $0.pressure < $1.pressure }
            for (a, b) in zip(ordered, ordered.dropFirst()) where b.pressure - a.pressure > 0.01 {
                #expect(b.lightness <= a.lightness + 0.005, "\(a) then \(b)")
            }
            let sprite = try #require(water.children.first { $0.name == WaterNode.pressureName } as? SKSpriteNode)
            #expect(!sprite.isHidden && sprite.texture != nil)
            #expect(abs(sprite.frame.minX - grid.rect.minX) < 1e-3 && abs(sprite.frame.maxY - grid.rect.maxY) < 1e-3
                && abs(sprite.frame.width - grid.rect.width) < 1e-3 && abs(sprite.frame.height - grid.rect.height) < 1e-3)
            #expect(sprite.zPosition < 0, "the pressure draws under the puffs")
        }
        #expect(highest - lowest > 0.1, "the fixture's pressure is flat: \(lowest)…\(highest)")
        #expect(lowest < 0 && highest > 0)
    }

    /// The minimap samples the model's own field at its pixels (#289): the HUD carries the pressure over the
    /// minimap's chart (course-up on the race area, #114, cached by `MinimapField`), each sample the sampler's pressure at the middle of its cell of the chart, and the minimap
    /// draws them stretched over exactly that chart, a pixel a sample. The same model as the water's: where the
    /// water samples the same point, it draws the same pressure.
    @Test func minimapDrawsThePressure() throws {
        let world = try Self.pressureWorld()
        let sampler = try #require(world.windSampler)
        let chart = MinimapChart(course: world.course)
        let tone = chart.pressure(sampler)
        // The HUD draws exactly this tone's image (`MinimapField`).
        let field = MinimapField()
        let drawn = try #require(field.refresh(world))
        #expect(field.chart == chart && drawn.width == tone.columns && drawn.height == tone.rows)
        #expect(tone.columns == MinimapChart.pressureColumns && tone.rows == chart.pressureRows && tone.boost == 1)
        for row in 0..<tone.rows {
            for column in 0..<tone.columns {
                let point = chart.pressurePoint(column: column, row: row)
                #expect(tone.pressure(column: column, row: row) == sampler.pressureFactor(at: point) - 1)
            }
        }
        // The cells tile the chart: the first's middle is half a cell in, the last's half a cell short.
        // In course coordinates: across the axis (u) and up it (v), the chart course-up.
        let cellX = (chart.maxU - chart.minU) / Double(tone.columns), cellY = (chart.maxV - chart.minV) / Double(tone.rows)
        #expect(abs(chart.courseCoordinates(chart.pressurePoint(column: 0, row: 0)).u - (chart.minU + cellX / 2)) < 1e-9)
        #expect(abs(chart.courseCoordinates(chart.pressurePoint(column: tone.columns - 1, row: tone.rows - 1)).v
            - (chart.maxV - cellY / 2)) < 1e-9)
        #expect(abs(cellX - cellY) < 0.05 * cellX, "square samples: \(cellX) × \(cellY) m")
        // Drawn over the chart exactly, its corners where the chart's corners draw.
        let size = CGSize(width: 110, height: 150)
        let rect = chart.rect(in: size)
        let southWest = chart.point(chart.position(u: chart.minU, v: chart.minV), in: size)
        let northEast = chart.point(chart.position(u: chart.maxU, v: chart.maxV), in: size)
        #expect(abs(rect.minX - southWest.x) < 1e-9 && abs(rect.maxY - southWest.y) < 1e-9)
        #expect(abs(rect.maxX - northEast.x) < 1e-9 && abs(rect.minY - northEast.y) < 1e-9)
        let image = try #require(tone.image(style: .standard))
        #expect(image.width == tone.columns && image.height == tone.rows)
        let spread = tone.pressures.max()! - tone.pressures.min()!
        #expect(spread > 0.1, "the fixture's pressure is flat on the minimap: \(spread)")
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

        // The pressure is a race cue (#289): the cheap tier draws it exactly as the full one, on the same grid with
        // the same samples, so it is pixel for pixel the same at every thermal tier (#127).
        let pressured = try Self.pressureWorld()
        let sampler = try #require(pressured.windSampler)
        let pressureView = Self.view(centeredOn: pressured.me.position)
        full.update(WaterWorld(pressured), view: pressureView, dt: 0)
        cheap.update(WaterWorld(pressured), view: pressureView, dt: 0)
        let fullTone = try #require(full.pressure), cheapTone = try #require(cheap.pressure)
        #expect(cheapTone.grid == fullTone.grid)
        #expect(cheapTone.tone.pressures == fullTone.tone.pressures)
        #expect(cheapTone.grid.rect.contains(pressureView.rect))
        for (row, j) in cheapTone.grid.rows.enumerated() {
            for (column, i) in cheapTone.grid.columns.enumerated() {
                let point = cheapTone.grid.position(i, j)
                #expect(cheapTone.tone.pressure(column: column, row: row)
                    == sampler.pressureFactor(at: Vec2(Double(point.x), Double(point.y)) / 8) - 1)
            }
        }
        #expect(cheapTone.tone.pixels(style: .standard).contains { $0 > 0 }, "the cheap tier drew no pressure")
    }

    /// A frozen render fixture draws the same pixels on every launch (#62). The view ignores sibling order, so
    /// sprites sharing a z draw in an order of SpriteKit's choosing, which can change between launches: the
    /// streak tiles, in four textures at one z, did, moving a few overlapping pixels a level. So every sprite the
    /// water draws has a z of its own, and the same world through the same view draws the same sprites: on a
    /// fresh node, on one whose pools grew on a wider view first, and again when redrawn settled (dt 0).
    ///
    /// The pressure's texture is made anew from its samples (#289), so it is compared by its samples and pixels:
    /// the same on each, and in every tier.
    @Test func waterDrawsTheSameEveryTime() throws {
        let race = try Self.race("gusty-offshore", to: -600)
        let world = WaterWorld(Self.world(of: race))
        let me = race.boats[0].position
        var caps = 0, streaks = 0
        let pressured = try Self.pressureWorld()
        for quality in [WaterQuality.full, .cheap] {
            for dy in stride(from: -200.0, through: 200, by: 100) {
                let view = Self.view(centeredOn: pressured.me.position + Vec2(0, dy))
                let fresh = WaterNode(pointsPerMeter: 8), used = WaterNode(pointsPerMeter: 8)
                fresh.quality = quality
                used.quality = quality
                used.update(WaterWorld(pressured), view: Self.view(centeredOn: pressured.me.position, scale: 1 / 0.45), dt: 0)
                fresh.update(WaterWorld(pressured), view: view, dt: 0)
                used.update(WaterWorld(pressured), view: view, dt: 0)
                let a = try #require(fresh.pressure), b = try #require(used.pressure)
                #expect(a.grid == b.grid && a.tone == b.tone)
                #expect(a.tone.pixels(style: .standard) == b.tone.pixels(style: .standard))
                #expect(DrawnSprite.all(under: fresh) == DrawnSprite.all(under: used))
                fresh.update(WaterWorld(pressured), view: view, dt: 0)
                #expect(try #require(fresh.pressure).tone == a.tone, "redrawn settled, the pressure moved")
            }
        }
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

extension WaterTests {
    /// A turned view (course-up and boat-up, #113) draws the bounding box of its turned rectangle: up to 2.3 times
    /// an upright view's area at 45°. The ripple lattice and the pressure grid spread by that area, so at any scale
    /// and angle a turned view takes no more tiles than `waterUpdateStaysCheap`'s bound, nor more pressure samples
    /// than an upright view at the finest scale; upright, nothing changes.
    @Test func turnedViewStaysInsideTheTileBound() throws {
        let race = try Self.race("gusty-offshore", to: -300)
        let world = WaterWorld(Self.world(of: race))
        let me = race.boats[0].position
        let sceneSize = CGSize(width: 402, height: 874)
        let spacing = WaterStyle.standard.rippleSpacing, finest = RippleLattice.finestScale
        let bound = (Int(Double(sceneSize.width) * finest / spacing) + 5)
            * (Int(Double(sceneSize.height) * finest / (spacing * 0.8)) + 5)
        let samples = (Int(Double(sceneSize.width) * finest / PressureGrid.fullSpacing) + 5)
            * (Int(Double(sceneSize.height) * finest / PressureGrid.fullSpacing) + 5)

        let upright = Self.view(centeredOn: me)
        #expect(upright.spreadScale == Double(upright.scale))
        #expect(upright.rect == CGRect(x: upright.center.x - 402 * 1.25 / 2, y: upright.center.y - 874 * 1.25 / 2,
                                       width: 402 * 1.25, height: 874 * 1.25))

        for scale in [1.25, 1 / 0.45, finest, finest * 1.5, finest * 4] {
            for degrees in [0.0, 15, 30, 45, 60, 90, 135, -45] {
                var view = Self.view(centeredOn: me, scale: CGFloat(scale))
                view.rotation = CGFloat(degrees * .pi / 180)
                // The rect holds every corner of the turned view.
                let rect = view.rect.insetBy(dx: -0.001, dy: -0.001)
                for (sx, sy) in [(-1.0, -1.0), (-1, 1), (1, -1), (1, 1)] {
                    let x = sx * 402 * scale / 2, y = sy * 874 * scale / 2
                    let r = Double(view.rotation)
                    let corner = CGPoint(x: Double(view.center.x) + x * cos(r) - y * sin(r),
                                         y: Double(view.center.y) + x * sin(r) + y * cos(r))
                    #expect(rect.contains(corner), "scale \(scale), \(degrees)°")
                }
                let water = WaterNode(pointsPerMeter: 8)
                water.update(world, view: view, dt: 0)
                #expect(!water.streaks.isEmpty && water.streaks.count <= bound,
                        "\(water.streaks.count) tiles at scale \(scale), \(degrees)°, bound \(bound)")
                let grid = try #require(water.pressure?.grid)
                #expect(grid.columns.count * grid.rows.count <= samples,
                        "\(grid.columns.count * grid.rows.count) samples at scale \(scale), \(degrees)°, bound \(samples)")
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
    /// Nil for the pressure's, made anew each frame: compared by its samples instead.
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
                                         texture: sprite.name == WaterNode.pressureName ? nil : sprite.texture.map(ObjectIdentifier.init),
                                         textureRect: sprite.texture?.textureRect()))
            }
            return drawn
        }
    }
}

/// Saved water tunings from older builds (#289).
@MainActor @Suite struct WaterStyleDecodeTests {
    /// A tuning saved before #289 has no pressure fields in its water: it keeps its tuned water values and
    /// the pressure fields take their standard defaults, rather than the whole water falling back to standard.
    @Test func preTwoEightyNineWaterKeepsItsTuning() throws {
        let water = """
        {"rippleSpacing": 96, "rippleAlpha": 0.4, "rippleDrift": 0.12, "fullTonePuffGain": 0.42,
         "fullToneLullLoss": 0.2, "catspaw": 0.3, "whitecapOnsetKnots": 9, "whitecapFullKnots": 20,
         "whitecapMaxShare": 0.5, "whitecapAlpha": 0.85, "whitecapSeconds": 3.5, "cheapWhitecapShare": 0.5}
        """
        let style = try JSONDecoder().decode(WaterStyle.self, from: Data(water.utf8))
        #expect(style.fullTonePuffGain == 0.42)
        #expect(style.fullTonePressureGain == WaterStyle.standard.fullTonePressureGain)
        #expect(style.fullTonePressureLoss == WaterStyle.standard.fullTonePressureLoss)

        let tuning = try JSONDecoder().decode(Tuning.self, from: Data("{\"water\": \(water)}".utf8))
        #expect(tuning.water.fullTonePuffGain == 0.42)
        #expect(tuning.water.fullTonePressureGain == WaterStyle.standard.fullTonePressureGain)
    }
}
