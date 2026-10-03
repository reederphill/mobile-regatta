import Foundation

/// #376 follow-on B: the wind shadow as a ribbon wake, and the backwind as a header and a lull, behind settings
/// (`ShadowSettings`). Nothing here sails at the defaults: `ShadowSettings()` is today's cones and backwind boxes,
/// and a default race never builds a wake.
///
/// The ribbon model (owner, 2026-10-03; the prototype was `TurbulenceTrailPrototypeTests`, A's drawing reads the
/// same type). Every boat leaves points in space at a fixed interval, each with a strength and a scale (its radius of
/// influence). A point drifts with the true wind; with age its scale grows (as √age) and its strength fades smoothly
/// to exactly 0 at the end of its life. A caster's consecutive points are joined into a ribbon whose strength and
/// scale interpolate along each segment; the ribbon breaks where an end has no strength or no scale, where an emission
/// was skipped (stopped, ghost) or where neighbours have drifted apart past a length cap. A boat's loss from one
/// caster is the strongest ribbon reaching her; casters stack as the cones do (product, floored).
///
/// Derived state (ADR 0002): the points are a pure function of the boats' states at the emission ticks and their held
/// eases, all integer ticks, so a race replays them exactly. They are not in a snapshot (ADR 0005), a log or a digest:
/// a race restored from a snapshot starts with none (`Race.importSnapshot`).
public struct TurbulenceRibbons: Sendable {
    /// Every value here is tuning, not measured: the research (docs/research/yacht-wake-and-backwind-aerodynamics.md)
    /// gives the wake's direction (along the apparent wind, a few degrees astern of it) and nothing on its reach,
    /// growth or decay beyond "felt for up to ten boat lengths" (Marchaj, second-hand).
    public struct Parameters: Equatable, Sendable {
        /// Seconds between a boat's points (tuning, not measured). Default 0.5 s: 15 ticks, so a 10 L trail at a
        /// close-hauled apparent wind is ~14 points, few enough for bots to read as a point map.
        public var emitSeconds = 0.5
        /// A point's life, a multiple of the class's `coneLength` over the caster's apparent wind at emission (tuning,
        /// not measured): 1, the time her apparent wind takes to carry air one cone length astern, so a steady boat's
        /// ribbon is as long as her box.
        public var lifeScale = 1.0
        /// A fixed life in seconds over `lifeScale`'s, or nil (tests).
        public var lifeSeconds: Double? = nil
        /// Half the width at the boat and at the end of life, metres (tuning, not measured). Default nil: half the
        /// class's `coneWidthAtBoat` and `coneWidthAtEnd`, so the steady ribbon is as wide as her box at both ends.
        public var startScale: Double? = nil
        public var endScale: Double? = nil
        /// Strength at emission (tuning, not measured). Default nil: the class's `lossCloseIn`, the box's loss
        /// close in.
        public var peak: Double? = nil
        /// Below this speed through the water a boat sheds nothing, which breaks her ribbon (tuning, not measured).
        /// Default 0.3 m/s: a boat that's stopped or head to wind isn't driving air off her sails.
        public var stoppedSpeed = 0.3
        /// Neighbouring points further apart than this, metres, aren't joined (tuning, not measured). Default
        /// 2 × the travel of a 10 kn apparent wind in one emission interval: 2 × 5.14 m/s × 0.5 s = 5.14 m, about
        /// 1 L. A steady boat's neighbours sit her apparent wind × `emitSeconds` apart (3.5 m close-hauled at 10 kn)
        /// and keep that spacing in a uniform wind, so the cap only bites where the pressure field (ADR 0008) drifts
        /// them apart, or where her apparent wind is over 20 kn.
        public var lengthCap = 2 * metresPerSecond(knots: 10) * 0.5
        /// Extra turning of the trail astern of the apparent-wind line, degrees (tuning; the research measures
        /// ~5° upwind, ~9° on a spinnaker reach). Default 0, inert. Applied to the drift: a point's velocity relative
        /// to her (true wind minus her velocity over ground, which streams astern along her apparent wind) is turned
        /// by this much towards her stern line (never past it), so a steady ribbon lies this far off the apparent
        /// wind towards her centreline. Its drift over the ground is then no longer exactly the true wind.
        public var extraTurnDegrees = 0.0
        /// The sail-angle build-up: an emission multiplier falls to a boat's scale at once and rises linearly, 0 to 1
        /// over this many seconds (tuning, not measured). Default 0: at once (the prototype's); `game`'s is 2 s.
        public var buildSeconds = 0.0

