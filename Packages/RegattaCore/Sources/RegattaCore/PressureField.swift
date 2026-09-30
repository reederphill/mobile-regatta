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
///
/// With schema 6 conditions (`lanes.extent`) a lane is a finite patch, an ellipse along the wind that drifts down it
/// slowly, and some lanes weaken the wind rather than strengthen it: pressure then changes up the course as well as across
/// it. Without, a lane is an unending band as it was.
///
/// The venue's geography steers both (#287, ADR 0008), from its public file: its side tendency, scaled by a
/// multiplier window 0's key draws for the race, is added to every side target, so the side leans its way in most
/// races but not all; and a share of lanes (`lanes.spotShare`) forms at its lane spots instead of anywhere. A venue
/// with neither (every schema-1 file) draws nothing more, so its field is exactly #286's.
struct PressurePlan: Hashable, Sendable {
    /// Stream tags for `SplitMix64(seed:stream:)` on a key's `puffSeed`, distinct from `PuffPlan.seedStream`:
    /// ASCII "presside", "preslane" and "presdrft".
    static let sideStream: UInt64 = 0x7072_6573_7369_6465
    static let laneStream: UInt64 = 0x7072_6573_6C61_6E65
    static let driftStream: UInt64 = 0x7072_6573_6472_6674
    /// Stream tags for the venue's geography (#287): ASCII "prestend" (the race's side tendency multiplier, window 0
    /// only) and "presspot" (which lanes form at the venue's lane spots, and where).
    static let tendencyStream: UInt64 = 0x7072_6573_7465_6E64
    static let spotStream: UInt64 = 0x7072_6573_7370_6F74
    /// Stream tag for finite lanes (schema 6): ASCII "presalng", per lane its length, where along the course it is at
    /// mid-life, its drift down the wind and whether it weakens the wind.
    static let extentStream: UInt64 = 0x7072_6573_616C_6E67
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
    /// What makes lanes finite patches (schema 6), or nil for unending bands.
    let extent: Conditions.PressureField.Lanes.Extent?
    /// Up the course (the mean direction), and the race area's centre and half-length: the along-the-wind coordinate.
    let up: Vec2
    let areaCentre: Vec2
    let halfLength: Double
    /// Drift speed per unit of `extent.drift`: the race's base strength, as puffs'.
    let baseStrength: Double
    /// The venue pairing's side tendency (`Venue.Pairing.sideTendency`): 0 for none.
    let sideTendency: Double
    /// Where the venue's lane spots lie across the course, or nil with none.
    let laneSpots: LaneSpots?

