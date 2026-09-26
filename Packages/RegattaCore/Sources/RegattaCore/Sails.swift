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
    public func isPlaning(was: Bool, twa: Double, speed: Double, tws: Double) -> Bool {
        if was { return twa >= offBelowTWA && speed >= offSpeed }
        guard twa >= fromTWA && speed >= onSpeed else { return false }
        return Self.apparentWindCosine(twa: twa, speed: speed, tws: tws) >= cos(onMaxAWA)
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
