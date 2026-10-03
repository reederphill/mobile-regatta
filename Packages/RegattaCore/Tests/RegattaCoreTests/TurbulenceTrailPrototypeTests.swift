import Foundation
import Testing
@testable import RegattaCore

/// #376 prototype (investigation only, nothing here ships; the model lives in this test file on purpose).
///
/// The ribbon model of the wind shadow (owner, 2026-10-03). Every boat leaves points in space at a fixed interval,
/// each with a strength and a scale (its radius of influence). A point drifts with the true wind; with age its scale
/// grows (as √age, so the growth slows) and its strength fades smoothly to exactly 0 at the end of its life. A
/// caster's consecutive points are joined into a ribbon whose strength and scale interpolate along each segment; the
/// ribbon breaks where an end has no strength or no scale, where an emission was skipped (stopped, ghost) or where
/// neighbours have drifted apart past a length cap. A boat's loss from one caster is the strongest ribbon reaching her;
/// casters stack as the cones do (product, floored). The backwind is a bound field around the boat (research, §2):
/// it is not trailed here.
///
/// The scenarios drive one scripted caster (a tack, a gybe, an ease, a run) past fixed and co-moving probe points and
/// print what the cone-and-trapezoid boxes say against what the ribbon says there. Read the output with
/// `swift test --filter TurbulenceTrailPrototypeTests` (it prints).
struct TurbulenceRibbons {
    /// Every value here is tuning, not measured: the research (docs/research/yacht-wake-and-backwind-aerodynamics.md)
    /// gives the wake's direction (along the apparent wind, a few degrees astern of it) and nothing on its reach,
    /// growth or decay beyond "felt for up to ten boat lengths" (Marchaj, second-hand).
    struct Parameters {
        /// Seconds between a boat's points (tuning, not measured). Default 0.5 s: 15 ticks, so a 10 L trail at a
        /// close-hauled apparent wind is ~14 points, few enough for bots to read as a point map.
        var emitSeconds = 0.5
        /// A point's life in seconds at emission, given the caster's apparent wind speed (tuning, not measured).
        /// Default nil: `coneLength / apparent`, the time her own apparent wind takes to carry air one cone length
        /// astern of her, so a steady boat's ribbon is as long as her box.
        var life: ((_ apparent: Double) -> Double)? = nil
        /// Half the width at the boat and at the end of life, metres (tuning, not measured). Default nil: half the
        /// class's `coneWidthAtBoat` and `coneWidthAtEnd`, so the steady ribbon is as wide as her box at both ends.
        var startScale: Double? = nil
        var endScale: Double? = nil
        /// Strength at emission (tuning, not measured). Default nil: the class's `lossCloseIn`, the box's loss
        /// close in.
        var peak: Double? = nil
        /// Below this speed through the water a boat sheds nothing, which breaks her ribbon (tuning, not measured).
        /// Default 0.3 m/s: a boat that's stopped or head to wind isn't driving air off her sails.
        var stoppedSpeed = 0.3
        /// Neighbouring points further apart than this, metres, aren't joined (tuning, not measured). Default
        /// 2 × the travel of a 10 kn apparent wind in one emission interval: 2 × 5.14 m/s × 0.5 s = 5.14 m, about
        /// 1 L. A steady boat's neighbours sit her apparent wind × `emitSeconds` apart (3.5 m close-hauled at 10 kn)
        /// and keep that spacing in a uniform wind, so the cap only bites where the pressure field (ADR 0008) drifts
        /// them apart, or where her apparent wind is over 20 kn.
        var lengthCap = 2 * metresPerSecond(knots: 10) * 0.5
        /// Extra turning of the trail astern of the apparent-wind line, degrees (tuning; the research measures
        /// ~5° upwind, ~9° on a spinnaker reach). Default 0, inert. Applied to the drift: a point's velocity relative
        /// to her (true wind minus her velocity over ground, which streams astern along her apparent wind) is turned
        /// by this much towards her stern line (never past it), so a steady ribbon lies this far off the apparent
        /// wind towards her centreline. Its drift over the ground is then no longer exactly the true wind.
        var extraTurnDegrees = 0.0
        /// The sail-angle build-up: an emission multiplier falls to a boat's scale at once and rises linearly, 0 to 1
        /// over this many seconds (as the app's `TurbulenceTrails.levels`). Default 0: at once.
        var buildSeconds = 0.0
    }

