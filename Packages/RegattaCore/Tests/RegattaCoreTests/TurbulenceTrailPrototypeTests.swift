import Foundation
import Testing
@testable import RegattaCore

/// #376 prototype (investigation only, nothing here ships; the model lives in this test file on purpose).
///
/// A trail model for the wind shadow and the backwind: every boat sheds samples of disturbed air along her track at
/// 10 Hz, each carried off by the true wind, growing and fading with age. A boat's loss from one caster is the
/// strongest of that caster's samples at her position; casters stack as the cones do (product, floored). Samples
/// are never stored per tick in the sim: they're a pure function of the casters' recent states.
///
/// The scenarios drive one scripted caster (a tack, a gybe, an ease, a run) past fixed and co-moving probe points and
/// print what the cone-and-trapezoid boxes say against what the trail says there. Read the output with
/// `swift test --filter TurbulenceTrailPrototypeTests` (it prints).
struct TurbulenceTrails {
    struct Sample {
        var position: Vec2
        /// The true wind's velocity at the caster: how the sample drifts (ground frame).
        var drift: Vec2
        var born: Int
        var caster: Int
        var peak: Double
        var radius: Double
        var growth: Double
        var life: Double
    }

    private(set) var samples: [Sample] = []
    let shadow: BoatClass.WindShadow
    let every: Int

    init(shadow: BoatClass.WindShadow, every: Int = 3) {
        self.shadow = shadow
        self.every = every
    }

    mutating func step(boats: [Boat], tick: Int) {
        samples.removeAll { Double(tick - $0.born) * Race.dt >= $0.life }
        guard tick % every == 0 else { return }
        for (seat, b) in boats.enumerated() where !b.isGhost {
            let apparent = max(b.apparentWind.speed, 0.5)
            let drift = b.windOverGround.velocity
            // Her cone: shed at her centre, reaching `coneLength` in the time her own apparent wind takes to carry
            // air that far astern of her (the trail's length in her frame is her apparent wind × the sample's life).
            let life = shadow.coneLength / apparent
            let r0 = shadow.coneWidthAtBoat / 2, r1 = shadow.coneWidthAtEnd / 2
            samples.append(Sample(position: b.position, drift: drift, born: tick, caster: seat, peak: shadow.lossCloseIn,
                                  radius: r0, growth: (r1 - r0) / life, life: life))
            // Her backwind: shed at the middle of the trapezoid, a short-lived patch.
            let cone = ShadowCone(caster: b, shadow: shadow)
            guard shadow.backwindInnerLength != nil, cone.backwindPresence > 0,
                  let at = Self.backwindCentre(of: cone) else { continue }
            let scale = shadow.backwindScale(speed: b.speedThroughWater)
            guard scale > 0 else { continue }
            samples.append(Sample(position: at, drift: drift, born: tick, caster: seat,
                                  peak: 1 - cone.backwindFactor(at: at), radius: shadow.backwindWidth / 2,
                                  growth: 0, life: shadow.backwindLength * scale / apparent))
        }
    }

    /// The middle of the trapezoid (#298) the box casts now.
    static func backwindCentre(of cone: ShadowCone) -> Vec2? {
        let s = cone.shadow
        let out = s.backwindWidth / 2
        guard let span = s.backwindSpan(out: out) else { return nil }
        let scale = s.backwindScale(speed: cone.speed)
        let astern = (span.start + span.end) / 2 * scale
        return cone.apex + cone.windward * (s.sternCorner.x + out) + cone.forward * (s.sternCorner.y - astern)
    }

    /// The loss (0...1) each caster's trail leaves at `p` at `tick`, by caster seat.
    func losses(at p: Vec2, tick: Int, casters: Int) -> [Double] {
        var best = [Double](repeating: 0, count: casters)
        for s in samples {
            let age = Double(tick - s.born) * Race.dt
            guard age < s.life else { continue }
            let d = (p - (s.position + s.drift * age)).length
            let r = s.radius + s.growth * age
            guard d < r else { continue }
            let loss = s.peak * (1 - age / s.life) * (1 - d / r)
            if loss > best[s.caster] { best[s.caster] = loss }
        }
        return best
    }

