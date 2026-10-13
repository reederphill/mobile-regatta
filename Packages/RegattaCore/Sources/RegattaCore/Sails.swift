import Foundation

/// A boat's automatic spinnaker (#248): down, going up, up, or coming down. Only a class with a
/// spinnaker (`BoatClass.spinnaker`, schema 3) ever leaves `down`; `BoatDynamics.advance` moves it.
///
/// It goes up when she bears away past the class's `hoistAboveTWA` and comes down when she heads up
/// forward of `dropBelowTWA`. The angles overlap, so nothing in between changes it: no flicker. A hoist
/// or a drop takes the class's `transitionTime`, and a turn back past the other angle reverses it
/// mid-way, taking as long to undo as it had run. Until it is up and drawing she sails at two-sail speed.
public enum Spinnaker: Sendable, Equatable {
    case down
    /// Going up: up in `remaining` seconds.
    case hoisting(remaining: Double)
    case up
    /// Coming down: down in `remaining` seconds.
    case dropping(remaining: Double)

    /// Seconds left of a hoist or a drop, or nil when it is up or down.
    public var remaining: Double? {
        switch self {
        case .hoisting(let remaining), .dropping(let remaining): remaining
        case .down, .up: nil
        }
    }

    /// Whether it is fully up (drawing unless it has collapsed by the lee, `Boat.isSpinnakerCollapsed(in:)`).
    public var isUp: Bool { self == .up }

    /// The spinnaker `dt` seconds on, with her sailing at `twa` (radians, 0...π) with `tuning`.
    public func next(twa: Double, dt: Double, tuning: BoatClass.SpinnakerTuning) -> Spinnaker {
        switch self {
        case .down:
            return twa > tuning.hoistAboveTWA ? .hoisting(remaining: tuning.transitionTime) : .down
        case .up:
            return twa < tuning.dropBelowTWA ? .dropping(remaining: tuning.transitionTime) : .up
        case .hoisting(let remaining):
            // Headed up mid-hoist: it comes down again, taking as long as it has been going up.
            if twa < tuning.dropBelowTWA { return Self.dropping(tuning.transitionTime - remaining) }
            return Self.hoisting(remaining - dt)
        case .dropping(let remaining):
            if twa > tuning.hoistAboveTWA { return Self.hoisting(tuning.transitionTime - remaining) }
            return Self.dropping(remaining - dt)
        }
    }

    /// Within this of done, a hoist or drop is done: `dt` steps don't add up to a whole transition exactly.
    static let doneTolerance = 1e-9

    private static func hoisting(_ remaining: Double) -> Spinnaker {
        remaining <= doneTolerance ? .up : .hoisting(remaining: remaining)
    }

    private static func dropping(_ remaining: Double) -> Spinnaker {
        remaining <= doneTolerance ? .down : .dropping(remaining: remaining)
    }
}

extension BoatClass.PlaningTuning {
    /// Whether a boat planes after this tick (#248), from whether she was, her true wind angle `twa`
    /// (radians, 0...π), her speed through the water `speed` and the true wind speed `tws` her sails see
    /// (m/s, after any shadow).
    ///
    /// On the plane she stays on it until she slows below `offSpeed` or heads up forward of `offBelowTWA`.
    /// Off it she gets on only from `fromTWA` aft, at `onSpeed` or more, with the apparent wind no further
    /// aft than `onMaxAWA`: the sails fed from forward. Deep downwind off the plane the apparent wind is
    /// aft of that, so she has to head up to get going (#244 §4.4).
    ///
    /// This is the whole rule of a class without `stayOnSpeedShare` and `apparentWind` (every class before
    /// skiff@9), and the first part of `isPlaning(was:twa:speed:tws:rudder:polar:)` for one with them.
    public func isPlaning(was: Bool, twa: Double, speed: Double, tws: Double) -> Bool {
        if was { return twa >= offBelowTWA && speed >= offSpeed }
        guard twa >= fromTWA && speed >= onSpeed else { return false }
        return Self.apparentWindCosine(twa: twa, speed: speed, tws: tws) >= cos(onMaxAWA)
    }