        // MARK: Sail (the emission multiplier's target, `scale(of:ease:boatClass:parameters:)`)

        /// The sail's angle to her apparent wind, degrees, at which a boat sheds her full turbulence; less, less, in
        /// proportion (tuning, not measured): about the upwind groove's in the default class at 10 kn.
        public var fullAngleDegrees = 12.5
        /// The drawn sail's trim off the centreline per radian of apparent wind off the bow, and its least and most,
        /// degrees; head to wind this close past the class's no-go angle it doesn't draw (the app's `BoatStyle`
        /// sail values, which A's drawing reads: `BoatPose.angleOfAttack`).
        public var trimPerApparentAngle = 0.5
        public var minTrimDegrees = 4.0
        public var maxTrimDegrees = 85.0
        public var headToWindMarginDegrees = 2.0

        public init() {}

        /// The game's: the prototype's with the 2 s build-up the drawing uses (`BoatStyle.trailBuildSeconds`).
        public static var game: Parameters {
            var p = Parameters()
            p.buildSeconds = 2
            return p
        }

        /// A point's life, seconds, shed by a caster with `apparent` m/s of apparent wind in `shadow`'s class.
        public func life(apparent: Double, shadow: BoatClass.WindShadow) -> Double {
            lifeSeconds ?? lifeScale * shadow.coneLength / apparent
        }
    }

    public struct Point: Equatable, Sendable {
        /// Where she was at emission, and how it drifts (ground frame).
        public var position: Vec2
        public var drift: Vec2
        public var born: Int
        /// Strength and scale at emission (already × the emission multiplier), the scale's √age growth rate, life.
        public var peak: Double
        public var scale: Double
        public var growth: Double
        public var life: Double
    }

    /// A point now: what a bot would read from the point map.
    public struct Live: Equatable, Sendable {
        public var position: Vec2
        public var strength: Double
        public var scale: Double

        public init(position: Vec2, strength: Double, scale: Double) {
            self.position = position
            self.strength = strength
            self.scale = scale
        }
    }

    public let shadow: BoatClass.WindShadow
    /// Live: a change applies to the points shed from then on (`every` with it); those already shed keep theirs.
    public var parameters: Parameters {
        didSet { every = Self.every(parameters) }
    }
    /// Ticks between emissions.
    public private(set) var every: Int
    /// Each caster's live points, oldest first.
    public private(set) var points: [[Point]] = []
    /// Each seat's emission multiplier now, 0...1. Empty until the first step.
    public private(set) var levels: [Double] = []

    public init(shadow: BoatClass.WindShadow, parameters: Parameters = Parameters()) {
        self.shadow = shadow
        self.parameters = parameters
        self.every = Self.every(parameters)
    }

    private static func every(_ parameters: Parameters) -> Int {
        max(1, Int((parameters.emitSeconds / Race.dt).rounded()))
    }

    public var pointCount: Int { points.reduce(0) { $0 + $1.count } }