    func factor(at p: Vec2, tick: Int, receiver: Int, casters: Int) -> Double {
        var f = 1.0
        for (c, loss) in losses(at: p, tick: tick, casters: casters).enumerated() where c != receiver { f *= 1 - loss }
        return max(f, shadow.stackingFloor)
    }
}

/// A scripted caster in a steady 10 kn wind from 0 in still water.
struct TrailScene {
    static let windDirection = 0.0
    static let tws = metresPerSecond(knots: 10)
    static let wind = Wind(direction: windDirection, speed: tws)
    static var shadow: BoatClass.WindShadow { OpenWater.boatClass.windShadow }
    static var hull: Double { OpenWater.hullLength }
    static var upwind: (twa: Double, speed: Double) { let b = OpenWater.boatClass.polar.bestUpwind(tws: tws); return (b.twa, b.speed) }

    static func boat(id: Int = 0, position: Vec2, heading: Double, speed: Double) -> Boat {
        var b = Boat(id: id, isPlayer: false, colorIndex: id, position: position, heading: heading, speed: speed)
        b.windOverGround = wind
        b.sailingWind = wind
        refresh(&b)
        return b
    }

    static func refresh(_ b: inout Boat) {
        b.apparentWind = BoatWinds.resolve(ground: wind, current: .zero, velocityThroughWater: b.velocity).apparent
        b.boomSide = b.relativeWind > 0 ? .port : .starboard
    }

    static func smooth(_ x: Double) -> Double { let t = x.clamped(to: 0...1); return t * t * (3 - 2 * t) }

    /// One manoeuvre: the caster's heading and speed at time t.
    struct Manoeuvre {
        let name: String
        let steer: (Double) -> TrailScene.Steer
    }

    typealias Steer = (heading: Double, speed: Double)

    static var manoeuvres: [Manoeuvre] {
        let up = upwind
        let twa: Double = up.twa, fast: Double = up.speed
        let h0: Double = windDirection - twa
        var list: [Manoeuvre] = []
        list.append(Manoeuvre(name: "steady close-hauled") { (_: Double) -> Steer in (h0, fast) })
        // Tack: heading through the wind over 3 s from t=2, speed to 55% at the crossing and back by t=9.
        list.append(Manoeuvre(name: "tack at t=2") { (t: Double) -> Steer in
            let k: Double = smooth((t - 2) / 3)
            let dip: Double = 1 - 0.45 * Foundation.sin(Double.pi * ((t - 2) / 7).clamped(to: 0...1))
            return (h0 + k * 2 * twa, fast * dip)
        })
        // Ease: bear away from close-hauled to a beam reach over 4 s from t=2 and speed up.
        list.append(Manoeuvre(name: "ease (bear away 45 to 90) at t=2") { (t: Double) -> Steer in
            let k: Double = smooth((t - 2) / 4)
            return (h0 - k * deg2rad(45), fast * (1 + 0.5 * k))
        })
        // Gybe from 150 degrees true wind angle on one gybe to the other over 3 s from t=2.
        list.append(Manoeuvre(name: "gybe at t=2 (twa 150)") { (t: Double) -> Steer in
            let k: Double = smooth((t - 2) / 3)
            let h: Double = windDirection + deg2rad(150) - k * deg2rad(300)
            return (h, 4.5 * (1 - 0.2 * Foundation.sin(Double.pi * k)))
        })
        list.append(Manoeuvre(name: "running (twa 170)") { (_: Double) -> Steer in (windDirection + deg2rad(170), 4.5) })
        return list
    }

    /// A probe: a point offset from the caster's start in her frame at t=0, either fixed in the water or sailing on
    /// at her initial velocity (a boat that doesn't manoeuvre).
    struct Probe {
        let name: String
        let offset: (ShadowCone, Boat) -> Vec2
        let sailsOn: Bool
    }