    /// Whether a boat planes after this tick, as `isPlaning(was:twa:speed:tws:)`, with her `rudder` (−1...1) and
    /// her class's `polar`: what `BoatDynamics.advance` asks. A class with neither `stayOnSpeedShare` nor
    /// `apparentWind` gets that rule's answer, bit for bit. One with them (#462, skiff@9) has two more ways off
    /// the plane, and one more condition to get on it:
    ///
    /// - With the apparent wind aft of `onMaxAWA` she drops off below `stayOnSpeedShare` of the polar's speed at
    ///   her angle and wind: a slammed, cranked or lingering gybe comes out slow with the wind behind her.
    /// - With the rudder within `apparentWind.rudderWithin` of centre she drops off with the apparent wind under
    ///   `apparentWind.offSpeed`: sailed too deep, or in a lull, she outruns her wind.
    /// - Off the plane she gets on only with the apparent wind at `apparentWind.onSpeed` or more.
    /// - Both apparent wind speeds taper in very light wind, to `apparentWind.offWindShare` and `onWindShare` of `tws`
    ///   where that is less (`ApparentWind.offSpeed(tws:)`): from the wind at which the share reaches the fixed speed
    ///   up, nothing differs.
    ///
    /// The same at every wind strength. `was` is the only state: nothing is remembered between ticks.
    public func isPlaning(was: Bool, twa: Double, speed: Double, tws: Double, rudder: Double, polar: PolarTable) -> Bool {
        guard stayOnSpeedShare != nil || apparentWind != nil else {
            return isPlaning(was: was, twa: twa, speed: speed, tws: tws)
        }
        let apparentSpeed = Self.apparentWindSpeed(twa: twa, speed: speed, tws: tws)
        guard was else {
            guard twa >= fromTWA && speed >= onSpeed else { return false }
            if let apparentWind, apparentSpeed < apparentWind.onSpeed(tws: tws) { return false }
            return Self.apparentWindCosine(twa: twa, speed: speed, tws: tws) >= cos(onMaxAWA)
        }
        guard twa >= offBelowTWA && speed >= offSpeed else { return false }
        if let stayOnSpeedShare, Self.apparentWindCosine(twa: twa, speed: speed, tws: tws) < cos(onMaxAWA),
           speed < stayOnSpeedShare * polar.speed(twa: twa, tws: tws) {
            return false
        }
        if let apparentWind, apparentSpeed < apparentWind.offSpeed(tws: tws), abs(rudder) <= apparentWind.rudderWithin { return false }
        return true
    }

    /// What the plane margin (`planeMargin(isPlaning:twa:speed:tws:polar:ranges:)`) counts as comfortably on the plane
    /// (#492). Drawing's, not the rule's: nothing here is in a class file, and the sim never reads it.
    public struct MarginRanges: Sendable, Equatable {
        /// The share of the polar's (on-plane) speed at her angle and wind at which the speed edge reads 1; it reads 0
        /// at the class's `stayOnSpeedShare`. Under 1: a fleet on a breezy run sails 0.8 to 0.9 of its polar, and that
        /// is ordinary planing, not the edge.
        public var fullSpeedShare: Double
        /// The apparent wind over the class's floor (`ApparentWind.offSpeed(tws:)`), m/s, at which the wind edge reads
        /// 1; it reads 0 at the floor.
        public var apparentRange: Double
        /// The speed edge comes in over this much apparent wind angle forward of `onMaxAWA`, radians: none of it that
        /// far forward or more, all of it from `onMaxAWA` aft.
        public var angleBand: Double

        public init(fullSpeedShare: Double = 0.85, apparentRange: Double = metresPerSecond(knots: 3),
                    angleBand: Double = deg2rad(15)) {
            self.fullSpeedShare = fullSpeedShare
            self.apparentRange = apparentRange
            self.angleBand = angleBand
        }

        public static let standard = MarginRanges()
    }

