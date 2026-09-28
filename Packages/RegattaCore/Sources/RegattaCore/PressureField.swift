import Foundation

// MARK: - The pressure field (#286, ADR 0008)

/// How a race's keys make its pressure field: everything that comes from the public `WindSetup`, its race area
/// and its venue pairing's across-the-wind coordinate, so the field is a function of the keys' `puffSeed`s and
/// public information only (ADR 0001). Stateless: nothing is carried from window to window but what the keys
/// themselves say, so any holder of the keys recomputes the same field (ADRs 0001, 0002, 0008).
///
/// Two layers, summed, both laid across the across-the-wind coordinate (`Venue.AcrossWind`):
/// - The **pressure side**: a slope in speed across the race area, keyed per window. Each window's key may redraw
///   it (a *setter*, with the chance of one window in `Conditions.PressureField.Side.persistence`, and always
///   window 0, which has no windows before it to look back to); a window's target is the most recent setter's draw within `sideLookback` windows, or no side at all if there is none.
///   The knot ending a window is the mean of the last `sideRampWindows` targets, and its slope the change from the
///   knot before, so a new side ramps in over two minutes, and between knots it follows the shift's Hermite curve.
/// - **Pressure lanes**: soft bands of stronger wind along the coordinate's level lines, spawned per window like
///   puffs, fading in and out over their life. Each lane's sideways position has a knot at each window's end: its
///   key draws the lane's sideways drift there, and the position moves by the mean of the drifts either side, so
///   between knots the drift is a straight line from one to the next and never beyond `lanes.drift`.
struct PressurePlan: Hashable, Sendable {
    /// Stream tags for `SplitMix64(seed:stream:)` on a key's `puffSeed`, distinct from `PuffPlan.seedStream`:
    /// ASCII "presside", "preslane" and "presdrft".
    static let sideStream: UInt64 = 0x7072_6573_7369_6465
    static let laneStream: UInt64 = 0x7072_6573_6C61_6E65
    static let driftStream: UInt64 = 0x7072_6573_6472_6674
    /// How many windows' targets a pressure side knot averages: a new side ramps in over this many windows.
    static let sideRampWindows = 4
    /// A side target looks back this many times the mean windows between setters for one, so it finds none, and
    /// the side lapses, about e⁻³ ≈ 5 % of the time.
    static let sideLookbackSetters = 3.0

    let field: Conditions.PressureField
    let acrossWind: Venue.AcrossWind
    let meanDirection: Double
    /// The across-the-wind coordinate of the race area's centre: the field's zero.
    let centre: Double
    /// Half the race area's width, metres: the pressure side reaches its full size at this distance across.
    let halfWidth: Double
    /// The chance a window's key redraws the pressure side.
    let setterChance: Double
    /// How many windows, its own included, a side target looks back for a setter.
    let sideLookback: Int
    /// How far past the race area's sides a lane's centre may form, metres: the widest half-width.
    let laneMargin: Double
    /// Expected lanes per window: `floor` of it, plus one with its fractional part's chance.
    let lanesPerWindow: Double
    /// The longest a lane lives, ticks.
    let maxLaneLifetimeTicks: Int
    /// How many windows before its own a tick may feel lanes from.
    let laneLookback: Int
    /// How many windows before its own the field at a tick needs keys from.
    let lookback: Int
    /// The largest peak lane strength: a lane's edge bend peaks at `lanes.bend` for it.
    let strongestLane: Double