    /// Call every tick. `scales`, by seat (nil = 1 for all), is each boat's emission multiplier target (the sail-angle
    /// scale), smoothed into `levels`: a level falls to its target at once and rises towards it linearly over
    /// `buildSeconds`. A seat's first level is its target. Points are shed on ticks that are multiples of `every`
    /// (before the gun too: Swift's `%` is 0 only on exact multiples, negative ones included).
    public mutating func step(boats: [Boat], tick: Int, scales: [Double]? = nil) {
        while points.count < boats.count { points.append([]) }
        for c in points.indices { points[c].removeAll { Double(tick - $0.born) * Race.dt >= $0.life } }
        stepLevels(seats: boats.count, scales: scales)
        guard tick % every == 0 else { return }
        for (seat, b) in boats.enumerated() where !b.isGhost && b.speedThroughWater >= parameters.stoppedSpeed {
            let m = levels[seat]
            let apparent = max(b.apparentWind.speed, 0.5)
            let life = parameters.life(apparent: apparent, shadow: shadow)
            let s0 = parameters.startScale ?? shadow.coneWidthAtBoat / 2
            let s1 = parameters.endScale ?? shadow.coneWidthAtEnd / 2
            points[seat].append(Point(position: b.position, drift: drift(of: b), born: tick,
                                      peak: (parameters.peak ?? shadow.lossCloseIn) * m, scale: s0 * m,
                                      growth: (s1 - s0) / life.squareRoot() * m, life: life))
        }
    }

    /// Steps `levels` alone, as `step(boats:tick:scales:)` does, shedding no points: the sail multiplier for a reader
    /// that needs it without the wake (`Race`'s backwind at `BackwindModel.headerAndLull`, the app's backwind stripes).
    public mutating func stepLevels(seats: Int, scales: [Double]?) {
        let rise = parameters.buildSeconds > 0 ? Race.dt / parameters.buildSeconds : 1
        for seat in 0..<seats {
            let target = (scales.map { seat < $0.count ? $0[seat] : 1 } ?? 1).clamped(to: 0...1)
            if seat >= levels.count {
                levels.append(target)
            } else {
                levels[seat] = target < levels[seat] ? target : min(target, levels[seat] + rise)
            }
        }
    }

    /// The true wind at her, turned `extraTurnDegrees` towards her stern line in her frame.
    public func drift(of b: Boat) -> Vec2 {
        let wind = b.windOverGround.velocity
        guard parameters.extraTurnDegrees != 0 else { return wind }
        let v = b.velocityOverGround
        let relative = wind - v, astern = -b.forward
        let towards = atan2(relative.cross(astern), relative.dot(astern))
        let turn = (towards < 0 ? -1.0 : 1.0) * min(abs(towards), deg2rad(parameters.extraTurnDegrees))
        let (s, c) = (sin(turn), cos(turn))
        return v + Vec2(relative.x * c - relative.y * s, relative.x * s + relative.y * c)
    }

    public static func smoothstep(_ x: Double) -> Double { let t = x.clamped(to: 0...1); return t * t * (3 - 2 * t) }

    public func live(_ p: Point, tick: Int) -> Live {
        live(p, age: max(0, Double(tick - p.born) * Race.dt))
    }

    public func live(_ p: Point, age: Double) -> Live {
        Live(position: p.position + p.drift * age, strength: p.peak * (1 - Self.smoothstep(age / p.life)),
             scale: p.scale + p.growth * age.squareRoot())
    }

    /// The caster's live points now, oldest first: the short list a bot could read.
    public func pointMap(of caster: Int, tick: Int) -> [Live] {
        guard caster < points.count else { return [] }
        return points[caster].filter { Double(tick - $0.born) * Race.dt < $0.life }.map { live($0, tick: tick) }
    }

    /// Whether two consecutive points (by emission) are joined into a segment now.
    public func joined(_ a: Point, _ la: Live, _ b: Point, _ lb: Live) -> Bool {
        b.born - a.born == every && la.strength > 0 && lb.strength > 0 && la.scale > 0 && lb.scale > 0
            && (lb.position - la.position).length <= parameters.lengthCap
    }

    /// The caster's ribbons now: runs of joined points (a lone point is a run of one).
    public func ribbons(of caster: Int, tick: Int) -> [[Live]] {
        ribbons(of: caster) { p in Double(tick - p.born) * Race.dt }
    }

