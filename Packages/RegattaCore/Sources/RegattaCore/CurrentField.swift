import Foundation

/// The water's own motion over a venue at any point and race tick (#78, ADR 0003): a pure function of
/// the venue's current, the tide state at the gun, the race clock and the position. No randomness, no
/// state, fully known before the gun, so every player can see it as a `TideForecast`.
///
/// Implements the formula in docs/venue-file.md ("The current field"): a channel current along each
/// node's fixed flood direction, scaled by depth and by the sine of the local tide phase (so it reverses,
/// never rotates, and the shallows turn first), plus Rankine headland eddies that flip to their other
/// centre when the tide turns there. Nothing bounds the sum: the channel term alone stays within the
/// venue's peak, and an eddy adds to it.
public struct CurrentField: Sendable, Equatable {
    /// Stream tag for `SplitMix64(seed:stream:)`: ASCII "tidestat".
    public static let seedStream: UInt64 = 0x7469_6465_7374_6174

    /// The venue's current, or nil for a venue without one: then the field is zero everywhere, always.
    public let current: Venue.Current?
    /// Tide phase at the gun (tick 0), radians: 0 slack before the flood, π/2 peak flood, π slack
    /// before the ebb, 3π/2 peak ebb (`Venue.Current`). Ignored without a current.
    public let tideStateAtGun: Double

    public init(current: Venue.Current?, tideStateAtGun: Double) {
        self.current = current
        self.tideStateAtGun = tideStateAtGun
    }

    public init(venue: Venue, tideStateAtGun: Double) {
        self.init(current: venue.current, tideStateAtGun: tideStateAtGun)
    }

    /// The field for a race: the tide state at the gun drawn from its public race seed
    /// (`tideStateAtGun(for:raceSeed:)`), or zero for a venue without current.
    public init(venue: Venue, raceSeed: RaceSeed) {
        self.init(current: venue.current, tideStateAtGun: Self.tideStateAtGun(for: venue, raceSeed: raceSeed) ?? 0)
    }

    /// The race's tide state at the gun, radians in [0, 2π): uniform over the venue's
    /// `allowedTideStatesAtGun` (wrapping through 0; the whole cycle means any), or nil for a venue
    /// without current. Practice has no tide choice (#25): every race draws it.
    ///
    /// Drawn from the race seed on its own stream, `SplitMix64(seed: raceSeed.value, stream: seedStream)`,
    /// first value, so it never moves any other race-seed draw. A pure function of the logged race seed
    /// and venue; the race log records it (`RaceLog.Header.tideStateAtGun`).
    public static func tideStateAtGun(for venue: Venue, raceSeed: RaceSeed) -> Double? {
        guard let range = venue.current?.allowedTideStatesAtGun else { return nil }
        var rng = SplitMix64(seed: raceSeed.value, stream: seedStream)
        let phase = range.from + rng.range(0, range.width)
        let turns = 2 * Double.pi
        let wrapped = phase >= turns ? phase - turns : phase
        return wrapped < turns ? wrapped : 0
    }

    /// Radians of tide phase per race second: 2π × `tideClockRate` / `tidalCycle`; 0 without current.
    public var phaseRate: Double {
        guard let current else { return 0 }
        return 2 * .pi * current.tideClockRate / Venue.Current.tidalCycle
    }

    /// Tide phase at the deepest water at race tick `tick` (negative before the gun), radians, unwrapped:
    /// φ(t) = tideStateAtGun + phaseRate × t.
    public func tideState(atTick tick: Int) -> Double {
        tideStateAtGun + phaseRate * Self.seconds(tick)
    }

    /// Current at `p` at race tick `tick`, m/s (a velocity: the way the water moves): `channel` plus
    /// `eddies`. Zero everywhere for a venue without current.
    public func sample(_ p: Vec2, tick: Int) -> Vec2 {
        channel(p, tick: tick) + eddies(p, tick: tick)
    }

