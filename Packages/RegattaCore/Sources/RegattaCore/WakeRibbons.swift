import Foundation

/// The wind shadow as a ribbon wake (#377, from #376's prototype). Every boat leaves points in space at a fixed
/// interval, each with a strength and a scale (its radius of influence). A point drifts with the true wind over the
/// ground; with age its scale grows (as √age) and its strength fades smoothly to exactly 0 at the end of its life. A
/// caster's consecutive points are joined into a ribbon whose strength and scale interpolate along each segment; the
/// ribbon breaks where an end has no strength or no scale, where an emission was skipped (stopped, ghost) or where
/// neighbours have drifted apart past a length cap. A boat's loss from one caster is the strongest ribbon reaching
/// her; casters stack by product, floored at the class's stacking floor.
///
/// Every size is the class file's (`BoatClass.WindShadow.ribbons`, ADR 0004). The points are race state: stepped a tick
/// at a time from the boats' states, in plain arrays in seat and emission order, so a race replays them exactly, and
/// carried whole in the in-memory snapshot (`WorldSnapshot.wake`).
public struct TurbulenceRibbons: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        /// Where she was at emission, and how it drifts (ground frame, m/s).
        public var position: Vec2
        public var drift: Vec2
        public var born: Int
        /// Strength and scale at emission (already × the emission level), the scale's √age growth rate, life (s).
        public var peak: Double
        public var scale: Double
        public var growth: Double
        public var life: Double

        public init(position: Vec2, drift: Vec2, born: Int, peak: Double, scale: Double, growth: Double, life: Double) {
            self.position = position
            self.drift = drift
            self.born = born
            self.peak = peak
            self.scale = scale
            self.growth = growth
            self.life = life
        }
    }

    /// A point now: what a bot reads from the point map.
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
    /// Each caster's live points, oldest first.
    public private(set) var points: [[Point]]
    /// Each seat's emission level now, 0...1. Empty until the first step.
    public private(set) var levels: [Double]

    public init(shadow: BoatClass.WindShadow) {
        self.init(shadow: shadow, points: [], levels: [])
    }

    /// A wake restored from a snapshot.
    public init(shadow: BoatClass.WindShadow, points: [[Point]], levels: [Double]) {
        self.shadow = shadow
        self.points = points
        self.levels = levels
    }

    public var parameters: BoatClass.WindShadow.Ribbons { shadow.ribbons }

    /// Ticks between emissions.
    public var every: Int { Self.every(emitSeconds: parameters.emitSeconds) }

    public static func every(emitSeconds: Double) -> Int { max(1, Int((emitSeconds / Race.dt).rounded())) }

    /// The tick `seconds` after `tick`, to the nearest (a bot's forecast reads the wake at it without holding a `Race`).
    public static func tick(after seconds: Double, from tick: Int) -> Int {
        tick + Int((seconds * Double(Race.tickRate)).rounded())
    }

    public var pointCount: Int { points.reduce(0) { $0 + $1.count } }

    /// Call every tick. `scales`, by seat (nil = 1 for all), is each boat's emission level target (her sail's working
    /// scale, `SailTrim.workingScale`), smoothed into `levels`: a level falls to its target at once and rises towards it
    /// linearly over `buildSeconds`. A seat's first level is its target. Points are shed on ticks that are multiples of
    /// `every` (before the gun too: Swift's `%` is 0 only on exact multiples, negative ones included).
    public mutating func step(boats: [Boat], tick: Int, scales: [Double]? = nil) {
        while points.count < boats.count { points.append([]) }
        for c in points.indices { points[c].removeAll { Double(tick - $0.born) * Race.dt >= $0.life } }
        let p = parameters
        let rise = p.buildSeconds > 0 ? Race.dt / p.buildSeconds : 1
        for seat in boats.indices {
            let target = (scales.map { seat < $0.count ? $0[seat] : 1 } ?? 1).clamped(to: 0...1)
            if seat >= levels.count {
                levels.append(target)
            } else {
                levels[seat] = target < levels[seat] ? target : min(target, levels[seat] + rise)
            }
        }
        guard tick % every == 0 else { return }
        let s0 = p.startWidth / 2, s1 = p.endWidth / 2
        for (seat, b) in boats.enumerated() where !b.isGhost && b.speedThroughWater >= p.stoppedSpeed {
            let m = levels[seat]
            let apparent = max(b.apparentWind.speed, 0.5)
            let life = p.life(apparent: apparent, coneLength: shadow.coneLength)
            points[seat].append(Point(position: b.position, drift: b.windOverGround.velocity, born: tick,
                                      peak: p.peak * m, scale: s0 * m, growth: (s1 - s0) / life.squareRoot() * m,
                                      life: life))
        }
    }

    public static func smoothstep(_ x: Double) -> Double { let t = x.clamped(to: 0...1); return t * t * (3 - 2 * t) }

    public func live(_ p: Point, tick: Int) -> Live {
        live(p, age: max(0, Double(tick - p.born) * Race.dt))
    }

    public func live(_ p: Point, age: Double) -> Live {
        Live(position: p.position + p.drift * age, strength: p.peak * (1 - Self.smoothstep(age / p.life)),
             scale: p.scale + p.growth * age.squareRoot())
    }

    /// The caster's live points now, oldest first: the short list a bot reads.
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

    /// Every caster's live points at one tick, walked once for all the receivers the race shades that tick
    /// (`frame(tick:)`): the same losses as `loss(of:at:tick:)` and `unflooredFactor(at:tick:receiver:)`, bit for bit,
    /// without rebuilding each point's live state for every receiver.
    public struct Frame: Sendable {
        /// One caster's live points, oldest first; whether each is joined to the one before it (`joined`); and the box
        /// round every point's disc (no loss reaches outside it: a segment's points and radius are between its ends').
        struct Caster: Sendable {
            var lives: [Live] = []
            var joinedBack: [Bool] = []
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        }
        let casters: [Caster]

        /// As `TurbulenceRibbons.loss(of:at:tick:)` at the frame's tick: the strongest segment of each run, a lone
        /// point's disc. Max is exact and order-free, so it equals the walk.
        public func loss(of c: Int, at p: Vec2) -> Double {
            guard c < casters.count else { return 0 }
            let caster = casters[c]
            guard p.x >= caster.minX, p.x <= caster.maxX, p.y >= caster.minY, p.y <= caster.maxY else { return 0 }
            let lives = caster.lives, joinedBack = caster.joinedBack
            var best = 0.0
            for k in lives.indices {
                if joinedBack[k] {
                    best = max(best, TurbulenceRibbons.segmentLoss(lives[k - 1], lives[k], at: p))
                } else if k + 1 == lives.count || !joinedBack[k + 1] {
                    best = max(best, TurbulenceRibbons.discLoss(lives[k], at: p))
                }
            }
            return best
        }

        /// As `TurbulenceRibbons.unflooredFactor(at:tick:receiver:)`: each caster's `1 - loss` in seat order.
        public func unflooredFactor(at p: Vec2, receiver: Int) -> Double {
            var f = 1.0
            for c in casters.indices where c != receiver { f *= 1 - loss(of: c, at: p) }
            return f
        }
    }

    /// The wake at `tick`, for every receiver at once (`Frame`).
    public func frame(tick: Int) -> Frame {
        Frame(casters: points.map { run in
            var caster = Frame.Caster()
            var previous: (point: Point, live: Live)?
            for q in run where Double(tick - q.born) * Race.dt < q.life {
                let l = live(q, tick: tick)
                caster.joinedBack.append(previous.map { joined($0.point, $0.live, q, l) } ?? false)
                caster.lives.append(l)
                // A nanometre over, so the box never clips a loss by a rounding of the segment's own arithmetic.
                let r = max(0, l.scale) + 1e-9
                caster.minX = min(caster.minX, l.position.x - r)
                caster.maxX = max(caster.maxX, l.position.x + r)
                caster.minY = min(caster.minY, l.position.y - r)
                caster.maxY = max(caster.maxY, l.position.y + r)
                previous = (q, l)
            }
            return caster
        })
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
    public func unflooredFactor(at p: Vec2, tick: Int, receiver: Int) -> Double {
        var f = 1.0
        for c in points.indices where c != receiver { f *= 1 - loss(of: c, at: p, tick: tick) }
        return f
    }

    /// The strength a point is shed with at the full level: the drawing's full alpha.
    public var peak: Double { parameters.peak }
}