    /// The caster's ribbons at race time `time`, seconds (between ticks, for the drawing).
    public func ribbons(of caster: Int, time: Double) -> [[Live]] {
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
    public func loss(of c: Int, at p: Vec2, tick: Int) -> Double {
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
    public static func loss(along run: [Live], at p: Vec2) -> Double {
        guard run.count > 1 else { return run.first.map { discLoss($0, at: p) } ?? 0 }
        return (1..<run.count).reduce(0) { max($0, segmentLoss(run[$1 - 1], run[$1], at: p)) }
    }

    public static func discLoss(_ a: Live, at p: Vec2) -> Double {
        guard a.scale > 0 else { return 0 }
        return a.strength * max(0, 1 - (p - a.position).length / a.scale)
    }

    /// The point `t` (0...1) of the way from `a` to `b`: position, strength and scale linear between them, as the
    /// loss interpolates them.
    public static func lerp(_ a: Live, _ b: Live, _ t: Double) -> Live {
        Live(position: a.position + (b.position - a.position) * t, strength: a.strength + (b.strength - a.strength) * t,
             scale: a.scale + (b.scale - a.scale) * t)
    }

    /// strength × (1 − d/scale) at the clamped projection of `p` on the segment, strength and scale linear between
    /// the ends.
    public static func segmentLoss(_ a: Live, _ b: Live, at p: Vec2) -> Double {
        let ab = b.position - a.position
        let t = ab.lengthSquared > 1e-12 ? ((p - a.position).dot(ab) / ab.lengthSquared).clamped(to: 0...1) : 0
        let r = a.scale + (b.scale - a.scale) * t
        guard r > 0 else { return 0 }
        let d = (p - (a.position + ab * t)).length
        guard d < r else { return 0 }
        return (a.strength + (b.strength - a.strength) * t) * (1 - d / r)
    }

    /// The wind multiplier every caster but `receiver` leaves at `p`: each one's `1 - loss`, multiplied, floored at
    /// the class's stacking floor.
    public func factor(at p: Vec2, tick: Int, receiver: Int) -> Double {
        max(unflooredFactor(at: p, tick: tick, receiver: receiver), shadow.stackingFloor)
    }

    /// `factor(at:tick:receiver:)` before the floor, for a caller stacking it with other multipliers.
    func unflooredFactor(at p: Vec2, tick: Int, receiver: Int) -> Double {
        var f = 1.0
        for c in points.indices where c != receiver { f *= 1 - loss(of: c, at: p, tick: tick) }
        return f
    }

    /// The strength a point is shed with at full multiplier: the drawing's full alpha.
    public var peak: Double { parameters.peak ?? shadow.lossCloseIn }

    // MARK: The sail (the emission multiplier's target)

    /// How much turbulence `boat`'s sail sheds now, 0...1 (the emission multiplier's target): the angle between her
    /// sail as drawn and her apparent wind (`angleOfAttack`) over `fullAngleDegrees`, capped at 1 (a stalled or
    /// running sail). Without her autohelm's footed ease (#219), as the drawing.
    public static func scale(of boat: Boat, ease: Bool, boatClass: BoatClass, parameters: Parameters) -> Double {
        let full = deg2rad(max(parameters.fullAngleDegrees, 0.1))
        return (angleOfAttack(boat, ease: ease, boatClass: boatClass, parameters: parameters) / full).clamped(to: 0...1)
    }

    /// The angle between her sail as drawn and her apparent wind, radians, 0 up: 0 head to wind (her true wind angle
    /// within `headToWindMarginDegrees` past the class's no-go angle) and with her sheets out (the sail weathervanes
    /// to the apparent wind, until it can go no further); by the lee her sail is out as far as it goes; otherwise it
    /// trims `trimPerApparentAngle` of the apparent angle, between `minTrimDegrees` and `maxTrimDegrees`. The app's
    /// `BoatPose.angleOfAttack` draws the same (a test holds them together).
    public static func angleOfAttack(_ boat: Boat, ease: Bool, boatClass: BoatClass, parameters: Parameters) -> Double {
        guard boat.twa >= BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(parameters.headToWindMarginDegrees) else { return 0 }
        let maxTrim = deg2rad(parameters.maxTrimDegrees)
        let minTrim = min(deg2rad(parameters.minTrimDegrees), maxTrim)
        let awa = boat.apparentWind.speed > 0.01 ? abs(wrapAngle(boat.apparentWind.direction - boat.heading)) : boat.twa
        let trim: Double
        if ease {
            trim = awa.clamped(to: minTrim...maxTrim)
        } else if boat.isByTheLee {
            trim = maxTrim
        } else {
            trim = (awa * parameters.trimPerApparentAngle).clamped(to: minTrim...maxTrim)
        }
        return max(0, awa - trim)
    }
}

/// What `Race.applyWindShadows` reads for the wind shadow (#376 follow-on B).
public enum ShadowModel: String, CaseIterable, Codable, Sendable {
    /// The cones (#10), today's.
    case boxes
    /// The ribbon wake (`TurbulenceRibbons`) in place of the cones; the backwind is still `BackwindModel`'s.
    case ribbons
    /// Both: the boxes' factor times the ribbons', floored.
    case both
}

/// How the backwind acts on a boat in it (#376 follow-on B).
public enum BackwindModel: String, CaseIterable, Codable, Sendable {
    /// The box (#298's trapezoid, or #79's band): a loss of wind speed (or, for a speed-loss class, of speed).
    case box
    /// The trapezoid as an envelope (`ShadowCone.backwindEnvelope(at:)`): a header (her wind turned towards her bow),
    /// which carries the cost, and a lull (`lullLoss`, none by default): the backwind is a shift, not a lull (the owner,
    /// 2026-10-03). A class with #79's band has no envelope and sails as `.box`.
    case headerAndLull
}

/// The sim's wind-shadow and backwind models and their sliders (#376 follow-on B), set on `Race.shadowSettings`.
/// Every value is tuning, not measured. `ShadowSettings()` is today's sim exactly: a race at the defaults steps,
/// replays and digests as before.
///
/// Not race data: these are in no `RaceSetup`, log, snapshot or digest (and can't be a class file's tuned copy,
/// which only rewrites numbers the file already holds, ADR 0004). A race with any other settings is a local Debug
/// practice race and does not replay from its log, as a tuned class file's doesn't (ADR 0004's caveat, extended).
/// Adopting a model later puts its values in a class-file version with a schema bump and a new `simulationRevision`.
public struct ShadowSettings: Equatable, Sendable {
    public var shadowModel = ShadowModel.boxes
    public var backwindModel = BackwindModel.box
    /// The ribbons' parameters (`.ribbons`, `.both`).
    public var ribbons = TurbulenceRibbons.Parameters.game
    /// The header at the full envelope (at the trapezoid's stern edge), degrees (tuning, not measured): her wind turned
    /// this far towards her bow. Several casters' headers add, up to `headerCapDegrees`. With no lull and
    /// `headerTimeConstant`'s 1 s, 8° costs the lee-bowed boat about what the box does over 20 s (+5%), most of it in
    /// height, lost before speed (`WakeRibbonsTests.leeBowDistanceMadeGoodOver20s`, `backwindIsMostlyAShift`).
    public var headerDegrees = 8.0
    /// One and a half full headers.
    public var headerCapDegrees = 12.0
    /// The lull at the full envelope, a fraction of her wind speed (or speed, for a speed-loss class), stacked as the
    /// boxes' (product, floored); nil, the class's `backwindLoss`, the box's exactly (tuning, not measured). None by
    /// default: the header carries the cost.
    public var lullLoss: Double? = 0
    /// Seconds: her header follows the envelope she sits in through a first-order lag of this time constant, so a
    /// boat crossing the trapezoid's stern edge isn't turned in one tick (tuning, not measured). 0: at once.
    public var headerTimeConstant = 1.0

    public init(shadowModel: ShadowModel = .boxes, backwindModel: BackwindModel = .box) {
        self.shadowModel = shadowModel
        self.backwindModel = backwindModel
    }
}
