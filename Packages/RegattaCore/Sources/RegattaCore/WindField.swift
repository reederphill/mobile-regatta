import Foundation

/// The wind over the ground at one place and tick, before any boat's shadow (#79).
public struct GroundWind: Hashable, Sendable {
    /// Compass direction the wind blows from, radians in [−π, π).
    public let direction: Double
    /// Metres per second.
    public let speed: Double

    public init(direction: Double, speed: Double) {
        self.direction = direction
        self.speed = speed
    }
}

public enum WindFieldError: Error, Equatable, Sendable {
    /// Sampling needs key `window`, which the field doesn't hold. The field never extrapolates past its
    /// keys (ADR 0001): a caller without the key must get it, not guess.
    case missingKey(Int)
    /// `tick` is before the origin of the window grid.
    case beforeOrigin(tick: Int)
}

/// The race's true wind: a pure function of the public `WindSetup`, the window grid, the keys held,
/// the race clock and position (ADR 0001). A value: sampling never changes it, so samples can be taken
/// in any order, by any number of readers, and give the same answer every time.
///
/// The shift from the mean direction and the strength channel are fleet-wide: the same everywhere at a
/// tick. Propagating them across the course would need keys beyond the 30 s reveal lead (ADR 0001).
/// Position matters through the puffs and lulls (#76), which each window's key spawns in the race area
/// (`PuffPlan`), and later the geographic grid (#77). A setup with no race area has no puffs.
public struct WindField: Hashable, Sendable {
    /// The knot at the origin, starting window 0: no shift, base strength, level. It stands in for a key
    /// −1 that doesn't exist. A race never samples window 0 (`WindWindows(startSequenceTicks:)`), so it
    /// never feels this knot.
    public static let firstKnot = (shift: WindKnot(value: 0, slope: 0), strength: WindKnot(value: 1, slope: 0))

    public let setup: WindSetup
    public let windows: WindWindows
    public private(set) var keys: WindKeyChain
    /// How keys spawn puffs, from the public setup; nil with no race area, so no puffs.
    let puffPlan: PuffPlan?
    /// `puffSpawns[k]`: the puffs and lulls key k spawns, made when the key is added so sampling only
    /// reads them. Empty for a window whose key isn't held. A function of the keys and setup, so two
    /// fields with the same keys hold the same spawns, whatever order the keys came in.
    private var puffSpawns: [[PuffSpawn]] = []

    public init(setup: WindSetup, windows: WindWindows, keys: WindKeyChain = WindKeyChain()) {
        self.setup = setup
        self.windows = windows
        self.keys = keys
        puffPlan = setup.raceArea.map { PuffPlan(setup: setup, area: $0) }
        for key in keys.keys { spawnPuffs(of: key) }
    }

    /// Adds a revealed key, replacing any held for its window.
    public mutating func add(_ key: WindKey) {
        keys.insert(key)
        spawnPuffs(of: key)
    }

    private mutating func spawnPuffs(of key: WindKey) {
        guard let puffPlan else { return }
        if key.window >= puffSpawns.count {
            puffSpawns += Array(repeating: [], count: key.window - puffSpawns.count + 1)
        }
        puffSpawns[key.window] = puffPlan.spawns(of: key, windows: windows)
    }

    /// The ground wind at `p` at `tick`: the fleet-wide channels, then the puffs and lulls alive at `p`.
    /// Throws `missingKey(k)` if it needs a key the field doesn't hold: window k needs keys k − 1 and k,
    /// and with puffs every key back to `firstWindowNeeded(atTick:)`, whose puffs may still be alive.
    public func sample(_ p: Vec2, tick: Int) throws(WindFieldError) -> GroundWind {
        let c = try channels(atTick: tick)
        let speed = Self.courseSpeed(setup, c)
        let direction = setup.meanDirection + c.shift
        guard let puffPlan else { return GroundWind(direction: wrapAngle(direction), speed: speed) }
        // Puffs act on top of the clamped channel: a puff may take the wind above the forecast range, as
        // a lull may below it (#10's strengths are relative to the wind around them).
        let puffs = try puffEffect(at: p, tick: tick, puffPlan)
        return GroundWind(direction: wrapAngle(direction + puffs.turn), speed: speed * puffs.factor)
    }

    /// The fleet-wide shift from the mean direction at `tick`, radians, positive veering (clockwise).
    public func shift(atTick tick: Int) throws(WindFieldError) -> Double {
        try channels(atTick: tick).shift
    }