    /// Whether the field reads window 0's key at every tick: for the race's side tendency multiplier.
    var readsFirstKey: Bool { sideTendency != 0 }

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
        extent = lanes.extent
        up = Vec2.heading(setup.meanDirection)
        areaCentre = area.centre
        halfLength = area.halfLength
        baseStrength = setup.baseStrength
        sideTendency = setup.pairing.sideTendency
        let reach = area.halfWidth + laneMargin
        laneSpots = LaneSpots(setup.pairing.geographicGrid, reach: reach) { [acrossWind, meanDirection, centre] p in
            acrossWind.coordinate(at: p, meanDirection: meanDirection) - centre
        }
    }

    /// The across-the-wind coordinate at `p`, from the race area's centre, metres.
    func coordinate(at p: Vec2) -> Double {
        acrossWind.coordinate(at: p, meanDirection: meanDirection) - centre
    }

    /// The along-the-wind coordinate at `p`: metres up the course from the race area's centre, a straight line
    /// along the mean direction. Only finite lanes read it.
    func along(at p: Vec2) -> Double {
        (p - areaCentre).dot(up)
    }

    /// Key `key.window`'s draws, from `SplitMix64(seed: key.puffSeed, stream:)` in a fixed order: for the pressure
    /// side (`sideStream`) the setter coin, the side and the size; for lanes (`laneStream`) the count, then per lane
    /// its spawn tick in the window, lifetime, width, strength, position across and first drift. New draws go after
    /// these, so existing ones never move. A finite lane (schema 6) draws four values more from `extentStream`, in a
    /// stream of their own so the lane draws above stay as they were: its length, its mid-life position along the
    /// course (uniform over the race area and half the longest length beyond each end), its drift and the weak coin.
    /// It forms upwind of that position by half its drift and moves down the wind, so it passes through the water
    /// it covers, as puffs do; a weak lane's strength is negative.
    ///
    /// Each lane forms inside its window, so none is felt before its window starts, and fades in from nothing (ADR
    /// 0001). Its centre forms uniform across the race area and `laneMargin` either side, or, at a venue with lane
    /// spots, with the chance `lanes.spotShare` at one of them instead (`spotStream`: per lane, the coin, the spot
    /// and where in it). Window 0's key at a venue with a side tendency also draws the race's multiplier on it
    /// (`tendencyStream`).
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
        var spotRNG = SplitMix64(seed: key.puffSeed, stream: Self.spotStream)
        var extentRNG = SplitMix64(seed: key.puffSeed, stream: Self.extentStream)
        for index in 0..<count {
            let offset = min(WindWindows.ticksPerWindow - 1, Int(laneRNG.unit() * Double(WindWindows.ticksPerWindow)))
            let lifetime = laneRNG.range(lanes.lifetime.lowerBound, lanes.lifetime.upperBound)
            let width = laneRNG.range(lanes.width.lowerBound, lanes.width.upperBound)
            let strength = laneRNG.range(lanes.strength.lowerBound, lanes.strength.upperBound)
            let across = laneRNG.unit()
            let drift = laneRNG.range(-lanes.drift, lanes.drift)
            var position = (2 * across - 1) * (halfWidth + laneMargin)
            if let laneSpots {
                let atSpot = spotRNG.unit() < lanes.spotShare
                let spot = spotRNG.unit(), within = spotRNG.unit()
                if atSpot { position = laneSpots.position(spot, within) }
            }
            let lifetimeTicks = min(maxLaneLifetimeTicks, PuffPlan.ticks(seconds: lifetime))
            var spawn = PressureLaneSpawn(
                window: key.window, index: index, spawnTick: start + offset, lifetimeTicks: lifetimeTicks,
                halfWidth: width / 2, strength: strength, start: position, startDrift: drift)
            if let extent {
                let length = extentRNG.range(extent.length.lowerBound, extent.length.upperBound)
                let mid = (2 * extentRNG.unit() - 1) * (halfLength + extent.length.upperBound / 2)
                let speed = extentRNG.range(extent.drift.lowerBound, extent.drift.upperBound)
                let isWeak = extentRNG.unit() < extent.weakShare
                let velocity = -speed * baseStrength
                spawn.halfLength = length / 2
                spawn.alongVelocity = velocity
                spawn.alongStart = mid - velocity * Double(lifetimeTicks) / Double(Race.tickRate) / 2
                if isWeak { spawn.strength = -strength }
            }
            spawns.append(spawn)
        }
        var tendency = 0.0
        if key.window == 0 && sideTendency != 0 {
            var tendencyRNG = SplitMix64(seed: key.puffSeed, stream: Self.tendencyStream)
            let scale = field.side.tendencyScale
            tendency = sideTendency * tendencyRNG.range(scale.lowerBound, scale.upperBound)
        }
        return PressureDraws(side: side, lanes: spawns, tendency: tendency)
    }

    /// The sideways drift key `key` draws for `lane` at the knot ending its window, metres per second: its own
    /// stream per lane, so a lane's drift never depends on which other lanes are alive.
    func drift(of lane: PressureLaneSpawn, key: WindKey) -> Double {
        let tag = Self.driftStream ^ (UInt64(bitPattern: Int64(lane.window)) &* 0x1_0000) ^ UInt64(lane.index)
        var rng = SplitMix64(seed: key.puffSeed, stream: tag)
        return rng.range(-field.lanes.drift, field.lanes.drift)
    }

    /// The field's pressure and bend at `p`: `effect(at:along:side:lanes:)` at its two coordinates.
    func effect(at p: Vec2, side: Double, lanes: [PressureLane]) -> (factor: Double, turn: Double) {
        effect(at: coordinate(at: p), along: extent == nil ? 0 : along(at: p), side: side, lanes: lanes)
    }

    /// The field's pressure and bend at relative coordinate `r` (`coordinate(at:)`) and `a` up the course
    /// (`along(at:)`, which only finite lanes read), given the pressure side's slope `side` and the lanes alive,
    /// summed in their order. The factor is kept to 0.5…2, so no overlap stops or doubles the wind; the lanes' bend is
    /// capped at `lanes.bend`.
    func effect(at r: Double, along a: Double = 0, side: Double, lanes: [PressureLane]) -> (factor: Double, turn: Double) {
        let sidePressure = side * (r / halfWidth).clamped(to: -1...1)
        let sideTurn = field.side.strength > 0 ? field.side.bend * sidePressure / field.side.strength : 0
        var gain = 0.0, fan = 0.0
        for lane in lanes {
            let effect = lane.effect(at: r, along: a)
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
    /// Window 0's only: the venue's side tendency as this race has it, the authored tendency times the race's
    /// multiplier, added to every side target (#287). 0 for any other window, or with no tendency.
    var tendency = 0.0

    static let none = PressureDraws(side: nil, lanes: [])
}

/// Where a venue's lane spots lie across the course (#287): each grid node that prefers lanes, at its across-the-wind
/// coordinate relative to the race area's centre, weighted by its preference. A lane is a band along the wind, so a
/// spot anywhere up or down the course draws it to the same place across. Only nodes a lane may form at count.
struct LaneSpots: Hashable, Sendable {
    /// Relative coordinates of the preferring nodes, metres, and their running total of preference.
    let positions: [Double]
    let cumulative: [Double]
    /// A lane forms up to half a cell either side of its node, so spots read as the smooth grid they are.
    let spread: Double

    /// Nil when no node within `reach` of the centre, across, prefers lanes.
    init?(_ geographic: Venue.GeographicGrid, reach: Double, coordinate: (Vec2) -> Double) {
        guard geographic.hasLaneSpots else { return nil }
        let grid = geographic.grid
        var positions: [Double] = [], cumulative: [Double] = []
        var total = 0.0
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let preference = geographic.lanePreference(column: column, row: row)
                guard preference > 0 else { continue }
                let r = coordinate(grid.position(column: column, row: row))
                guard abs(r) <= reach else { continue }
                total += preference
                positions.append(r)
                cumulative.append(total)
            }
        }
        guard total > 0 else { return nil }
        self.positions = positions
        self.cumulative = cumulative
        spread = grid.cellSize / 2
    }

    /// The position a lane forms at for draws `spot` (which node, by preference) and `within` (where around it),
    /// each in [0, 1).
    func position(_ spot: Double, _ within: Double) -> Double {
        let target = spot * cumulative[cumulative.count - 1]
        var low = 0, high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] > target { high = mid } else { low = mid + 1 }
        }
        return positions[low] + (2 * within - 1) * spread
    }
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
    /// Peak gain down its middle, as a fraction of wind speed; negative for a weak lane (schema 6).
    var strength: Double
    /// Relative coordinate of its middle at the start of its window, and its drift there, metres per second.
    let start: Double
    let startDrift: Double
    /// A finite lane's (schema 6) half-length along the wind, nil for an unending band; its position up the course at
    /// `spawnTick`, and its speed along it, metres per second, negative down the wind.
    var halfLength: Double?
    var alongStart = 0.0
    var alongVelocity = 0.0

    var endTick: Int { spawnTick + lifetimeTicks }

    func isAlive(atTick tick: Int) -> Bool {
        spawnTick <= tick && tick <= endTick
    }

    /// Where its middle is up the course at `tick`, metres from the race area's centre: only meaningful for a finite lane.
    func alongCentre(atTick tick: Int) -> Double {
        alongStart + alongVelocity * Double(tick - spawnTick) / Double(Race.tickRate)
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
    /// Current peak gain, negative for a weak lane.
    let intensity: Double
    /// A finite lane's middle up the course, and its half-length; nil half-length for an unending band.
    var alongCentre = 0.0
    var halfLength: Double?

    /// What the lane does at relative coordinate `r`, and `a` up the course. `speed`: `intensity · (1 − d²)²`, where d
    /// is the distance from its middle over its half-width; for a finite lane `(1 − d² − e²)²`, where e is the distance
    /// from its middle up the course over its half-length, so its footprint is an ellipse. `fan`: its edge bend as a
    /// share of the peak turn, signed positive veering: `speed · d / Puff.fanShapePeak`, so the wind veers on its
    /// right-hand edge (looking downwind) and backs on its left, as a puff fans; a weak lane draws in, the other way.
    func effect(at r: Double, along a: Double = 0) -> (speed: Double, fan: Double) {
        let d = (r - centre) / halfWidth
        guard d > -1, d < 1 else { return (0, 0) }
        var f = 1 - d * d
        if let halfLength {
            let e = (a - alongCentre) / halfLength
            f -= e * e
            guard f > 0 else { return (0, 0) }
        }
        let speed = intensity * f * f
        return (speed, speed * d / Puff.fanShapePeak)
    }
}