    static var probes: [Probe] {
        [
            Probe(name: "shadow 3L down, sails on", offset: { c, _ in c.axis * (3 * hull) }, sailsOn: true),
            Probe(name: "3L down her apparent wind, sails on", offset: { c, _ in
                -Vec2.heading(c.apparentWindDirection) * (3 * hull) }, sailsOn: true),
            Probe(name: "shadow 6L down, sails on", offset: { c, _ in c.axis * (6 * hull) }, sailsOn: true),
            Probe(name: "shadow 6L down, stopped", offset: { c, _ in c.axis * (6 * hull) }, sailsOn: false),
            Probe(name: "lee-bow (backwind middle), sails on", offset: { c, _ in
                (TurbulenceTrails.backwindCentre(of: c) ?? c.apex) - c.apex }, sailsOn: true),
        ]
    }

    struct Result: Equatable {
        var box: [Double], trail: [Double]
        var boxLoss: Double { box.map { 1 - $0 }.max() ?? 0 }
        var trailLoss: Double { trail.map { 1 - $0 }.max() ?? 0 }
        /// Loss-seconds.
        var boxSeconds: Double { box.reduce(0) { $0 + (1 - $1) } * Race.dt }
        var trailSeconds: Double { trail.reduce(0) { $0 + (1 - $1) } * Race.dt }
        func seconds(above level: Double, _ series: [Double]) -> Double { Double(series.filter { 1 - $0 > level }.count) * Race.dt }
    }

    static func run(_ m: Manoeuvre, seconds: Double = 25, every: Int = 3) -> [Result] {
        var caster = boat(position: .zero, heading: m.steer(0).heading, speed: m.steer(0).speed)
        let start = ShadowCone(caster: caster, shadow: shadow)
        let v0 = caster.velocity
        let ps = probes
        let offsets = ps.map { $0.offset(start, caster) }
        var results = ps.map { _ in Result(box: [], trail: []) }
        var trails = TurbulenceTrails(shadow: shadow, every: every)
        for tick in 0..<Int(seconds * Double(Race.tickRate)) {
            let t = Double(tick) * Race.dt
            let (h, s) = m.steer(t)
            caster.heading = h
            caster.speed = s
            caster.position += caster.velocity * Race.dt
            refresh(&caster)
            trails.step(boats: [caster], tick: tick)
            let cone = ShadowCone(caster: caster, shadow: shadow)
            for (i, p) in ps.enumerated() {
                let at = offsets[i] + (p.sailsOn ? v0 * t : .zero)
                // The probe is seat 1; the caster is seat 0.
                results[i].box.append(max(cone.factor(at: at), shadow.stackingFloor))
                results[i].trail.append(trails.factor(at: at, tick: tick, receiver: 1, casters: 2))
            }
        }
        return results
    }
}

@Suite struct TurbulenceTrailPrototypeTests {
    typealias S = TrailScene