    /// The wind speed away from any puff or lull at `tick`, m/s: the strength channel, the same across
    /// the course. What puffs are shaded against (#15), and a bot's measure of a puff.
    public func courseAverageSpeed(atTick tick: Int) throws(WindFieldError) -> Double {
        Self.courseSpeed(setup, try channels(atTick: tick))
    }

    /// Throws the `missingKey` that `sample` at `tick` would, anywhere on the water, or `beforeOrigin`;
    /// returns if the field holds every key the wind at `tick` needs.
    public func requireKeys(atTick tick: Int) throws(WindFieldError) {
        _ = try channels(atTick: tick)
        for window in firstWindowNeeded(atTick: tick)..<windows.window(containing: tick) where keys[window] == nil {
            throw .missingKey(window)
        }
    }

    /// The first window whose key the wind at `tick` (from the origin on) needs: the one before its own
    /// (its starting knot), or with puffs the first whose puffs may still be alive (`PuffPlan.lookback`),
    /// never below 0. Every key from it through `tick`'s window is needed.
    public func firstWindowNeeded(atTick tick: Int) -> Int {
        max(0, windows.window(containing: tick) - max(1, puffPlan?.lookback ?? 0))
    }

    /// Puffs and lulls alive at `tick`, for rendering and bots: those of the held keys from
    /// `firstWindowNeeded(atTick:)` on, in window and spawn order. Includes one at its spawn tick or end
    /// of life, at intensity 0. Empty with no race area.
    public func activePuffs(atTick tick: Int) -> [Puff] {
        guard puffPlan != nil, windows.window(containing: tick) >= 0 else { return [] }
        var puffs: [Puff] = []
        for window in firstWindowNeeded(atTick: tick)...windows.window(containing: tick) where window < puffSpawns.count {
            for spawn in puffSpawns[window] where spawn.isAlive(atTick: tick) {
                puffs.append(spawn.puff(atTick: tick))
            }
        }
        return puffs
    }

    /// The puffs and lulls key `window` spawns, in draw order; empty if it isn't held or there's no race area.
    func spawns(ofWindow window: Int) -> [PuffSpawn] {
        puffSpawns.indices.contains(window) ? puffSpawns[window] : []
    }

    // MARK: - Evaluation

    /// The strength channel as a speed. It stays inside the forecast strength range (#10: the forecast is
    /// never wrong); the generator caps its knots, and this catches any overshoot between them.
    static func courseSpeed(_ setup: WindSetup, _ c: Channels) -> Double {
        (setup.baseStrength * c.strength).clamped(to: setup.conditions.strength)
    }

    /// The puffs' speed factor and direction change at `p` at `tick`, summed over every puff alive there
    /// in window and spawn order, so the sum is the same whatever order samples are taken in. The factor
    /// is capped at the conditions' strongest puff and deepest lull, so overlaps never go beyond #10's
    /// strengths, and the turn at the conditions' fan.
    func puffEffect(at p: Vec2, tick: Int, _ plan: PuffPlan) throws(WindFieldError) -> (factor: Double, turn: Double) {
        let current = windows.window(containing: tick)
        var gain = 0.0, fan = 0.0
        for window in firstWindowNeeded(atTick: tick)...current {
            guard keys[window] != nil else { throw .missingKey(window) }
            for spawn in puffSpawns[window] where spawn.isAlive(atTick: tick) {
                let effect = spawn.puff(atTick: tick).effect(at: p, across: plan.acrossDownwind)
                gain += effect.speed
                fan += effect.fan
            }
        }
        let puffs = setup.conditions.puffs
        let factor = (1 + gain).clamped(to: (1 - puffs.lullLoss.upperBound)...(1 + puffs.gain.upperBound))
        // No spawn is stronger than `strongest`, so with it 0 (no gain and no loss) every fan share is 0.
        let turn = plan.strongest > 0 ? (puffs.fan * fan / plan.strongest).clamped(to: -puffs.fan...puffs.fan) : 0
        return (factor, turn)
    }

    /// Both channels and their slopes, per second, at `tick`.
    func channels(atTick tick: Int) throws(WindFieldError) -> Channels {
        let k = windows.window(containing: tick)
        guard k >= 0 else { throw .beforeOrigin(tick: tick) }
        let fraction = Double(tick - windows.start(of: k)) / Double(WindWindows.ticksPerWindow)
        return try channels(window: k, fraction: fraction)
    }