    init(setup: WindSetup, area: RaceArea, field: Conditions.PressureField) {
        self.field = field
        acrossWind = setup.pairing.acrossWind
        meanDirection = setup.meanDirection
        centre = setup.pairing.acrossWind.coordinate(at: area.centre, meanDirection: setup.meanDirection)
        halfWidth = area.halfWidth
        setterChance = min(1, WindWindows.seconds / field.side.persistence)
        sideLookback = max(1, Int((Self.sideLookbackSetters / setterChance).rounded(.up)))
        let lanes = field.lanes
        laneMargin = lanes.width.upperBound / 2
        let meanLifetime = (lanes.lifetime.lowerBound + lanes.lifetime.upperBound) / 2
        lanesPerWindow = lanes.count * WindWindows.seconds / meanLifetime
        maxLaneLifetimeTicks = PuffPlan.ticks(seconds: lanes.lifetime.upperBound)
        laneLookback = (maxLaneLifetimeTicks + WindWindows.ticksPerWindow - 1) / WindWindows.ticksPerWindow
        // Window k's curve runs from knot k − 1, whose oldest target reaches back `sideRampWindows` more.
        lookback = max(Self.sideRampWindows + sideLookback, laneLookback)
        strongestLane = lanes.strength.upperBound
    }

    /// The across-the-wind coordinate at `p`, from the race area's centre, metres.
    func coordinate(at p: Vec2) -> Double {
        acrossWind.coordinate(at: p, meanDirection: meanDirection) - centre
    }

    /// Key `key.window`'s draws, from `SplitMix64(seed: key.puffSeed, stream:)` in a fixed order: for the pressure
    /// side (`sideStream`) the setter coin, the side and the size; for lanes (`laneStream`) the count, then per lane
    /// its spawn tick in the window, lifetime, width, strength, position across and first drift. New draws go after
    /// these, so existing ones never move.
    ///
    /// Each lane forms inside its window, so none is felt before its window starts, and fades in from nothing (ADR
    /// 0001). Its centre forms uniform across the race area and `laneMargin` either side.
    func draws(of key: WindKey, windows: WindWindows) -> PressureDraws {
        var rng = SplitMix64(seed: key.puffSeed, stream: Self.sideStream)
        // Window 0's key always sets a side: no window before it can, so without it the side would start absent.
        let isSetter = rng.unit() < setterChance || key.window == 0
        let sign: Double = rng.unit() < 0.5 ? -1 : 1
        let size = rng.range(0.5, 1)
        let side = isSetter ? sign * size * field.side.strength : nil

        let lanes = field.lanes
        var laneRNG = SplitMix64(seed: key.puffSeed, stream: Self.laneStream)
        let whole = lanesPerWindow.rounded(.down)
        let count = Int(whole) + (laneRNG.unit() < lanesPerWindow - whole ? 1 : 0)
        let start = windows.start(of: key.window)
        var spawns: [PressureLaneSpawn] = []
        spawns.reserveCapacity(count)
        for index in 0..<count {
            let offset = min(WindWindows.ticksPerWindow - 1, Int(laneRNG.unit() * Double(WindWindows.ticksPerWindow)))
            let lifetime = laneRNG.range(lanes.lifetime.lowerBound, lanes.lifetime.upperBound)
            let width = laneRNG.range(lanes.width.lowerBound, lanes.width.upperBound)
            let strength = laneRNG.range(lanes.strength.lowerBound, lanes.strength.upperBound)
            let across = laneRNG.unit()
            let drift = laneRNG.range(-lanes.drift, lanes.drift)
            spawns.append(PressureLaneSpawn(
                window: key.window, index: index, spawnTick: start + offset,
                lifetimeTicks: min(maxLaneLifetimeTicks, PuffPlan.ticks(seconds: lifetime)), halfWidth: width / 2,
                strength: strength, start: (2 * across - 1) * (halfWidth + laneMargin), startDrift: drift))
        }
        return PressureDraws(side: side, lanes: spawns)
    }

    /// The sideways drift key `key` draws for `lane` at the knot ending its window, metres per second: its own
    /// stream per lane, so a lane's drift never depends on which other lanes are alive.
    func drift(of lane: PressureLaneSpawn, key: WindKey) -> Double {
        let tag = Self.driftStream ^ (UInt64(bitPattern: Int64(lane.window)) &* 0x1_0000) ^ UInt64(lane.index)
        var rng = SplitMix64(seed: key.puffSeed, stream: tag)
        return rng.range(-field.lanes.drift, field.lanes.drift)
    }