    /// How far a planing boat is from falling off the plane (#492), 0...1: 1 comfortably on it, 0 at the edge, and 0
    /// off it. Read from the terms of `isPlaning(was:twa:speed:tws:rudder:polar:)`, with the same `twa`, `speed`, `tws`
    /// and `polar`; pure, and for drawing only: no boat keeps it, nothing of it is in the digest or on the wire, and the
    /// sim never asks. A class with neither `stayOnSpeedShare` nor `apparentWind`: 1 while she planes.
    ///
    /// The nearer of the rule's two edges:
    ///
    /// - The speed edge: her speed as a share of the polar's at her angle and wind, from `stayOnSpeedShare` (0) up to
    ///   `ranges.fullSpeedShare` (1). The rule asks it only with the apparent wind aft of `onMaxAWA`, so forward of that
    ///   she is as far from this edge as her apparent wind is from `onMaxAWA`, over `ranges.angleBand`, where that is
    ///   more: a slow boat bearing away loses her margin over the band, not at a stroke as her apparent wind crosses,
    ///   and with it forward by the band or more this edge reads 1 whatever her speed.
    /// - The apparent wind edge: her apparent wind speed from the floor (`ApparentWind.offSpeed(tws:)`, taper and all;
    ///   0) up to `ranges.apparentRange` over it (1).
    ///
    /// Where the rule drops her on either edge with the rudder centred, this is 0. Two things it leaves out on purpose:
    /// the rule's rudder gate (`ApparentWind.rudderWithin`: the wind in her sails is as thin with the rudder over), and
    /// the two older edges, `offSpeed` and `offBelowTWA`, so heading up forward of `offBelowTWA` drops her at whatever
    /// this read.
    public func planeMargin(isPlaning: Bool, twa: Double, speed: Double, tws: Double, polar: PolarTable,
                            ranges: MarginRanges = .standard) -> Double {
        guard isPlaning else { return 0 }
        var margin = 1.0
        if let stayOnSpeedShare {
            let polarSpeed = polar.speed(twa: twa, tws: tws)
            let share = polarSpeed > 0 ? speed / polarSpeed : 1
            let onSpeed = Self.share(share - stayOnSpeedShare, of: ranges.fullSpeedShare - stayOnSpeedShare)
            let apparentAngle = acos(Self.apparentWindCosine(twa: twa, speed: speed, tws: tws).clamped(to: -1...1))
            let forward = Self.share(onMaxAWA - apparentAngle, of: ranges.angleBand)
            margin = min(margin, max(onSpeed, forward))
        }
        if let apparentWind {
            let over = Self.apparentWindSpeed(twa: twa, speed: speed, tws: tws) - apparentWind.offSpeed(tws: tws)
            margin = min(margin, Self.share(over, of: ranges.apparentRange))
        }
        return margin
    }

    /// `amount` as a share of `range`, 0...1; with no range, 1 from nothing up and 0 below.
    private static func share(_ amount: Double, of range: Double) -> Double {
        range > 0 ? (amount / range).clamped(to: 0...1) : (amount >= 0 ? 1 : 0)
    }

    /// The apparent wind speed (m/s) of a boat sailing at `speed` (m/s) at `twa` (radians) to a true wind of `tws`
    /// (m/s): the true wind plus her own, over the bow.
    public static func apparentWindSpeed(twa: Double, speed: Double, tws: Double) -> Double {
        let ahead = tws * cos(twa) + speed
        let abeam = tws * sin(twa)
        return (ahead * ahead + abeam * abeam).squareRoot()
    }

    /// The cosine of the apparent wind angle of a boat sailing at `speed` (m/s) at `twa` (radians) to a
    /// true wind of `tws` (m/s): the true wind plus her own, over the bow. 1 in a flat calm.
    static func apparentWindCosine(twa: Double, speed: Double, tws: Double) -> Double {
        let ahead = tws * cos(twa) + speed
        let abeam = tws * sin(twa)
        let apparent = (ahead * ahead + abeam * abeam).squareRoot()
        return apparent > 0 ? ahead / apparent : 1
    }
}