    /// Both channels at `fraction` (0…1) of the way through `window`: a cubic Hermite curve from the knot in
    /// key `window − 1` (or `firstKnot`) to the knot in key `window`, plus the window's wobble on the shift.
    /// Fraction 1 gives the knot itself, as the start of the next window does.
    func channels(window k: Int, fraction s: Double) throws(WindFieldError) -> Channels {
        let from: (shift: WindKnot, strength: WindKnot)
        if k == 0 {
            from = Self.firstKnot
        } else {
            guard let previous = keys[k - 1] else { throw .missingKey(k - 1) }
            from = (previous.shift, previous.strength)
        }
        guard let key = keys[k] else { throw .missingKey(k) }
        let shift = Self.hermite(from.shift, key.shift, s)
        let wobble = Self.wobble(key.wobble, s)
        let strength = Self.hermite(from.strength, key.strength, s)
        return Channels(shift: shift.value + wobble.value, shiftSlope: shift.slope + wobble.slope,
                        strength: strength.value, strengthSlope: strength.slope)
    }

    struct Channels: Equatable {
        /// Radians, and radians per second.
        let shift: Double
        let shiftSlope: Double
        /// Factor of base strength, and per second.
        let strength: Double
        let strengthSlope: Double
    }

    /// Cubic Hermite from `a` to `b` over one window, at fraction `s`; the slope is per second. Written
    /// as `a` plus changes, so it gives `a` exactly at `s` = 0 and stays exactly level between equal,
    /// level knots.
    static func hermite(_ a: WindKnot, _ b: WindKnot, _ s: Double) -> (value: Double, slope: Double) {
        let h = WindWindows.seconds
        let s2 = s * s, s3 = s2 * s
        let rise = b.value - a.value
        let value = a.value + rise * (3 * s2 - 2 * s3) + h * (a.slope * (s3 - 2 * s2 + s) + b.slope * (s3 - s2))
        let perFraction = rise * (6 * s - 6 * s2) + h * (a.slope * (3 * s2 - 4 * s + 1) + b.slope * (3 * s2 - 2 * s))
        return (value, perFraction / h)
    }

    /// Peak of `2 sin²x cos x`, at `tan² x = 2`: the wiggle's shape divided by it peaks at 1.
    static let wigglePeak = 4 / (3 * 3.0.squareRoot())

    /// The wobble at fraction `s`, and its slope per second. Both shapes and their slopes are zero at
    /// `s` = 0 and 1, so the wobble never moves a knot or its slope.
    static func wobble(_ w: WindWobble, _ s: Double) -> (value: Double, slope: Double) {
        guard w != .none else { return (0, 0) }
        let x = Double.pi * s
        let sine = sin(x), cosine = cos(x)
        let hump = sine * sine
        let humpSlope = 2 * sine * cosine * .pi
        let wiggle = 2 * sine * sine * cosine / wigglePeak
        let wiggleSlope = 2 * (2 * sine * cosine * cosine - sine * sine * sine) * .pi / wigglePeak
        return (w.hump * hump + w.wiggle * wiggle, (w.hump * humpSlope + w.wiggle * wiggleSlope) / WindWindows.seconds)
    }
}

// MARK: - Puffs and lulls (#76)

/// How a race's keys spawn puffs and lulls: everything that comes from the public `WindSetup` and its
/// race area, so a key's spawns are a function of its `puffSeed` and public information only (ADR 0001).
struct PuffPlan: Hashable, Sendable {
    /// Stream tag for `SplitMix64(seed:stream:)` on a key's `puffSeed`: ASCII "windpuff".
    static let seedStream: UInt64 = 0x7769_6E64_7075_6666
    /// A point is under a puff or lull when it changes the wind speed there by more than this fraction:
    /// the measure of the conditions' `coverage`.
    static let coverageThreshold = 0.05

    let puffs: Conditions.Puffs
    let area: RaceArea
    /// Downwind along the mean direction, and to its right (looking downwind).
    let downwind: Vec2
    let acrossDownwind: Vec2
    /// Drift speed per unit of `drift`: the race's base strength (#10: drift is a fraction of the wind).
    let baseStrength: Double
    /// How far past the race area's edges a puff's mid-life centre may lie, metres: the largest radius,
    /// so the water at the edges is as puffy as the middle.
    let margin: Double
    /// Expected spawns per window: the count is `floor` of it, plus one with its fractional part's chance.
    /// 0 when no spawn could ever change the speed by more than `coverageThreshold`: none could cover water.
    let spawnsPerWindow: Double
    /// The longest a puff lives, ticks.
    let maxLifetimeTicks: Int
    /// How many windows before its own a tick may feel puffs from: ⌈longest life / window⌉.
    let lookback: Int
    /// The largest peak `|strength|` a spawn can have: the fan peaks at `puffs.fan` for it.
    let strongest: Double

