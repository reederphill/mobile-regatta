import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The app's turbulence trails (#376 follow-on A) are the prototype's (`TurbulenceTrailPrototypeTests` in RegattaCore's
/// tests, the reference): the same scene gives the same factors, printed from the prototype's model once. And the layer
/// draws a ribbon a caster and kind.
@MainActor @Suite struct TurbulenceTrailsTests {
    /// Printed from the prototype's `TurbulenceTrails` on `TrailParity`'s scene (the default class).
    static let prototype: [Double] = [1, 0.82444011624698443, 0.92180166715991441, 0.85173926921858512, 1, 141]

    @Test func factorsMatchThePrototype() {
        let factors = TrailParity.factors(boatClass: Race.defaultBoatClass)
        #expect(factors.count == Self.prototype.count)
        for (got, want) in zip(factors, Self.prototype) { #expect(abs(got - want) < 1e-9, "\(got) vs \(want)") }
    }

    /// A ribbon a caster and kind, feathered at both ends; a lone sample is its disc; the rest hidden.
    @Test func layerDrawsARibbonACasterAndKind() throws {
        let shadow = Race.defaultBoatClass.windShadow
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        func sample(_ x: Double, caster: Int = 0, backwind: Bool = false) -> TurbulenceTrails.Sample {
            TurbulenceTrails.Sample(position: Vec2(x, 0), drift: Vec2(0, -1), born: 0, caster: caster,
                                    peak: backwind ? shadow.backwindLoss : shadow.lossCloseIn, radius: 2, growth: 0.5,
                                    life: 10, isBackwind: backwind)
        }
        // Caster 0: a cone ribbon of three and a lone backwind; caster 1: a lone cone.
        let five = [sample(0), sample(4), sample(8), sample(0, backwind: true), sample(20, caster: 1)]
        layer.update(samples: five, time: 1, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 3)
        // Drifted, grown and faded: at 1 s of 10, 2.5 m a side, 1 m down, at 90% of the hatch.
        let hatch = BoatStyle.standard.coneAlpha * 0.9
        let strip = layer.sprites[0]
        #expect(strip.texture === TurbulenceTrailLayer.strip && strip.shader === TurbulenceTrailLayer.shimmer)
        // The strip's own alpha is the hatch; its texture carries the fade (u = life left).
        #expect(abs(Double(strip.alpha) - BoatStyle.standard.coneAlpha) < 1e-6)
        let grid = try #require(strip.warpGeometry as? SKWarpGeometryGrid)
        // Three samples and three feather columns at each end.
        let columns = 3 + 2 * TurbulenceTrailLayer.featherSteps.count
        #expect(grid.numberOfColumns == columns - 1 && grid.numberOfRows == 2)
        #expect(abs(Double(grid.sourcePosition(at: 3).x) - 0.9) < 1e-6)
        func point(_ index: Int) -> CGPoint {
            let p = grid.destPosition(at: index)
            return CGPoint(x: strip.position.x + CGFloat(p.x) * strip.size.width,
                           y: strip.position.y + CGFloat(p.y) * strip.size.height)
        }
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(a.x - x) < 1e-3 && abs(a.y - y) < 1e-3 }
        // The oldest and newest samples' edges, ± the radius, across the track (points), and the centreline between.
        #expect(near(point(3), 0, -28) && near(point(2 * columns + 3), 0, 12))
        #expect(near(point(5), 64, -28) && near(point(2 * columns + 5), 64, 12))
        #expect(near(point(columns + 4), 32, -8))
        // Feathered: each end a radius past its sample, closed to a point and clear, no square edge.
        #expect(near(point(0), -20, -8) && near(point(2 * columns), -20, -8))
        #expect(near(point(columns - 1), 84, -8) && near(point(3 * columns - 1), 84, -8))
        #expect(grid.sourcePosition(at: 0).x == 0 && grid.sourcePosition(at: columns - 1).x == 0)
        #expect(grid.sourcePosition(at: 2).x < grid.sourcePosition(at: 3).x)
        // The lone backwind at the backwind's share and z, a disc; the lone cone at full alpha.
        let backwind = layer.sprites[1]
        #expect(backwind.warpGeometry == nil && backwind.texture === TurbulenceTrailLayer.disc)
        #expect(abs(Double(backwind.alpha) - hatch * BoatStyle.standard.backwindShare) < 1e-6)
        // SpriteKit keeps a z in single precision.
        #expect(abs(backwind.zPosition - BoatEffects.Layer.backwind) < 1e-6)
        #expect(abs(strip.zPosition - BoatEffects.Layer.cones) < 1e-6)
        #expect(abs(Double(layer.sprites[2].alpha) - hatch) < 1e-6)
        // u is life left only, a weaker sample's column too (its strength shows in its width); one far weaker than
        // the strongest breaks the ribbon into two discs.
        var weak = five
        weak[1].peak /= 2
        layer.update(samples: weak, time: 1, shadow: shadow, style: .standard)
        let weakGrid = try #require(layer.sprites[0].warpGeometry as? SKWarpGeometryGrid)
        #expect(abs(Double(weakGrid.sourcePosition(at: 4).x) - 0.9) < 1e-6)
        weak[1].peak = shadow.lossCloseIn * 0.1
        layer.update(samples: weak, time: 1, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 4 && layer.sprites[0].warpGeometry == nil && layer.sprites[1].warpGeometry == nil)
        // Fewer samples: the pool stays, the rest hide.
        layer.update(samples: Array(five.prefix(2)), time: 1, shadow: shadow, style: .standard)
        #expect(layer.sprites.count == 4 && layer.visibleCount == 1)
        // Past their life, none.
        layer.update(samples: five, time: 11, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 0)
    }

    /// The sail-angle scale: k = 0 sheds nothing; k = 0.5 halves every sample's peak, radius and growth (cone and
    /// backwind), its life and drift unchanged.
    @Test func scaleShrinksAndWeakensWhatABoatSheds() {
        let shadow = Race.defaultBoatClass.windShadow
        let fleet = TrailParity.fleet(boatClass: Race.defaultBoatClass)
        var full = TurbulenceTrails(shadow: shadow), half = TurbulenceTrails(shadow: shadow)
        var none = TurbulenceTrails(shadow: shadow)
        full.step(boats: fleet, tick: 0)
        half.step(boats: fleet, tick: 0, scales: [0.5, 0.5])
        none.step(boats: fleet, tick: 0, scales: [0, 1])
        #expect(full.samples.count >= 3 && full.samples.contains(where: \.isBackwind))
        #expect(half.samples.count == full.samples.count)
        for (h, f) in zip(half.samples, full.samples) {
            #expect(abs(h.peak - f.peak / 2) < 1e-12 && abs(h.radius - f.radius / 2) < 1e-12)
            #expect(abs(h.growth - f.growth / 2) < 1e-12 && h.life == f.life && h.drift == f.drift)
        }
        #expect(!none.samples.contains { $0.caster == 0 })
        #expect(none.samples.filter { $0.caster == 1 }.count == full.samples.filter { $0.caster == 1 }.count)
    }

    /// The game's trails shed only the shadow: its backwind stays the original zone stripes (owner, #376 A).
    @Test func gameTrailsShedNoBackwind() {
        let shadow = Race.defaultBoatClass.windShadow
        let fleet = TrailParity.fleet(boatClass: Race.defaultBoatClass)
        var prototype = TurbulenceTrails(shadow: shadow), game = TurbulenceTrails(shadow: shadow, shedsBackwind: false)
        prototype.step(boats: fleet, tick: 0)
        game.step(boats: fleet, tick: 0)
        #expect(prototype.samples.contains { $0.isBackwind })
        #expect(!game.samples.contains { $0.isBackwind })
        #expect(game.samples.count == prototype.samples.filter { !$0.isBackwind }.count)
    }

    /// The level builds back: an ease drops a boat's level at once; sheeted in again it rises linearly over
    /// `buildSeconds` (half way at half the time), so the first samples shed after the release are small.
    @Test func trailBuildsBackAfterAnEase() throws {
        let shadow = Race.defaultBoatClass.windShadow
        let boat = TrailParity.fleet(boatClass: Race.defaultBoatClass)[0]
        let build = 2.0
        var trails = TurbulenceTrails(shadow: shadow)
        let full = Race.tickRate, eased = 2 * Race.tickRate
        for tick in 0..<full { trails.step(boats: [boat], tick: tick, scales: [1], buildSeconds: build) }
        #expect(trails.levels == [1])
        trails.step(boats: [boat], tick: full, scales: [0], buildSeconds: build)
        #expect(trails.levels == [0])
        for tick in full + 1..<eased { trails.step(boats: [boat], tick: tick, scales: [0], buildSeconds: build) }
        #expect(!trails.samples.contains { $0.born > full })
        // Released at `eased`: after half of `build` the level is a half.
        let half = Int(build / 2 * Double(Race.tickRate))
        for tick in eased..<eased + half { trails.step(boats: [boat], tick: tick, scales: [1], buildSeconds: build) }
        #expect(abs(trails.levels[0] - 0.5) < 1e-9)
        let first = try #require(trails.samples.filter { $0.born >= eased && !$0.isBackwind }.min { $0.born < $1.born })
        #expect(first.born == eased && first.radius < 0.05 * shadow.coneWidthAtBoat / 2)
        for tick in eased + half..<eased + 2 * half + 1 {
            trails.step(boats: [boat], tick: tick, scales: [1], buildSeconds: build)
        }
        #expect(trails.levels == [1])
        // A tack's head to wind (scale 0) drops it again at once.
        trails.step(boats: [boat], tick: eased + 2 * half + 1, scales: [0], buildSeconds: build)
        #expect(trails.levels == [0])
    }

    /// A boat that eases, then sheets in, draws as two ribbon pieces: one shed before the ease, one building back after
    /// it, nothing bridging the gap, and no column pinched below a tenth of its piece's widest (bar the feathered tips).
    @Test func easeThenSheetInDrawsTwoPieces() throws {
        let boatClass = Race.defaultBoatClass
        let shadow = boatClass.windShadow
        var boat = TrailParity.fleet(boatClass: boatClass)[0]
        var trails = TurbulenceTrails(shadow: shadow)
        var probe = TurbulenceTrails(shadow: shadow)
        probe.step(boats: [boat], tick: 0)
        let life = try #require(probe.samples.first { !$0.isBackwind }).life
        let ticks = { (share: Double) in Int(share * life * Double(Race.tickRate)) }
        let ease = ticks(0.3), sheet = ticks(0.5), end = ticks(0.85)
        for tick in 0...end {
            boat.position += boat.velocity * Race.dt
            TrailParity.refresh(&boat)
            let scale: Double = tick >= ease && tick < sheet ? 0 : 1
            trails.step(boats: [boat], tick: tick, scales: [scale], buildSeconds: 2)
        }
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        layer.update(samples: trails.samples.filter { !$0.isBackwind }, time: Double(end) * Race.dt, every: trails.every,
                     shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 2)
        let feather = TurbulenceTrailLayer.featherSteps.count
        for sprite in layer.sprites.prefix(layer.visibleCount) {
            let grid = try #require(sprite.warpGeometry as? SKWarpGeometryGrid)
            let columns = grid.numberOfColumns + 1
            func point(_ index: Int) -> CGPoint {
                let p = grid.destPosition(at: index)
                return CGPoint(x: CGFloat(p.x) * sprite.size.width, y: CGFloat(p.y) * sprite.size.height)
            }
            let widths = (0..<columns).map { i in
                let a = point(i), b = point(2 * columns + i)
                return Double(hypot(a.x - b.x, a.y - b.y))
            }
            let widest = widths.max() ?? 0
            let inner = widths[feather..<(columns - feather)]
            #expect(inner.allSatisfy { $0 >= 0.1 * widest }, "\(widths)")
        }
    }

    /// The sail's angle to her apparent wind, as drawn: about the default full angle sailing the upwind groove (so
    /// she sheds her full turbulence there), none with the sheets out on a beat or head to wind, full on a run.
    @Test func sailAngleScalesTheTurbulence() {
        let boatClass = Race.defaultBoatClass
        let style = BoatStyle.standard
        let groove = TrailParity.fleet(boatClass: boatClass)[0]
        let aoa = rad2deg(BoatPose.angleOfAttack(groove, ease: false, boatClass: boatClass, style: style))
        print("upwind groove angle of attack: \(aoa)°")
        #expect(abs(aoa - style.trailFullAngleDegrees) < 1)
        #expect(BoatPose.angleOfAttack(groove, ease: true, boatClass: boatClass, style: style) == 0)
        #expect(abs(TurbulenceTrails.scale(of: groove, ease: false, boatClass: boatClass, style: style) - 1) < 0.02)
        var head = groove
        head.heading = 0
        TrailParity.refresh(&head)
        #expect(TurbulenceTrails.scale(of: head, ease: false, boatClass: boatClass, style: style) == 0)
        var run = groove
        run.heading = .pi * 0.9
        TrailParity.refresh(&run)
        #expect(TurbulenceTrails.scale(of: run, ease: false, boatClass: boatClass, style: style) == 1)
        var half = style
        half.trailFullAngleDegrees = 2 * aoa
        #expect(abs(TurbulenceTrails.scale(of: groove, ease: false, boatClass: boatClass, style: half) - 0.5) < 1e-9)
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
    @Test func savedTuningsLoadAsCones() throws {
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data("{}".utf8))
        #expect(tuning.shadowDrawing == .cones)
        var trails = Tuning()
        trails.shadowDrawing = .trails
        #expect(try JSONDecoder().decode(Tuning.self, from: trails.jsonData()).shadowDrawing == .trails)
    }
    #endif
}

@MainActor enum TrailParity {
    /// Two boats close-hauled in a steady 10 kn from 0 in still water: seat 0 tacks at t=2 (the prototype's tack), seat 1
    /// sails on 3 hull lengths down seat 0's shadow at the start. 8 s, then the factor at a few probes.
    static let wind = Wind(direction: 0, speed: metresPerSecond(knots: 10))

    static func refresh(_ b: inout Boat) {
        b.apparentWind = BoatWinds.resolve(ground: wind, current: .zero, velocityThroughWater: b.velocity).apparent
        b.boomSide = b.relativeWind > 0 ? .port : .starboard
    }

    /// The scene's two boats at the start: seat 0 on her upwind groove, seat 1 3 hull lengths down her shadow.
    static func fleet(boatClass: BoatClass) -> [Boat] {
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        func boat(_ id: Int, _ position: Vec2) -> Boat {
            var b = Boat(id: id, isPlayer: false, colorIndex: id, position: position, heading: -best.twa, speed: best.speed)
            b.windOverGround = wind
            b.sailingWind = wind
            refresh(&b)
            return b
        }
        let caster = boat(0, .zero)
        return [caster, boat(1, ShadowCone(caster: caster, shadow: boatClass.windShadow).axis * (3 * boatClass.hull.length))]
    }

    static func factors(boatClass: BoatClass) -> [Double] {
        let shadow = boatClass.windShadow
        let hull = boatClass.hull.length
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        let twa = best.twa, fast = best.speed
        let fleet = fleet(boatClass: boatClass)
        var caster = fleet[0]
        var other = fleet[1]
        var trails = TurbulenceTrails(shadow: shadow)
        let ticks = 8 * Race.tickRate
        for tick in 0..<ticks {
            let t = Double(tick) * Race.dt
            let x = ((t - 2) / 3).clamped(to: 0...1)
            let k = x * x * (3 - 2 * x)
            caster.heading = -twa + k * 2 * twa
            caster.speed = fast * (1 - 0.45 * Foundation.sin(Double.pi * ((t - 2) / 7).clamped(to: 0...1)))
            caster.position += caster.velocity * Race.dt
            refresh(&caster)
            other.position += other.velocity * Race.dt
            refresh(&other)
            trails.step(boats: [caster, other], tick: tick)
        }
        let tick = ticks - 1
        let cone = ShadowCone(caster: caster, shadow: shadow)
        let start = Vec2.heading(-twa) * (fast * 2)
        return [
            trails.factor(at: other.position, tick: tick, receiver: 1, casters: 2),
            trails.factor(at: caster.position + cone.axis * (2 * hull), tick: tick, receiver: 1, casters: 2),
            trails.factor(at: TurbulenceTrails.backwindCentre(of: cone) ?? cone.apex, tick: tick, receiver: 1, casters: 2),
            trails.factor(at: start + Vec2(0, -3 * hull), tick: tick, receiver: 1, casters: 2),
            trails.factor(at: caster.position, tick: tick, receiver: 0, casters: 2),
            Double(trails.samples.count),
        ]
    }
}