    /// The field's pressure and bend at relative coordinate `r` (`coordinate(at:)`), given the pressure side's
    /// slope `side` and the lanes alive, summed in their order. The factor is kept to 0.5…2, so no overlap stops
    /// or doubles the wind; the lanes' bend is capped at `lanes.bend`.
    func effect(at r: Double, side: Double, lanes: [PressureLane]) -> (factor: Double, turn: Double) {
        let sidePressure = side * (r / halfWidth).clamped(to: -1...1)
        let sideTurn = field.side.strength > 0 ? field.side.bend * sidePressure / field.side.strength : 0
        var gain = 0.0, fan = 0.0
        for lane in lanes {
            let effect = lane.effect(at: r)
            gain += effect.speed
            fan += effect.fan
        }
        let bend = field.lanes.bend
        let laneTurn = strongestLane > 0 ? (bend * fan / strongestLane).clamped(to: -bend...bend) : 0
        return ((1 + sidePressure + gain).clamped(to: 0.5...2), sideTurn + laneTurn)
    }
}

/// What one key draws for the pressure field: its pressure side draw if it is a setter, and the lanes it spawns.
struct PressureDraws: Hashable, Sendable {
    /// The pressure side's slope this window sets, as a speed change at the race area's right-hand side (looking
    /// downwind); nil if the window doesn't redraw it.
    let side: Double?
    let lanes: [PressureLaneSpawn]

    static let none = PressureDraws(side: nil, lanes: [])
}

/// One pressure lane as its key spawned it.
struct PressureLaneSpawn: Hashable, Sendable {
    /// The window whose key spawned it, and its place in that key's draws: its drift streams' name.
    let window: Int
    let index: Int
    /// Race tick it forms at, at intensity 0. It lives through `endTick`, where it is at 0 again.
    let spawnTick: Int
    let lifetimeTicks: Int
    /// Metres across.
    let halfWidth: Double
    /// Peak gain down its middle, as a fraction of wind speed.
    let strength: Double
    /// Relative coordinate of its middle at the start of its window, and its drift there, metres per second.
    let start: Double
    let startDrift: Double

    var endTick: Int { spawnTick + lifetimeTicks }

    func isAlive(atTick tick: Int) -> Bool {
        spawnTick <= tick && tick <= endTick
    }

    /// Current strength, fading in and out like a puff's (`Puff.intensity`).
    func intensity(atTick tick: Int) -> Double {
        let x = (Double(tick - spawnTick) / Double(lifetimeTicks)).clamped(to: 0...1)
        return strength * sin(.pi * min(x, 1 - x))
    }
}

/// A pressure lane as it is at one tick.
struct PressureLane: Hashable, Sendable {
    /// Relative across-the-wind coordinate of its middle, metres.
    let centre: Double
    /// Its sideways drift, metres per second.
    let drift: Double
    let halfWidth: Double
    /// Current peak gain.
    let intensity: Double

    /// What the lane does at relative coordinate `r`. `speed`: `intensity · (1 − d²)²`, where d is the distance
    /// from its middle over its half-width. `fan`: its edge bend as a share of the peak turn, signed positive
    /// veering: `speed · d / Puff.fanShapePeak`, so the wind veers on its right-hand edge (looking downwind) and
    /// backs on its left, as a puff fans.
    func effect(at r: Double) -> (speed: Double, fan: Double) {
        let d = (r - centre) / halfWidth
        guard d > -1, d < 1 else { return (0, 0) }
        let f = 1 - d * d
        let speed = intensity * f * f
        return (speed, speed * d / Puff.fanShapePeak)
    }
}

/// The pressure field at one tick: its side's slope and the lanes alive, ready to apply at any point.
struct PressureState: Hashable, Sendable {
    let side: Double
    let lanes: [PressureLane]
}