/// What `WindField` caches per window so `pressureState` only blends knots (#288): the window's pressure side target
/// from the keys' own draws (`keyedSideTarget`, before the race's tendency), and the knots of each lane its key
/// spawns (`laneKnotList`), in draw order.
struct PressureKnots: Hashable, Sendable {
    var sideTarget = 0.0
    var lanes: [[WindKnot]] = []

    static let none = PressureKnots()
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
        return heldPressureState(atTick: tick, plan)
    }

    /// `pressureState(atTick:_:)` from the keys held, never throwing: a window whose key isn't held draws nothing,
    /// as `sideTarget` and `laneKnots` read it. Where puffs form (#288): their window's key has just been added,
    /// so its spawn ticks' state is the one sampling will see once the keys before it are all held.
    func heldPressureState(atTick tick: Int, _ plan: PressurePlan) -> PressureState {
        let k = windows.window(containing: tick)
        let fraction = Double(tick - windows.start(of: k)) / Double(WindWindows.ticksPerWindow)
        // Each target once, newest first: knot k reads the first `ramp + 1`, knot k − 1 the rest from the second. The
        // cache holds each window's target from the keys' own draws; the race's tendency goes on as `sideTarget` adds it.
        let ramp = PressurePlan.sideRampWindows
        let tendency = plan.readsFirstKey ? pressureDraws(ofWindow: 0).tendency : nil
        let targets = (0...(ramp + 1)).map { i in
            let keyed = k - i >= 0 ? pressureKnots[k - i].sideTarget : 0
            return tendency.map { keyed + $0 } ?? keyed
        }
        let side = Self.hermite(Self.sideKnot(targets[1...]), Self.sideKnot(targets[...]), fraction).value

        var lanes: [PressureLane] = []
        for window in max(0, k - plan.laneLookback)...k {
            let knotLists = pressureKnots[window].lanes
            for (spawn, list) in zip(pressureDraws(ofWindow: window).lanes, knotLists) where spawn.isAlive(atTick: tick) {
                let knots = Self.laneKnots(list, spawn, k)
                let position = Self.hermite(knots.from, knots.to, fraction)
                lanes.append(PressureLane(centre: position.value, drift: position.slope, halfWidth: spawn.halfWidth,
                                          intensity: spawn.intensity(atTick: tick),
                                          alongCentre: spawn.halfLength == nil ? 0 : spawn.alongCentre(atTick: tick),
                                          halfLength: spawn.halfLength))
            }
        }
        return PressureState(side: side, lanes: lanes)
    }

    /// The pressure side's target for window `j`: the most recent setter's draw in the `sideLookback` windows up to
    /// it, or 0 with none (or before the first window), plus the race's side tendency (`PressureDraws.tendency`,
    /// from window 0's key) at a venue with one. Reads held keys only.
    func sideTarget(_ j: Int, _ plan: PressurePlan) -> Double {
        let keyed = keyedSideTarget(j, plan)
        return plan.readsFirstKey ? keyed + pressureDraws(ofWindow: 0).tendency : keyed
    }

    /// The side target from the windows' own draws alone: #286's. What `pressureKnots` caches per window.
    func keyedSideTarget(_ j: Int, _ plan: PressurePlan) -> Double {
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

    /// Lane `spawn`'s knots as `laneKnots` replays them, for the cache: its start, then the knot ending each window
    /// from its own through the last it may be alive in (`laneLookback` after it), stopping at the first key not held.
    func laneKnotList(_ spawn: PressureLaneSpawn, _ plan: PressurePlan) -> [WindKnot] {
        var position = spawn.start, drift = spawn.startDrift
        var knots = [WindKnot(value: position, slope: drift)]
        for window in spawn.window...(spawn.window + plan.laneLookback) {
            guard let key = keys[window] else { break }
            let next = plan.drift(of: spawn, key: key)
            position += WindWindows.seconds * (drift + next) / 2
            drift = next
            knots.append(WindKnot(value: position, slope: drift))
        }
        return knots
    }

    /// `laneKnots(spawn, k, _)` from the cached `list` (`laneKnotList`), bit for bit.
    static func laneKnots(_ list: [WindKnot], _ spawn: PressureLaneSpawn, _ k: Int) -> (from: WindKnot, to: WindKnot) {
        let i = k - spawn.window
        return (i < list.count ? list[i] : list[0], list[min(i + 1, list.count - 1)])
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

// MARK: - Reading the pressure (#290)

/// The pressure at a place (CONTEXT.md, "Pressure"): the wind there before any puff or lull, as the venue's
/// geography and the pressure field make it. What the water and the minimap tone (ADR 0008), and what a bot reads of
/// them (`SeatView.PressureMap`).
public struct Pressure: Sendable, Hashable {
    /// The wind's speed as a factor of the course average (`WindField.courseAverageSpeed(atTick:)`).
    public let factor: Double
    /// How far the wind is turned from the course's direction now, radians, positive veering: the geography's bend
    /// plus the pressure side's and the lanes' edges'.
    public let turn: Double

    public init(factor: Double, turn: Double) {
        self.factor = factor
        self.turn = turn
    }

    /// The pressure at `p`: `WindField.sample(_:tick:)`'s geography and pressure field terms, without its puffs.
    static func at(_ p: Vec2, _ geographicGrid: Venue.GeographicGrid,
                   _ field: (plan: PressurePlan, state: PressureState)?) -> Pressure {
        let geographic = geographicGrid.sample(p)
        guard let (plan, state) = field else { return Pressure(factor: geographic.speedFactor, turn: geographic.directionDelta) }
        let pressure = plan.effect(at: p, side: state.side, lanes: state.lanes)
        return Pressure(factor: geographic.speedFactor * pressure.factor, turn: geographic.directionDelta + pressure.turn)
    }
}

extension WindField {
    /// The pressure anywhere at `tick` (`Pressure`): the tick's pressure state worked out once, to read at many
    /// places. Throws what `sample(_:tick:)` would.
    func pressure(atTick tick: Int) throws(WindFieldError) -> (Vec2) -> Pressure {
        let field = try pressurePlan.map { plan throws(WindFieldError) in (plan, try pressureState(atTick: tick, plan)) }
        let grid = setup.pairing.geographicGrid
        return { Pressure.at($0, grid, field) }
    }
}

extension WindSampler {
    /// The pressure at `p` (`Pressure`): this tick's wind there without its puffs, as a factor of the course average
    /// and a turn from the course's direction.
    public func pressure(at p: Vec2) -> Pressure {
        Pressure.at(p, geographicGrid, pressure)
    }
}