    /// The channel term alone, m/s: `peak × relativeStrength(d) × sin(local phase) × heading(flood)`.
    /// Its size never exceeds the venue's peak; it is zero on dry water and beyond the outer nodes.
    public func channel(_ p: Vec2, tick: Int) -> Vec2 {
        guard let current, let water = water(at: p), water.depth > 0 else { return .zero }
        let phase = tideState(atTick: tick) + current.phaseLead(depth: water.depth)
        return current.peak * current.relativeStrength(depth: water.depth) * sin(phase) * water.flood
    }

    /// The eddies' term alone, m/s: each eddy's flood centre while the tide floods there and its ebb
    /// centre while it ebbs there, each a tapered Rankine vortex (`Venue.Eddy.relativeSpeed`).
    public func eddies(_ p: Vec2, tick: Int) -> Vec2 {
        guard let current else { return .zero }
        let phase = tideState(atTick: tick)
        var sum = Vec2.zero
        for eddy in current.eddies {
            let flood = eddy.peak * max(0, sin(phase + current.phaseLead(depth: depth(at: eddy.floodCentre))))
            let ebb = eddy.peak * max(0, -sin(phase + current.phaseLead(depth: depth(at: eddy.ebbCentre))))
            sum += flood * Self.vortex(eddy, centre: eddy.floodCentre, rotation: eddy.floodRotation, at: p)
            sum += ebb * Self.vortex(eddy, centre: eddy.ebbCentre, rotation: eddy.ebbRotation, at: p)
        }
        return sum
    }

    /// Local tide phase at `p` (with the shallows lead at the depth there) at race tick `tick`, radians,
    /// unwrapped. Beyond the outer nodes the depth counts as 0 (`depth(at:)`).
    public func localPhase(at p: Vec2, tick: Int) -> Double {
        guard let current else { return tideStateAtGun }
        return tideState(atTick: tick) + current.phaseLead(depth: depth(at: p))
    }

    /// Water depth at `p`, metres: bilinear between the four nodes around it, 0 beyond the outer nodes
    /// or without current.
    public func depth(at p: Vec2) -> Double {
        guard let current, let cell = current.grid.cell(containing: p) else { return 0 }
        return current.grid.bilinear(current.depths, at: cell)
    }

    /// Unit vector the flood flows towards at `p`, or nil beyond the outer nodes or without current:
    /// the bilinear of the four nodes' unit flood vectors, normalised, or the nearest node's where
    /// they cancel.
    public func floodDirection(at p: Vec2) -> Vec2? {
        water(at: p)?.flood
    }

    private func water(at p: Vec2) -> (depth: Double, flood: Vec2)? {
        guard let current, let cell = current.grid.cell(containing: p) else { return nil }
        let (c, r, u, v) = (cell.column, cell.row, cell.columnFraction, cell.rowFraction)
        func node(_ dc: Int, _ dr: Int) -> Vec2 { .heading(current.floodDirection(column: c + dc, row: r + dr)) }
        var flood = (node(0, 0) * (1 - u) + node(1, 0) * u) * (1 - v) + (node(0, 1) * (1 - u) + node(1, 1) * u) * v
        if flood.length > 1e-9 {
            flood = flood.normalized
        } else {
            let column = cell.column + Int(cell.columnFraction.rounded())
            let row = cell.row + Int(cell.rowFraction.rounded())
            flood = .heading(current.floodDirection(column: column, row: row))
        }
        return (current.grid.bilinear(current.depths, at: cell), flood)
    }

    /// Unit-speed-at-core-radius velocity of a vortex about `centre` turning `rotation`, at `p`.
    private static func vortex(_ eddy: Venue.Eddy, centre: Vec2, rotation: Venue.Eddy.Rotation, at p: Vec2) -> Vec2 {
        let offset = p - centre
        let f = eddy.relativeSpeed(atDistance: offset.length)
        guard f > 0 else { return .zero }
        let clockwise = offset.rightPerp.normalized
        return f * (rotation == .clockwise ? clockwise : -clockwise)
    }

    static func seconds(_ tick: Int) -> Double { Double(tick) / Double(Race.tickRate) }
}