extension WindField {
    /// The pressure field's state at `tick`: the pressure side's slope on its Hermite curve between knots, and every
    /// lane alive, in window and spawn order. Throws `missingKey` for the first key it needs and lacks: every key
    /// from `firstWindowNeeded(atTick:)` through `tick`'s window.
    func pressureState(atTick tick: Int, _ plan: PressurePlan) throws(WindFieldError) -> PressureState {
        let k = windows.window(containing: tick)
        guard k >= 0 else { throw .beforeOrigin(tick: tick) }
        for window in firstWindowNeeded(atTick: tick)...k where keys[window] == nil { throw .missingKey(window) }
        let fraction = Double(tick - windows.start(of: k)) / Double(WindWindows.ticksPerWindow)
        // Each target once, newest first: knot k reads the first `ramp + 1`, knot k − 1 the rest from the second.
        let ramp = PressurePlan.sideRampWindows
        let targets = (0...(ramp + 1)).map { sideTarget(k - $0, plan) }
        let side = Self.hermite(Self.sideKnot(targets[1...]), Self.sideKnot(targets[...]), fraction).value

        var lanes: [PressureLane] = []
        for window in max(0, k - plan.laneLookback)...k {
            for spawn in pressureDraws(ofWindow: window).lanes where spawn.isAlive(atTick: tick) {
                let knots = laneKnots(spawn, k, plan)
                let position = Self.hermite(knots.from, knots.to, fraction)
                lanes.append(PressureLane(centre: position.value, drift: position.slope, halfWidth: spawn.halfWidth,
                                          intensity: spawn.intensity(atTick: tick)))
            }
        }
        return PressureState(side: side, lanes: lanes)
    }

    /// The pressure side's target for window `j`: the most recent setter's draw in the `sideLookback` windows up to
    /// it, or 0 with none (or before the first window). Reads held keys only.
    func sideTarget(_ j: Int, _ plan: PressurePlan) -> Double {
        var window = j
        while window >= max(0, j - plan.sideLookback + 1) {
            if let side = pressureDraws(ofWindow: window).side { return side }
            window -= 1
        }
        return 0
    }

    /// The pressure side's knot ending window `j`: the mean of the last `sideRampWindows` targets, and its change
    /// from the knot before, per second.
    func sideKnot(_ j: Int, _ plan: PressurePlan) -> WindKnot {
        Self.sideKnot((0...PressurePlan.sideRampWindows).map { sideTarget(j - $0, plan) }[...])
    }

    /// The knot from targets newest first, its own window's at the start: at least `sideRampWindows + 1` of them.
    static func sideKnot(_ targets: ArraySlice<Double>) -> WindKnot {
        let ramp = PressurePlan.sideRampWindows
        let first = targets.startIndex
        var total = 0.0
        for i in 0..<ramp { total += targets[first + i] }
        let value = total / Double(ramp)
        var earlier = 0.0
        for i in 1...ramp { earlier += targets[first + i] }
        let before = earlier / Double(ramp)
        return WindKnot(value: value, slope: (value - before) / WindWindows.seconds)
    }

    /// Lane `spawn`'s position and drift at the knot ending window `j` (`j` from the one before its own window):
    /// from its start, each later key's drift, and the position moved by the mean of the drifts either side.
    func laneKnot(_ spawn: PressureLaneSpawn, _ j: Int, _ plan: PressurePlan) -> WindKnot {
        laneKnots(spawn, j, plan).to
    }

    /// Lane `spawn`'s knots ending windows `k − 1` and `k`, in one pass: `laneKnot` of each.
    func laneKnots(_ spawn: PressureLaneSpawn, _ k: Int, _ plan: PressurePlan) -> (from: WindKnot, to: WindKnot) {
        var position = spawn.start, drift = spawn.startDrift
        var from = WindKnot(value: position, slope: drift)
        var window = spawn.window
        while window <= k {
            guard let key = keys[window] else { break }
            let next = plan.drift(of: spawn, key: key)
            position += WindWindows.seconds * (drift + next) / 2
            drift = next
            if window == k - 1 { from = WindKnot(value: position, slope: drift) }
            window += 1
        }
        return (from, WindKnot(value: position, slope: drift))
    }
}