/// How the sail is drawn and how hard it works (#377): one definition for the sim (the ribbons' emission level and the
/// backwind) and the app's drawing (`BoatStyle`'s defaults are these; a test holds `BoatPose.angleOfAttack` to
/// `angleOfAttack` at them).
public struct SailTrim: Equatable, Sendable {
    /// The sail's trim off the centreline per radian of apparent wind off the bow, and its least and most, degrees.
    public var perApparentAngle: Double
    public var minTrimDegrees: Double
    public var maxTrimDegrees: Double
    /// Head to wind: her true wind angle within this many degrees past the class's no-go angle, the sail doesn't draw.
    public var headToWindMarginDegrees: Double

    public init(perApparentAngle: Double, minTrimDegrees: Double, maxTrimDegrees: Double, headToWindMarginDegrees: Double) {
        self.perApparentAngle = perApparentAngle
        self.minTrimDegrees = minTrimDegrees
        self.maxTrimDegrees = maxTrimDegrees
        self.headToWindMarginDegrees = headToWindMarginDegrees
    }

    /// The sim's (and the drawing's default).
    public static let standard = SailTrim(perApparentAngle: 0.5, minTrimDegrees: 4, maxTrimDegrees: 85, headToWindMarginDegrees: 2)

    /// The apparent wind off her bow, radians (0...π), as her sail trims to it: the sailing wind's angle before the race
    /// has given her an apparent wind.
    public static func apparentAngle(_ boat: Boat) -> Double {
        boat.apparentWind.speed > 0.01 ? abs(wrapAngle(boat.apparentWind.direction - boat.heading)) : boat.twa
    }