    struct Point {
        /// Where she was at emission, and how it drifts (ground frame).
        var position: Vec2
        var drift: Vec2
        var born: Int
        /// Strength and scale at emission (already × the emission multiplier), the scale's √age growth rate, life.
        var peak: Double
        var scale: Double
        var growth: Double
        var life: Double
    }

    /// A point now: what a bot would read from the point map.
    struct Live: Equatable {
        var position: Vec2
        var strength: Double
        var scale: Double
    }

    let shadow: BoatClass.WindShadow
    let parameters: Parameters
    /// Ticks between emissions.
    let every: Int
    /// Each caster's live points, oldest first.
    private(set) var points: [[Point]] = []
    /// Each seat's emission multiplier now, 0...1 (the app's `levels`). Empty until the first step.
    private(set) var levels: [Double] = []

    init(shadow: BoatClass.WindShadow, parameters: Parameters = Parameters()) {
        self.shadow = shadow
        self.parameters = parameters
        self.every = max(1, Int((parameters.emitSeconds / Race.dt).rounded()))
    }

    var pointCount: Int { points.reduce(0) { $0 + $1.count } }

    /// Call every tick. `scales`, by seat (nil = 1 for all), is each boat's emission multiplier target (the sail-angle
    /// scale), smoothed into `levels` as the app does: a level falls to its target at once and rises towards it
    /// linearly over `buildSeconds`. A seat's first level is its target.
    mutating func step(boats: [Boat], tick: Int, scales: [Double]? = nil) {
        while points.count < boats.count { points.append([]) }
        for c in points.indices { points[c].removeAll { Double(tick - $0.born) * Race.dt >= $0.life } }
        let rise = parameters.buildSeconds > 0 ? Race.dt / parameters.buildSeconds : 1
        for seat in boats.indices {
            let target = (scales.map { seat < $0.count ? $0[seat] : 1 } ?? 1).clamped(to: 0...1)
            if seat >= levels.count {
                levels.append(target)
            } else {
                levels[seat] = target < levels[seat] ? target : min(target, levels[seat] + rise)
            }
        }
        guard tick % every == 0 else { return }
        for (seat, b) in boats.enumerated() where !b.isGhost && b.speedThroughWater >= parameters.stoppedSpeed {
            let m = levels[seat]
            let apparent = max(b.apparentWind.speed, 0.5)
            let life = parameters.life?(apparent) ?? shadow.coneLength / apparent
            let s0 = parameters.startScale ?? shadow.coneWidthAtBoat / 2
            let s1 = parameters.endScale ?? shadow.coneWidthAtEnd / 2
            points[seat].append(Point(position: b.position, drift: drift(of: b), born: tick,
                                      peak: (parameters.peak ?? shadow.lossCloseIn) * m, scale: s0 * m,
                                      growth: (s1 - s0) / life.squareRoot() * m, life: life))
        }
    }

    /// The true wind at her, turned `extraTurnDegrees` towards her stern line in her frame.
    func drift(of b: Boat) -> Vec2 {
        let wind = b.windOverGround.velocity
        guard parameters.extraTurnDegrees != 0 else { return wind }
        let v = b.velocityOverGround
        let relative = wind - v, astern = -b.forward
        let towards = atan2(relative.cross(astern), relative.dot(astern))
        let turn = (towards < 0 ? -1.0 : 1.0) * min(abs(towards), deg2rad(parameters.extraTurnDegrees))
        let (s, c) = (Foundation.sin(turn), Foundation.cos(turn))
        return v + Vec2(relative.x * c - relative.y * s, relative.x * s + relative.y * c)
    }

    static func smoothstep(_ x: Double) -> Double { let t = x.clamped(to: 0...1); return t * t * (3 - 2 * t) }

    func live(_ p: Point, tick: Int) -> Live {
        let age = max(0, Double(tick - p.born) * Race.dt)
        return Live(position: p.position + p.drift * age, strength: p.peak * (1 - Self.smoothstep(age / p.life)),
                    scale: p.scale + p.growth * age.squareRoot())
    }

