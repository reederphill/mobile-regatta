import Foundation
import RegattaCore

/// #376 follow-on A (Debug drawing only; nothing here sails): the ribbon model of the wind shadow, copied from the
/// prototype (`TurbulenceRibbons` in `Packages/RegattaCore/Tests/RegattaCoreTests/TurbulenceTrailPrototypeTests.swift`,
/// the reference) so the scene can draw it (`TurbulenceTrailLayer`). Every boat leaves points in space at a fixed
/// interval, each with a strength and a scale (its radius of influence). A point drifts with the true wind; with age its
/// scale grows (as √age) and its strength fades smoothly to exactly 0 at the end of its life. A caster's consecutive
/// points are joined into a ribbon whose strength and scale interpolate along each segment; the ribbon breaks where an
/// end has no strength or no scale, where an emission was skipped (stopped, ghost) or where neighbours have drifted
/// apart past a length cap. A boat's loss from one caster is the strongest ribbon reaching her; casters stack as the
/// cones do (product, floored). The race never reads it: core's cones still slow the boats.
///
/// The changes from the prototype: `parameters` can change live (`TurbulenceRibbons.Parameters(style:)`; points
/// already shed keep theirs), the ribbons can be read between ticks (`ribbons(of:time:)`, for the drawing), and the
/// emission multiplier the game feeds is the sail-angle scale (`scale(of:ease:boatClass:style:)`). Otherwise the
/// arithmetic is the prototype's, and so are its factors (`TurbulenceTrailsTests`).
struct TurbulenceRibbons {
    /// Every value here is tuning, not measured: the research (docs/research/yacht-wake-and-backwind-aerodynamics.md)
    /// gives the wake's direction (along the apparent wind, a few degrees astern of it) and nothing on its reach,
    /// growth or decay beyond "felt for up to ten boat lengths" (Marchaj, second-hand).
    struct Parameters {
        /// Seconds between a boat's points (tuning, not measured).
        var emitSeconds = 0.5
        /// A point's life in seconds at emission, given the caster's apparent wind speed (tuning, not measured).
        /// Default nil: `coneLength / apparent`, so a steady boat's ribbon is as long as her box.
        var life: ((_ apparent: Double) -> Double)? = nil
        /// Half the width at the boat and at the end of life, metres (tuning, not measured). Default nil: half the
        /// class's `coneWidthAtBoat` and `coneWidthAtEnd`.
        var startScale: Double? = nil
        var endScale: Double? = nil
        /// Strength at emission (tuning, not measured). Default nil: the class's `lossCloseIn`.
        var peak: Double? = nil
        /// Below this speed through the water a boat sheds nothing, which breaks her ribbon (tuning, not measured).
        var stoppedSpeed = 0.3
        /// Neighbouring points further apart than this, metres, aren't joined (tuning, not measured): 2 × the travel
        /// of a 10 kn apparent wind in one 0.5 s emission interval, about 1 L.
        var lengthCap = 2 * metresPerSecond(knots: 10) * 0.5
        /// Extra turning of the trail astern of the apparent-wind line, degrees (tuning; the research measures ~5°
        /// upwind, ~9° on a spinnaker reach). Default 0, inert.
        var extraTurnDegrees = 0.0
        /// The sail-angle build-up: the emission multiplier falls to a boat's scale at once and rises linearly, 0 to
        /// 1 over this many seconds. Default 0: at once.
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
    /// Live: a change applies to the points shed from then on (`every` with it); those already shed keep theirs.
    var parameters: Parameters {
        didSet { every = Self.every(parameters) }
    }
    /// Ticks between emissions.
    private(set) var every: Int
    /// Each caster's live points, oldest first.
    private(set) var points: [[Point]] = []
    /// Each seat's emission multiplier now, 0...1. Empty until the first step.
    private(set) var levels: [Double] = []

    init(shadow: BoatClass.WindShadow, parameters: Parameters = Parameters()) {
        self.shadow = shadow
        self.parameters = parameters
        self.every = Self.every(parameters)
    }

    private static func every(_ parameters: Parameters) -> Int {
        max(1, Int((parameters.emitSeconds / Race.dt).rounded()))
    }