    /// Head to wind: so close past the class's no-go angle her sail doesn't draw.
    public func isHeadToWind(_ boat: Boat, boatClass: BoatClass) -> Bool {
        boat.twa < BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(headToWindMarginDegrees)
    }

    /// The angle between her sail as drawn and her apparent wind, radians, 0 up: 0 head to wind and with her sheets out
    /// (the sail weathervanes to the apparent wind, until it can go no further); by the lee her sail is out as far as it
    /// goes; otherwise it trims `perApparentAngle` of the apparent angle, between `minTrimDegrees` and `maxTrimDegrees`.
    /// Without her autohelm's footed ease (#219).
    public func angleOfAttack(_ boat: Boat, ease: Bool, boatClass: BoatClass) -> Double {
        guard !isHeadToWind(boat, boatClass: boatClass) else { return 0 }
        let maxTrim = deg2rad(maxTrimDegrees)
        let minTrim = min(deg2rad(minTrimDegrees), maxTrim)
        let awa = Self.apparentAngle(boat)
        let trim: Double
        if ease {
            trim = awa.clamped(to: minTrim...maxTrim)
        } else if boat.isByTheLee {
            trim = maxTrim
        } else {
            trim = (awa * perApparentAngle).clamped(to: minTrim...maxTrim)
        }
        return max(0, awa - trim)
    }

    /// How hard her sail works now, 0...1: `angleOfAttack` over the class's `ribbons.fullAngle`, capped at 1 (a stalled
    /// or running sail). Eased, luffing, head to wind: 0. The ribbons' emission level target and the backwind's.
    public func workingScale(of boat: Boat, ease: Bool, boatClass: BoatClass) -> Double {
        let full = max(boatClass.windShadow.ribbons.fullAngle, deg2rad(0.1))
        return (angleOfAttack(boat, ease: ease, boatClass: boatClass) / full).clamped(to: 0...1)
    }
}

/// Each seat's backwind level and the side it is cast on (#377): the backwind is upwash off a working sail, so it
/// follows her sail's working scale (`SailTrim.workingScale`), smoothed its own way, apart from the ribbons' emission
/// `levels`: it rises towards the target linearly over `buildSeconds` and falls towards it linearly over `fadeSeconds`,
/// so easing or luffing fades it rather than cutting it.
///
/// It sits on her windward side (`Boat.tack`), which flips at the boom crossing (#71). A fading zone keeps the side it
/// was cast on (`sides`): when her side changes it falls to 0 on the old one, whatever her sail does, and only then
/// takes her side now and builds there. Stepped a tick at a time: deterministic, and race state (`WorldSnapshot`). A
/// seat's first level is its target, on her side then.
public struct BackwindSails: Equatable, Sendable {
    /// Each seat's level now, 0...1. Empty until the first step.
    public private(set) var levels: [Double]
    /// The side each seat's backwind is cast on now.
    public private(set) var sides: [Tack]

    public init(levels: [Double] = [], sides: [Tack] = []) {
        precondition(levels.count == sides.count, "a backwind level for every side")
        self.levels = levels
        self.sides = sides
    }

    /// Call every tick with `boats` and each one's working scale target (`scales`, by seat; missing = 1).
    public mutating func step(boats: [Boat], scales: [Double], buildSeconds: Double, fadeSeconds: Double) {
        let rise = buildSeconds > 0 ? Race.dt / buildSeconds : 1
        let fall = fadeSeconds > 0 ? Race.dt / fadeSeconds : 1
        for (seat, b) in boats.enumerated() {
            let target = (seat < scales.count ? scales[seat] : 1).clamped(to: 0...1)
            guard seat < levels.count else {
                levels.append(target)
                sides.append(b.tack)
                continue
            }
            let level = levels[seat]
            if sides[seat] != b.tack {
                // Her side has flipped: the old zone fades out where it is, then the new one starts from nothing.
                levels[seat] = max(0, level - fall)
                if levels[seat] == 0 { sides[seat] = b.tack }
            } else if target < level {
                levels[seat] = max(target, level - fall)
            } else {
                levels[seat] = min(target, level + rise)
            }
        }
    }
}