    /// The caster's live points now, oldest first: the short list a bot could read.
    func pointMap(of caster: Int, tick: Int) -> [Live] {
        guard caster < points.count else { return [] }
        return points[caster].filter { Double(tick - $0.born) * Race.dt < $0.life }.map { live($0, tick: tick) }
    }

    /// Whether two consecutive points (by emission) are joined into a segment now.
    func joined(_ a: Point, _ la: Live, _ b: Point, _ lb: Live) -> Bool {
        b.born - a.born == every && la.strength > 0 && lb.strength > 0 && la.scale > 0 && lb.scale > 0
            && (lb.position - la.position).length <= parameters.lengthCap
    }

    /// The caster's ribbons now: runs of joined points (a lone point is a run of one).
    func ribbons(of caster: Int, tick: Int) -> [[Live]] {
        guard caster < points.count else { return [] }
        let ps = points[caster].filter { Double(tick - $0.born) * Race.dt < $0.life }
        var runs: [[Live]] = []
        for (i, p) in ps.enumerated() {
            let l = live(p, tick: tick)
            if i > 0, joined(ps[i - 1], live(ps[i - 1], tick: tick), p, l) { runs[runs.count - 1].append(l) } else { runs.append([l]) }
        }
        return runs
    }

    /// The loss (0...1) caster `c`'s ribbons leave at `p`: the strongest ribbon reaching it. The same as the max of
    /// `loss(along:at:)` over `ribbons(of:tick:)`, walked without building them.
    func loss(of c: Int, at p: Vec2, tick: Int) -> Double {
        guard c < points.count else { return 0 }
        var best = 0.0
        var prev: (point: Point, live: Live, joinedBack: Bool)? = nil
        for q in points[c] where Double(tick - q.born) * Race.dt < q.life {
            let l = live(q, tick: tick)
            var joinedBack = false
            if let pr = prev {
                if joined(pr.point, pr.live, q, l) {
                    best = max(best, Self.segmentLoss(pr.live, l, at: p))
                    joinedBack = true
                } else if !pr.joinedBack {
                    best = max(best, Self.discLoss(pr.live, at: p))
                }
            }
            prev = (q, l, joinedBack)
        }
        if let pr = prev, !pr.joinedBack { best = max(best, Self.discLoss(pr.live, at: p)) }
        return best
    }

    /// The loss one ribbon leaves at `p`: the strongest of its segments. A lone point is a disc.
    static func loss(along run: [Live], at p: Vec2) -> Double {
        guard run.count > 1 else { return run.first.map { discLoss($0, at: p) } ?? 0 }
        return (1..<run.count).reduce(0) { max($0, segmentLoss(run[$1 - 1], run[$1], at: p)) }
    }

    static func discLoss(_ a: Live, at p: Vec2) -> Double {
        guard a.scale > 0 else { return 0 }
        return a.strength * max(0, 1 - (p - a.position).length / a.scale)
    }

    /// strength × (1 − d/scale) at the clamped projection of `p` on the segment, strength and scale linear between
    /// the ends.
    static func segmentLoss(_ a: Live, _ b: Live, at p: Vec2) -> Double {
        let ab = b.position - a.position
        let t = ab.lengthSquared > 1e-12 ? ((p - a.position).dot(ab) / ab.lengthSquared).clamped(to: 0...1) : 0
        let r = a.scale + (b.scale - a.scale) * t
        guard r > 0 else { return 0 }
        let d = (p - (a.position + ab * t)).length
        guard d < r else { return 0 }
        return (a.strength + (b.strength - a.strength) * t) * (1 - d / r)
    }