    var pointCount: Int { points.reduce(0) { $0 + $1.count } }

    /// Call every tick. `scales`, by seat (nil = 1 for all), is each boat's emission multiplier target (the sail-angle
    /// scale), smoothed into `levels`: a level falls to its target at once and rises towards it linearly over
    /// `buildSeconds`. A seat's first level is its target.
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
        live(p, age: max(0, Double(tick - p.born) * Race.dt))
    }

    func live(_ p: Point, age: Double) -> Live {
        Live(position: p.position + p.drift * age, strength: p.peak * (1 - Self.smoothstep(age / p.life)),
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
        ribbons(of: caster) { p in Double(tick - p.born) * Race.dt }
    }

    /// The caster's ribbons at race time `time`, seconds (between ticks, for the drawing).
    func ribbons(of caster: Int, time: Double) -> [[Live]] {
        ribbons(of: caster) { p in time - Double(p.born) * Race.dt }
    }

    private func ribbons(of caster: Int, age: (Point) -> Double) -> [[Live]] {
        guard caster < points.count else { return [] }
        var runs: [[Live]] = []
        var previous: (point: Point, live: Live)?
        for p in points[caster] {
            let a = age(p)
            guard a < p.life else { continue }
            let l = live(p, age: max(0, a))
            if let pr = previous, joined(pr.point, pr.live, p, l) { runs[runs.count - 1].append(l) } else { runs.append([l]) }
            previous = (p, l)
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

    /// The point `t` (0...1) of the way from `a` to `b`: position, strength and scale linear between them, as the
    /// loss interpolates them.
    static func lerp(_ a: Live, _ b: Live, _ t: Double) -> Live {
        Live(position: a.position + (b.position - a.position) * t, strength: a.strength + (b.strength - a.strength) * t,
             scale: a.scale + (b.scale - a.scale) * t)
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

    /// The strength a point is shed with at full multiplier: the drawing's full alpha.
    var peak: Double { parameters.peak ?? shadow.lossCloseIn }

    /// How much turbulence `boat`'s sail sheds now, 0...1 (the emission multiplier's target): the angle between her
    /// drawn sail and her apparent wind (`BoatPose.angleOfAttack`) over `BoatStyle.trailFullAngleDegrees`, capped at 1
    /// (a stalled or running sail).
    static func scale(of boat: Boat, ease: Bool, boatClass: BoatClass, style: BoatStyle) -> Double {
        let full = deg2rad(max(style.trailFullAngleDegrees, 0.1))
        return (BoatPose.angleOfAttack(boat, ease: ease, boatClass: boatClass, style: style) / full).clamped(to: 0...1)
    }
}

extension BoatStyle {
    /// The sliders `TurbulenceRibbons.Parameters(style:shadow:)` reads: a change rebuilds the parameters.
    var trailTuning: [Double] {
        [trailEmitSeconds, trailLifeScale, trailStartWidth, trailEndWidth, trailPeak, trailLengthCap, trailStoppedSpeed,
         trailExtraTurnDegrees, trailBuildSeconds]
    }
}

extension TurbulenceRibbons.Parameters {
    /// The Debug sliders' (`BoatStyle.trail…`, all tuning, not measured) for `shadow`'s class. `BoatStyle.standard`'s
    /// are the prototype's defaults: each width, the peak and the life a multiple of 1 of the class's.
    init(style: BoatStyle, shadow: BoatClass.WindShadow) {
        self.init()
        emitSeconds = max(style.trailEmitSeconds, Race.dt)
        let lifeScale = max(style.trailLifeScale, 0.01)
        let length = shadow.coneLength
        life = { apparent in lifeScale * length / apparent }
        startScale = style.trailStartWidth * shadow.coneWidthAtBoat / 2
        endScale = style.trailEndWidth * shadow.coneWidthAtEnd / 2
        peak = style.trailPeak * shadow.lossCloseIn
        lengthCap = style.trailLengthCap
        stoppedSpeed = style.trailStoppedSpeed
        extraTurnDegrees = style.trailExtraTurnDegrees
        buildSeconds = style.trailBuildSeconds
    }
}