    init(setup: WindSetup, area: RaceArea) {
        let puffs = setup.conditions.puffs
        self.puffs = puffs
        self.area = area
        let downwind = -Vec2.heading(setup.meanDirection)
        self.downwind = downwind
        acrossDownwind = downwind.rightPerp
        baseStrength = setup.baseStrength
        let margin = puffs.diameter.upperBound / 2
        self.margin = margin
        let maxLifetimeTicks = Self.ticks(seconds: puffs.lifetime.upperBound)
        self.maxLifetimeTicks = maxLifetimeTicks
        lookback = (maxLifetimeTicks + WindWindows.ticksPerWindow - 1) / WindWindows.ticksPerWindow
        strongest = max(puffs.gain.upperBound, puffs.lullLoss.upperBound)

        // Spawns laid uniformly (with overlaps) cover the fraction 1 − e^(−density · footprint) of the water,
        // so `coverage` needs density · footprint = −ln(1 − coverage). A spawn's footprint over its life is
        // its lifetime × disk area × the mean share of its disk over the threshold as it fades in and out.
        let water = 4 * (area.halfWidth + margin) * (area.halfLength + margin)
        let d = puffs.diameter
        let meanRadiusSquared = (d.upperBound * d.upperBound + d.upperBound * d.lowerBound + d.lowerBound * d.lowerBound) / 12
        let meanLifetime = (puffs.lifetime.lowerBound + puffs.lifetime.upperBound) / 2
        let footprint = meanLifetime * Double.pi * meanRadiusSquared * Self.meanShareOverThreshold(puffs)
        spawnsPerWindow = footprint > 0 ? -log(1 - puffs.coverage) * water * WindWindows.seconds / footprint : 0
    }

    static func ticks(seconds: Double) -> Int {
        max(1, Int(seconds * Double(Race.tickRate)))
    }

    /// The mean share of a spawn's disk where it changes the speed by more than `coverageThreshold`,
    /// over its life and its strengths: midpoint rule over the fade and the strength ranges. With the
    /// falloff (1 − d²)², where d is the distance over the radius, peak `a` is over the threshold for
    /// d² < 1 − √(threshold / a), the share of the disk's area.
    static func meanShareOverThreshold(_ puffs: Conditions.Puffs) -> Double {
        let strengths = 16, phases = 64
        func share(_ strength: Double) -> Double {
            var total = 0.0
            for i in 0..<phases {
                let peak = strength * sin(Double.pi * (Double(i) + 0.5) / Double(phases))
                if peak > coverageThreshold { total += 1 - (coverageThreshold / peak).squareRoot() }
            }
            return total / Double(phases)
        }
        var total = 0.0
        for i in 0..<strengths {
            let u = (Double(i) + 0.5) / Double(strengths)
            let gain = puffs.gain.lowerBound + (puffs.gain.upperBound - puffs.gain.lowerBound) * u
            let loss = puffs.lullLoss.lowerBound + (puffs.lullLoss.upperBound - puffs.lullLoss.lowerBound) * u
            total += (1 - puffs.lullShare) * share(gain) + puffs.lullShare * share(loss)
        }
        return total / Double(strengths)
    }

    /// Key `key.window`'s spawns, drawn from `SplitMix64(seed: key.puffSeed, stream: seedStream)` in a fixed
    /// order with one value per slot whether or not it is used: the count, then per spawn its spawn tick in
    /// the window, lifetime, diameter, drift, lull coin, strength, and mid-life position across and along
    /// the race area. New draws go after these, so existing ones never move.
    ///
    /// Each spawns inside its window, so no puff of key k is felt before window k starts, and fades in from
    /// nothing (ADR 0001: an early key reveals little that can't soon be seen). Its mid-life centre is
    /// uniform over the race area and `margin` around it, and it spawns upwind of that by half its drift,
    /// so it drifts through the water it covers.
    func spawns(of key: WindKey, windows: WindWindows) -> [PuffSpawn] {
        var rng = SplitMix64(seed: key.puffSeed, stream: Self.seedStream)
        let whole = spawnsPerWindow.rounded(.down)
        let count = Int(whole) + (rng.unit() < spawnsPerWindow - whole ? 1 : 0)
        let up = Vec2.heading(area.axis), right = up.rightPerp
        let start = windows.start(of: key.window)
        var spawns: [PuffSpawn] = []
        spawns.reserveCapacity(count)
        for _ in 0..<count {
            let offset = min(WindWindows.ticksPerWindow - 1, Int(rng.unit() * Double(WindWindows.ticksPerWindow)))
            let lifetime = rng.range(puffs.lifetime.lowerBound, puffs.lifetime.upperBound)
            let diameter = rng.range(puffs.diameter.lowerBound, puffs.diameter.upperBound)
            let drift = rng.range(puffs.drift.lowerBound, puffs.drift.upperBound)
            let isLull = rng.unit() < puffs.lullShare
            let depth = rng.unit()
            let across = rng.unit(), along = rng.unit()

            let lifetimeTicks = min(maxLifetimeTicks, Self.ticks(seconds: lifetime))
            let strength = isLull
                ? -(puffs.lullLoss.lowerBound + (puffs.lullLoss.upperBound - puffs.lullLoss.lowerBound) * depth)
                : puffs.gain.lowerBound + (puffs.gain.upperBound - puffs.gain.lowerBound) * depth
            let midLife = area.centre
                + right * ((2 * across - 1) * (area.halfWidth + margin))
                + up * ((2 * along - 1) * (area.halfLength + margin))
            let velocity = downwind * (drift * baseStrength)
            let halfLife = Double(lifetimeTicks) / Double(Race.tickRate) / 2
            spawns.append(PuffSpawn(spawnTick: start + offset, lifetimeTicks: lifetimeTicks, radius: diameter / 2,
                                    strength: strength, origin: midLife - velocity * halfLife, velocity: velocity))
        }
        return spawns
    }
}

