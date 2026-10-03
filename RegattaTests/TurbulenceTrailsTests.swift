import Foundation
import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The app's turbulence trails (#376 follow-on A) are the prototype's (`TurbulenceTrailPrototypeTests` in RegattaCore's
/// tests, the reference): the same scene gives the same factors, printed from the prototype's model once. And the layer
/// draws a sprite a live sample.
@MainActor @Suite struct TurbulenceTrailsTests {
    /// Printed from the prototype's `TurbulenceTrails` on `TrailParity`'s scene (the default class).
    static let prototype: [Double] = [1, 0.82444011624698443, 0.92180166715991441, 0.85173926921858512, 1, 141]

    @Test func factorsMatchThePrototype() {
        let factors = TrailParity.factors(boatClass: Race.defaultBoatClass)
        #expect(factors.count == Self.prototype.count)
        for (got, want) in zip(factors, Self.prototype) { #expect(abs(got - want) < 1e-9, "\(got) vs \(want)") }
    }

    @Test func layerDrawsASpriteASample() {
        let shadow = Race.defaultBoatClass.windShadow
        let layer = TurbulenceTrailLayer(pointsPerMeter: 8)
        func samples(_ n: Int) -> [TurbulenceTrails.Sample] {
            (0..<n).map { i in
                TurbulenceTrails.Sample(position: Vec2(Double(i), 0), drift: Vec2(0, -1), born: 0, caster: 0,
                                        peak: shadow.lossCloseIn, radius: 2, growth: 0.5, life: 10, isBackwind: i == 0)
            }
        }
        layer.update(samples: samples(7), time: 1, shadow: shadow, style: .standard)
        #expect(layer.visibleCount == 7)
        layer.update(samples: samples(3), time: 1, shadow: shadow, style: .standard)
        #expect(layer.sprites.count == 7 && layer.visibleCount == 3)
        // Drifted, grown and faded: at 1 s of 10, 2.5 m wide a side, 1 m down, at 90% of the hatch.
        let sprite = layer.sprites[1]
        #expect(abs(sprite.position.y - -8) < 1e-6 && abs(sprite.size.width - 40) < 1e-6)
        #expect(abs(Double(sprite.alpha) - BoatStyle.standard.coneAlpha * 0.9) < 1e-6)
        // SpriteKit keeps a z in single precision.
        #expect(abs(layer.sprites[0].zPosition - BoatEffects.Layer.backwind) < 1e-6)
        #expect(abs(sprite.zPosition - BoatEffects.Layer.cones) < 1e-6)
        // Past their life, none.
        layer.update(samples: samples(3), time: 11, shadow: shadow, style: .standard)
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
