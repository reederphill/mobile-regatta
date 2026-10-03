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

    /// A ribbon a caster and kind: samples − ribbons segments, plus a cap on each ribbon's newest end (a lone sample
    /// is just its disc), so as many sprites as samples; the rest hidden.
    @Test func layerDrawsASpriteASample() throws {
        let shadow = Race.defaultBoatClass.windShadow
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        func sample(_ x: Double, caster: Int = 0, backwind: Bool = false) -> TurbulenceTrails.Sample {
            TurbulenceTrails.Sample(position: Vec2(x, 0), drift: Vec2(0, -1), born: 0, caster: caster,
                                    peak: backwind ? shadow.backwindLoss : shadow.lossCloseIn, radius: 2, growth: 0.5,
                                    life: 10, isBackwind: backwind)
        }
        // Caster 0: a cone ribbon of three (one warped strip and a cap) and a lone backwind; caster 1: a lone cone.
        let five = [sample(0), sample(4), sample(8), sample(0, backwind: true), sample(20, caster: 1)]
        layer.update(samples: five, time: 1, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 4)
        // Drifted, grown and faded: at 1 s of 10, 2.5 m a side, 1 m down, at 90% of the hatch.
        let hatch = BoatStyle.standard.coneAlpha * 0.9
        let strip = layer.sprites[0], cap = layer.sprites[1]
        #expect(strip.texture === TurbulenceTrailLayer.strip && cap.texture === TurbulenceTrailLayer.disc)
        // The strip's own alpha is the hatch; its texture carries the fade (u = life left).
        #expect(abs(Double(strip.alpha) - BoatStyle.standard.coneAlpha) < 1e-6)
        let grid = try #require(strip.warpGeometry as? SKWarpGeometryGrid)
        #expect(grid.numberOfColumns == 2 && grid.numberOfRows == 2)
        #expect(abs(Double(grid.sourcePosition(at: 0).x) - 0.9) < 1e-6)
        // The first and last columns' edges at the oldest and newest centres, ± the radius, across the track (points).
        func point(_ index: Int) -> CGPoint {
            let p = grid.destPosition(at: index)
            return CGPoint(x: strip.position.x + CGFloat(p.x) * strip.size.width,
                           y: strip.position.y + CGFloat(p.y) * strip.size.height)
        }
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(a.x - x) < 1e-3 && abs(a.y - y) < 1e-3 }
        #expect(near(point(0), 0, -28) && near(point(6), 0, 12))
        #expect(near(point(2), 64, -28) && near(point(8), 64, 12))
        #expect(near(point(4), 32, -8))
        #expect(abs(cap.position.x - 64) < 1e-6 && abs(cap.size.width - 40) < 1e-6)
        #expect(abs(Double(cap.alpha) - hatch / 2) < 1e-6)
        // The lone backwind at the backwind's share and z; the lone cone at full alpha.
        let backwind = layer.sprites[2]
        #expect(backwind.warpGeometry == nil)
        #expect(abs(Double(backwind.alpha) - hatch * BoatStyle.standard.backwindShare) < 1e-6)
        // SpriteKit keeps a z in single precision.
        #expect(abs(backwind.zPosition - BoatEffects.Layer.backwind) < 1e-6)
        #expect(abs(strip.zPosition - BoatEffects.Layer.cones) < 1e-6)
        #expect(abs(Double(layer.sprites[3].alpha) - hatch) < 1e-6)
        // Fewer samples: the pool stays, the rest hide.
        layer.update(samples: Array(five.prefix(2)), time: 1, shadow: shadow, style: .standard)
        #expect(layer.sprites.count == 4 && layer.visibleCount == 2)
        // Past their life, none.
        layer.update(samples: five, time: 11, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 0)
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
    static func factors(boatClass: BoatClass) -> [Double] {
        let shadow = boatClass.windShadow
        let hull = boatClass.hull.length
        let wind = Wind(direction: 0, speed: metresPerSecond(knots: 10))
        let best = boatClass.polar.bestUpwind(tws: wind.speed)
        let twa = best.twa, fast = best.speed
        func refresh(_ b: inout Boat) {
            b.apparentWind = BoatWinds.resolve(ground: wind, current: .zero, velocityThroughWater: b.velocity).apparent
            b.boomSide = b.relativeWind > 0 ? .port : .starboard
        }
        func boat(_ id: Int, _ position: Vec2) -> Boat {
            var b = Boat(id: id, isPlayer: false, colorIndex: id, position: position, heading: -twa, speed: fast)
            b.windOverGround = wind
            b.sailingWind = wind
            refresh(&b)
            return b
        }
        var caster = boat(0, .zero)
        var other = boat(1, ShadowCone(caster: caster, shadow: shadow).axis * (3 * hull))
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