/// One puff or lull as its key spawned it: where and when, and how it drifts.
struct PuffSpawn: Hashable, Sendable {
    /// Race tick it spawns at, at intensity 0. It lives through `endTick`, where it is at 0 again.
    let spawnTick: Int
    let lifetimeTicks: Int
    /// Metres.
    let radius: Double
    /// Peak change in wind speed as a fraction; negative for a lull.
    let strength: Double
    /// Centre at `spawnTick`, metres.
    let origin: Vec2
    /// Drift, metres per second, downwind.
    let velocity: Vec2

    var endTick: Int { spawnTick + lifetimeTicks }

    func isAlive(atTick tick: Int) -> Bool {
        spawnTick <= tick && tick <= endTick
    }

    func puff(atTick tick: Int) -> Puff {
        let age = Double(tick - spawnTick) / Double(Race.tickRate)
        return Puff(center: origin + velocity * age, radius: radius, strength: strength, age: age,
                    lifetime: Double(lifetimeTicks) / Double(Race.tickRate), velocity: velocity)
    }
}

/// A patch of stronger (puff) or weaker (lull) breeze drifting down the course (#76), as it is at one tick.
public struct Puff: Sendable {
    public var center: Vec2
    public var radius: Double
    /// Peak change in wind speed as a fraction; negative for a lull.
    public var strength: Double
    /// Seconds since it spawned.
    public var age: Double
    /// Seconds from spawn to end of life.
    public var lifetime: Double
    /// Drift over the ground, metres per second.
    public var velocity: Vec2

    public init(center: Vec2, radius: Double, strength: Double, age: Double, lifetime: Double, velocity: Vec2 = .zero) {
        self.center = center
        self.radius = radius
        self.strength = strength
        self.age = age
        self.lifetime = lifetime
        self.velocity = velocity
    }

    /// Current strength, fading in and out over the puff's life: `strength · sin(π · age / lifetime)`,
    /// exactly 0 at spawn and at the end of life, and the same either side of mid-life. Taken on the
    /// nearer end's side of mid-life because `sin(.pi)` is 1.2e-16 in floating point, not 0.
    public var intensity: Double {
        let x = (age / lifetime).clamped(to: 0...1)
        return strength * sin(.pi * min(x, 1 - x))
    }

    /// Peak of `l (1 − d²)²` over the disk, where `l` is the offset across over the radius: at `l = 1/√5`.
    static let fanShapePeak = 16 / (25 * 5.0.squareRoot())

    /// What the puff does at `p`. `speed`: the change in wind speed as a fraction, `intensity · (1 − d²)²`,
    /// where d is the distance from the centre over the radius. `fan`: the radial outflow, as a share of
    /// the peak turn, signed positive veering: `intensity · (1 − d²)² · l / fanShapePeak`, where `l` is the
    /// offset along `across` (to the right looking downwind) over the radius. A puff spreads out as it
    /// lands, so the wind veers on its right-hand side and backs on its left; a lull draws in, the other way.
    func effect(at p: Vec2, across: Vec2) -> (speed: Double, fan: Double) {
        let offset = p - center
        let d2 = offset.lengthSquared / (radius * radius)
        guard d2 < 1 else { return (0, 0) }
        let f = 1 - d2
        let speed = intensity * f * f
        return (speed, speed * offset.dot(across) / radius / Self.fanShapePeak)
    }
}