    func factor(at p: Vec2, tick: Int, receiver: Int) -> Double {
        var f = 1.0
        for c in points.indices where c != receiver { f *= 1 - loss(of: c, at: p, tick: tick) }
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
        let downwind = Vec2.heading(windDirection + .pi)
        return [
            Probe(name: "shadow 3L down, sails on", offset: { c, _ in c.axis * (3 * hull) }, sailsOn: true),
            Probe(name: "3L down her apparent wind, sails on", offset: { c, _ in
                -Vec2.heading(c.apparentWindDirection) * (3 * hull) }, sailsOn: true),
            Probe(name: "shadow 6L down, sails on", offset: { c, _ in c.axis * (6 * hull) }, sailsOn: true),
            Probe(name: "6L down her apparent wind, sails on", offset: { c, _ in
                -Vec2.heading(c.apparentWindDirection) * (6 * hull) }, sailsOn: true),
            Probe(name: "shadow 6L down, stopped", offset: { c, _ in c.axis * (6 * hull) }, sailsOn: false),
            // Stopped-downwind: a boat stopped dead downwind (true) of where the caster starts.
            Probe(name: "3L downwind (true), stopped", offset: { _, _ in downwind * (3 * hull) }, sailsOn: false),
            Probe(name: "6L downwind (true), stopped", offset: { _, _ in downwind * (6 * hull) }, sailsOn: false),
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

    /// How long the warm-up sails before t = 0: 1.2 × a point's life at her t = 0 apparent wind, so her trail is
    /// fully formed when the scenario starts.
    static func warmUpSeconds(_ caster: Boat, parameters: TurbulenceRibbons.Parameters) -> Double {
        let apparent = max(caster.apparentWind.speed, 0.5)
        return 1.2 * (parameters.life?(apparent) ?? shadow.coneLength / apparent)
    }

    /// `warmUp` (default on): before t = 0 the caster sails her t = 0 heading and speed for `warmUpSeconds`
    /// (negative ticks), stepping the ribbons, so she arrives at her t = 0 start with the trail the box assumes she
    /// always had. Off, the trail starts empty at t = 0 (the step 1 cold start). Probes and the box are the same
    /// either way.
    static func run(_ m: Manoeuvre, seconds: Double = 25,
                    parameters: TurbulenceRibbons.Parameters = .init(), warmUp: Bool = true) -> [Result] {
        var caster = boat(position: .zero, heading: m.steer(0).heading, speed: m.steer(0).speed)
        let start = ShadowCone(caster: caster, shadow: shadow)
        let v0 = caster.velocity
        let ps = probes
        let offsets = ps.map { $0.offset(start, caster) }
        var results = ps.map { _ in Result(box: [], trail: []) }
        var ribbons = TurbulenceRibbons(shadow: shadow, parameters: parameters)
        if warmUp {
            let ticks = Int((warmUpSeconds(caster, parameters: parameters) * Double(Race.tickRate)).rounded(.up))
            // The loop below moves her before stepping, so start her `ticks` steps short of .zero.
            caster.position = v0 * (-Double(ticks) * Race.dt)
            for tick in -ticks..<0 {
                caster.position += caster.velocity * Race.dt
                refresh(&caster)
                ribbons.step(boats: [caster], tick: tick)
            }
            caster.position = .zero
        }
        for tick in 0..<Int(seconds * Double(Race.tickRate)) {
            let t = Double(tick) * Race.dt
            let (h, s) = m.steer(t)
            caster.heading = h
            caster.speed = s
            caster.position += caster.velocity * Race.dt
            refresh(&caster)
            ribbons.step(boats: [caster], tick: tick)
            let cone = ShadowCone(caster: caster, shadow: shadow)
            for (i, p) in ps.enumerated() {
                let at = offsets[i] + (p.sailsOn ? v0 * t : .zero)
                // The probe is seat 1; the caster is seat 0.
                results[i].box.append(max(cone.factor(at: at), shadow.stackingFloor))
                results[i].trail.append(ribbons.factor(at: at, tick: tick, receiver: 1))
            }
        }
        return results
    }
}

@Suite struct TurbulenceTrailPrototypeTests {
    typealias S = TrailScene
    typealias R = TurbulenceRibbons

    @Test func scenariosBoxesAgainstRibbons() {
        let c = S.shadow
        let r = R(shadow: c)
        print("""
        RIBBON PROTOTYPE class: cone \(c.coneLength / S.hull) L long, \(c.coneWidthAtBoat / S.hull) -> \(c.coneWidthAtEnd / S.hull) L wide, \
        loss \(c.lossCloseIn), floor \(c.stackingFloor), swing \(c.coneSwing), fromHull \(c.coneFromHull); hull \(S.hull) m; 10 kn; \
        a point every \(r.every) ticks, lengthCap \(String(format: "%.2f", r.parameters.lengthCap)) m
        """)
        for m in S.manoeuvres {
            let results = S.run(m)
            print("== \(m.name)")
            for (p, r) in zip(S.probes, results) {
                let line = String(format: "  %-38@ box: peak %.2f, %.1f loss-s, >0.02 for %4.1f s | ribbon: peak %.2f, %.1f loss-s, >0.02 for %4.1f s",
                                  p.name as NSString, r.boxLoss, r.boxSeconds, r.seconds(above: 0.02, r.box),
                                  r.trailLoss, r.trailSeconds, r.seconds(above: 0.02, r.trail))
                print(line)
                // The factor each second, box then ribbon, in loss percent.
                let every = Race.tickRate
                let b = stride(from: 0, to: r.box.count, by: every).map { String(format: "%2.0f", (1 - r.box[$0]) * 100) }.joined(separator: " ")
                let t = stride(from: 0, to: r.trail.count, by: every).map { String(format: "%2.0f", (1 - r.trail[$0]) * 100) }.joined(separator: " ")
                print("      box    %/s: \(b)\n      ribbon %/s: \(t)")
            }
            for r in results { #expect(r.trail.allSatisfy { $0 >= S.shadow.stackingFloor && $0 <= 1 }) }
        }
        // Cold (trail empty at t = 0, step 1) against warm (the default): how much of each ribbon number was the
        // cold start. The box is the same both ways.
        print("== cold against warm: peak / loss-s, box | ribbon cold | ribbon warm")
        for m in S.manoeuvres {
            print("== \(m.name), warm-up \(String(format: "%.1f", S.warmUpSeconds(S.boat(position: .zero, heading: m.steer(0).heading, speed: m.steer(0).speed), parameters: .init()))) s")
            let cold = S.run(m, warmUp: false), warm = S.run(m)
            for (p, (c, w)) in zip(S.probes, zip(cold, warm)) {
                #expect(c.box == w.box)
                print(String(format: "  %-38@ box %.2f / %4.1f | cold %.2f / %4.1f | warm %.2f / %4.1f", p.name as NSString,
                             c.boxLoss, c.boxSeconds, c.trailLoss, c.trailSeconds, w.trailLoss, w.trailSeconds))
            }
        }
        // The extra turn, for comparison: 5 degrees (Richards, upwind) on the steady boat and the tack.
        var turned = R.Parameters()
        turned.extraTurnDegrees = 5
        for m in S.manoeuvres.prefix(2) {
            print("== \(m.name), extraTurn 5")
            for (p, r) in zip(S.probes, S.run(m, parameters: turned)) {
                print(String(format: "  %-38@ ribbon: peak %.2f, %.1f loss-s", p.name as NSString, r.trailLoss, r.trailSeconds))
            }
        }
    }

    /// The ribbon reproduces the box when nothing manoeuvres: print-only, as the disc prototype's was (no tolerance).
    @Test func steadyTrailMatchesTheBoxRoughly() {
        let warm = S.run(S.manoeuvres[0]), cold = S.run(S.manoeuvres[0], warmUp: false)
        // Cold: skip the first 12 s while the ribbon fills (it is `coneLength / apparent` long). Warm: all of it.
        let skip = 12 * Race.tickRate
        func mean(_ xs: ArraySlice<Double>) -> Double { xs.map { 1 - $0 }.reduce(0, +) / Double(xs.count) }
        for (p, (c, w)) in zip(S.probes, zip(cold, warm)) {
            print(String(format: "STEADY %-38@ mean loss box %.3f ribbon cold (from 12 s) %.3f warm %.3f", p.name as NSString,
                         mean(w.box[...]), mean(c.trail.dropFirst(skip)), mean(w.trail[...])))
        }
    }

    @Test func trailsAreDeterministic() {
        #expect(S.run(S.manoeuvres[1]) == S.run(S.manoeuvres[1]))
    }

    // MARK: The model

    /// One caster sailing upwind steadily for `seconds`.
    static func sail(seconds: Double, parameters: R.Parameters = .init(), speed: ((Int) -> Double)? = nil,
                     scales: ((Int) -> Double)? = nil) -> (R, Int) {
        let up = S.upwind
        var b = S.boat(position: .zero, heading: S.windDirection - up.twa, speed: up.speed)
        var r = R(shadow: S.shadow, parameters: parameters)
        let ticks = Int(seconds * Double(Race.tickRate))
        for tick in 0..<ticks {
            b.speed = speed?(tick) ?? up.speed
            b.position += b.velocity * Race.dt
            S.refresh(&b)
            r.step(boats: [b], tick: tick, scales: scales.map { [$0(tick)] })
        }
        return (r, ticks - 1)
    }

    @Test func scaleGrowsAsTheRootOfAge() {
        let (r, _) = Self.sail(seconds: 0.1)
        let p = r.points[0][0], s0 = p.scale
        let age = 0.5, at = { (a: Double) in r.live(p, tick: p.born + Int((a / Race.dt).rounded())).scale }
        #expect(abs((at(4 * age) - s0) - 2 * (at(age) - s0)) < 1e-9)
        #expect(abs(s0 - S.shadow.coneWidthAtBoat / 2) < 1e-12)
        // And it reaches the box's end width at the end of life.
        #expect(abs(p.scale + p.growth * p.life.squareRoot() - S.shadow.coneWidthAtEnd / 2) < 1e-9)
    }

    @Test func strengthFadesSmoothlyToNothing() {
        // A life of exactly 3 s, so half and whole lives fall on ticks.
        var params = R.Parameters()
        params.life = { _ in 3 }
        let (r, _) = Self.sail(seconds: 0.1, parameters: params)
        let p = r.points[0][0]
        #expect(r.live(p, tick: p.born).strength == S.shadow.lossCloseIn)
        #expect(abs(r.live(p, tick: p.born + 45).strength - 0.5 * S.shadow.lossCloseIn) < 1e-12)
        #expect(r.live(p, tick: p.born + 90).strength == 0)
    }

    @Test func aSteadyBoatSailsOneRibbon() {
        let (r, tick) = Self.sail(seconds: 10)
        let runs = r.ribbons(of: 0, tick: tick)
        #expect(runs.count == 1)
        #expect(runs[0].count == r.pointMap(of: 0, tick: tick).count)
    }

    @Test func zeroEmissionBreaksTheRibbon() {
        // Her sail along the wind for 1 s from t=3: m = 0 there, a zero point (or two) between two ribbons.
        let (r, tick) = Self.sail(seconds: 6, scales: { (90..<120).contains($0) ? 0 : 1 })
        let runs = r.ribbons(of: 0, tick: tick)
        #expect(runs.count == 4)
        #expect(runs.filter { $0.count == 1 && $0[0].strength == 0 }.count == 2)
    }

    @Test func stoppingBreaksTheRibbon() {
        // Stopped for 1 s from t=3: no points then, two ribbons.
        let (r, tick) = Self.sail(seconds: 6, speed: { (90..<120).contains($0) ? 0 : S.upwind.speed })
        let runs = r.ribbons(of: 0, tick: tick)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.allSatisfy { $0.strength > 0 } })
    }

    @Test func separationPastTheCapBreaksTheRibbon() {
        // Close-hauled neighbours sit apparent × 0.5 s ≈ 3.5 m apart: a 3 m cap breaks every joint.
        var params = R.Parameters()
        params.lengthCap = 3
        let (r, tick) = Self.sail(seconds: 5, parameters: params)
        let runs = r.ribbons(of: 0, tick: tick)
        #expect(runs.count == r.pointMap(of: 0, tick: tick).count)
        #expect(runs.allSatisfy { $0.count == 1 })
    }

    @Test func aSegmentInterpolatesBetweenItsEnds() {
        let (r, tick) = Self.sail(seconds: 3)
        let run = r.ribbons(of: 0, tick: tick)[0]
        let a = run[0], b = run[1]
        let mid = (a.position + b.position) / 2
        // At the midpoint, d = 0: the loss is the mean of the ends' strengths (the neighbours either side are weaker
        // or further than the midpoint's own segment).
        #expect(abs(r.loss(of: 0, at: mid, tick: tick) - (a.strength + b.strength) / 2) < 1e-9)
        // Half the mean scale off the segment, square to its midpoint: this segment leaves half the mean strength
        // there (the ribbon's loss is at least that).
        let across = (b.position - a.position).normalized.rightPerp
        let r0 = (a.scale + b.scale) / 2
        let side = r.loss(of: 0, at: mid + across * (r0 / 2), tick: tick)
        #expect(side >= (a.strength + b.strength) / 4 - 1e-9)
    }

    @Test func lossIsTheStrongestRibbon() {
        // Stopped for 1 s from t=3: two ribbons. Just astern of the newer one's oldest point both reach; the loss is
        // the stronger of the two, not their sum.
        let (r, tick) = Self.sail(seconds: 6, speed: { (90..<120).contains($0) ? 0 : S.upwind.speed })
        let runs = r.ribbons(of: 0, tick: tick)
        #expect(runs.count == 2)
        let older = runs[0], newer = runs[1]
        let p = (older[older.count - 1].position + newer[0].position) / 2
        let each = runs.map { R.loss(along: $0, at: p) }
        #expect(each.allSatisfy { $0 > 0 })
        #expect(abs(r.loss(of: 0, at: p, tick: tick) - each.max()!) < 1e-12)
        // The walk agrees with the ribbons everywhere along the trail, breaks and lone points included.
        let (z, zt) = Self.sail(seconds: 8, scales: { (90..<120).contains($0) || (150..<170).contains($0) ? 0 : 1 })
        for q in z.pointMap(of: 0, tick: zt) {
            for off in [Vec2(0, 0), Vec2(2, 1), Vec2(-4, 3)] {
                let walked = z.loss(of: 0, at: q.position + off, tick: zt)
                let built = z.ribbons(of: 0, tick: zt).reduce(0) { max($0, R.loss(along: $1, at: q.position + off)) }
                #expect(abs(walked - built) < 1e-12)
            }
        }
        // Casters stack as a product, floored.
        #expect(r.factor(at: p, tick: tick, receiver: 1) == max(1 - r.loss(of: 0, at: p, tick: tick), S.shadow.stackingFloor))
    }

    @Test func extraTurnIsInertAtZeroAndTurnsAstern() {
        let up = S.upwind
        let b = S.boat(position: .zero, heading: S.windDirection - up.twa, speed: up.speed)
        #expect(R(shadow: S.shadow).drift(of: b) == b.windOverGround.velocity)
        var params = R.Parameters()
        params.extraTurnDegrees = 5
        let relative0 = b.windOverGround.velocity - b.velocityOverGround
        let relative5 = R(shadow: S.shadow, parameters: params).drift(of: b) - b.velocityOverGround
        let astern = -b.forward
        let angle = { (v: Vec2) in abs(atan2(v.cross(astern), v.dot(astern))) }
        #expect(abs(angle(relative0) - angle(relative5) - deg2rad(5)) < 1e-9)
        #expect(abs(relative0.length - relative5.length) < 1e-9)
    }

    /// 16 boats in the sim's shape: cones (`applyWindShadows`) against ribbons, timed per tick on the host (the ratio
    /// is the finding; device numbers are #172's).
    @Test func costAt16Boats() {
        let up = S.upwind
        var boats: [Boat] = (0..<16).map { i in
            let row = Double(i / 8), col = Double(i % 8)
            let h = S.windDirection + (i % 2 == 0 ? -up.twa : up.twa)
            return S.boat(id: i, position: Vec2(col * 3 * S.hull, row * 4 * S.hull), heading: h, speed: up.speed)
        }
        let ticks = 20 * Race.tickRate
        var ribbons = R(shadow: S.shadow)
        let clock = ContinuousClock()
        var boxTime = Duration.zero, ribbonTime = Duration.zero, maxPoints = 0, maxPerCaster = 0
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
            ribbons.step(boats: boats, tick: tick)
            for i in boats.indices { sink += ribbons.factor(at: boats[i].position, tick: tick, receiver: i) }
            ribbonTime += start.duration(to: clock.now)
            maxPoints = max(maxPoints, ribbons.pointCount)
            maxPerCaster = max(maxPerCaster, ribbons.points.map(\.count).max() ?? 0)
        }
        let ms = { (d: Duration) in (Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15) / Double(ticks) }
        let stride = MemoryLayout<R.Point>.stride
        print(String(format: "COST 16 boats (host): boxes %.4f ms/tick, ribbons %.4f ms/tick (x%.1f); up to %d points (%d per caster), %d B each = %d B live (sink %.1f)",
                     ms(boxTime), ms(ribbonTime), ms(ribbonTime) / max(ms(boxTime), 1e-9), maxPoints, maxPerCaster,
                     stride, maxPoints * stride, sink))
        #expect(maxPoints > 0)
    }
}