    @Test func scenariosBoxesAgainstTrails() {
        let c = S.shadow
        print("""
        TRAIL PROTOTYPE class: cone \(c.coneLength / S.hull) L long, \(c.coneWidthAtBoat / S.hull) -> \(c.coneWidthAtEnd / S.hull) L wide, \
        loss \(c.lossCloseIn), floor \(c.stackingFloor), swing \(c.coneSwing), fromHull \(c.coneFromHull); backwind \
        \(c.backwindLength / S.hull) L long, \(c.backwindWidth / S.hull) L wide, loss \(c.backwindLoss); hull \(S.hull) m; 10 kn
        """)
        for m in S.manoeuvres {
            let results = S.run(m)
            print("== \(m.name)")
            for (p, r) in zip(S.probes, results) {
                let line = String(format: "  %-38@ box: peak %.2f, %.1f loss-s, >0.02 for %4.1f s | trail: peak %.2f, %.1f loss-s, >0.02 for %4.1f s",
                                  p.name as NSString, r.boxLoss, r.boxSeconds, r.seconds(above: 0.02, r.box),
                                  r.trailLoss, r.trailSeconds, r.seconds(above: 0.02, r.trail))
                print(line)
                // The factor each second, box then trail, in loss percent.
                let every = Race.tickRate
                let b = stride(from: 0, to: r.box.count, by: every).map { String(format: "%2.0f", (1 - r.box[$0]) * 100) }.joined(separator: " ")
                let t = stride(from: 0, to: r.trail.count, by: every).map { String(format: "%2.0f", (1 - r.trail[$0]) * 100) }.joined(separator: " ")
                print("      box   %/s: \(b)\n      trail %/s: \(t)")
            }
            for r in results { #expect(r.trail.allSatisfy { $0 >= S.shadow.stackingFloor && $0 <= 1 }) }
        }
    }

    /// The trail reproduces the cone when nothing manoeuvres: the loss sits in the same place down her axis.
    @Test func steadyTrailMatchesTheBoxRoughly() {
        let steady = S.run(S.manoeuvres[0])
        // Skip the first 12 s while the trail fills (it is `coneLength / apparent` long).
        let skip = 12 * Race.tickRate
        for (p, r) in zip(S.probes, steady) {
            let box = r.box.dropFirst(skip).map { 1 - $0 }.reduce(0, +) / Double(r.box.count - skip)
            let trail = r.trail.dropFirst(skip).map { 1 - $0 }.reduce(0, +) / Double(r.trail.count - skip)
            print(String(format: "STEADY %-38@ mean loss box %.3f trail %.3f", p.name as NSString, box, trail))
        }
    }

    @Test func trailsAreDeterministic() {
        #expect(S.run(S.manoeuvres[1]) == S.run(S.manoeuvres[1]))
    }

    /// 16 boats in the sim's shape: cones (`applyWindShadows`) against trails, timed per tick on the host in a debug
    /// build (the ratio is the finding; device numbers are #172's).
    @Test func costAt16Boats() {
        let up = S.upwind
        var boats: [Boat] = (0..<16).map { i in
            let row = Double(i / 8), col = Double(i % 8)
            let h = S.windDirection + (i % 2 == 0 ? -up.twa : up.twa)
            return S.boat(id: i, position: Vec2(col * 3 * S.hull, row * 4 * S.hull), heading: h, speed: up.speed)
        }
        let ticks = 20 * Race.tickRate
        var trails = TurbulenceTrails(shadow: S.shadow)
        let clock = ContinuousClock()
        var boxTime = Duration.zero, trailTime = Duration.zero, maxSamples = 0
        var sink = 0.0
        for tick in 0..<ticks {
            for i in boats.indices {
                boats[i].position += boats[i].velocity * Race.dt
                S.refresh(&boats[i])
            }
            var start = clock.now
            let cones = boats.map { ShadowCone(caster: $0, shadow: S.shadow) }
            for i in boats.indices {
                let others = cones.indices.compactMap { $0 == i ? nil : cones[$0] }
                sink += ShadowCone.factor(at: boats[i].position, of: others, floor: S.shadow.stackingFloor)
            }
            boxTime += start.duration(to: clock.now)
            start = clock.now
            trails.step(boats: boats, tick: tick)
            for i in boats.indices { sink += trails.factor(at: boats[i].position, tick: tick, receiver: i, casters: boats.count) }
            trailTime += start.duration(to: clock.now)
            maxSamples = max(maxSamples, trails.samples.count)
        }
        let ms = { (d: Duration) in (Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15) / Double(ticks) }
        print(String(format: "COST 16 boats (debug host): boxes %.4f ms/tick, trails %.4f ms/tick (x%.1f); up to %d samples, %d B each = %d B live (sink %.1f)",
                     ms(boxTime), ms(trailTime), ms(trailTime) / max(ms(boxTime), 1e-9), maxSamples,
                     MemoryLayout<TurbulenceTrails.Sample>.stride, maxSamples * MemoryLayout<TurbulenceTrails.Sample>.stride, sink))
        #expect(maxSamples > 0)
    }
}
