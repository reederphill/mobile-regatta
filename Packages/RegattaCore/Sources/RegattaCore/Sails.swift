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

    /// PROTOTYPE (#485): how far a planing boat is above the nearer of the two edges of `isPlaning(was:twa:speed:tws:rudder:polar:)`,
    /// 0...1: 1 comfortably on the plane, 0 at the edge, and 0 when she is not planing. A pure read of the rule: no
    /// state, nothing in the digest. A class without the rule (neither `stayOnSpeedShare` nor `apparentWind`): 1 while
    /// she planes.
    ///
    /// - The speed edge, counted only where the rule tests it (the apparent wind aft of `onMaxAWA`): her speed as a
    ///   share of the polar's at her angle and wind, from `stayOnSpeedShare` (0) up to `fullSpeedShare` (1).
    /// - The apparent wind edge: her apparent wind speed from the floor (`ApparentWind.offSpeed(tws:)`, taper and
    ///   all; 0) up to `apparentRange` m/s over it (1). Read whatever the rudder: the rule lets her off this edge
    ///   only with the rudder near centre, but the wind in her sails is as thin with it over.
    public func planeMargin(isPlaning: Bool, twa: Double, speed: Double, tws: Double, polar: PolarTable,
                            fullSpeedShare: Double = 1.0, apparentRange: Double = metresPerSecond(knots: 3)) -> Double {
        guard isPlaning else { return 0 }
        var margin = 1.0
        if let stayOnSpeedShare, Self.apparentWindCosine(twa: twa, speed: speed, tws: tws) < cos(onMaxAWA) {
            let polarSpeed = polar.speed(twa: twa, tws: tws)
            let share = polarSpeed > 0 ? speed / polarSpeed : 1
            let range = fullSpeedShare - stayOnSpeedShare
            margin = min(margin, range > 0 ? (share - stayOnSpeedShare) / range : (share >= stayOnSpeedShare ? 1 : 0))
        }
        if let apparentWind {
            let over = Self.apparentWindSpeed(twa: twa, speed: speed, tws: tws) - apparentWind.offSpeed(tws: tws)
            margin = min(margin, apparentRange > 0 ? over / apparentRange : (over >= 0 ? 1 : 0))
        }
        return min(max(margin, 0), 1)
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
