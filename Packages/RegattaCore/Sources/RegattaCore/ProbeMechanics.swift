import Foundation

/// Probe-only tack and gybe mechanics for the #456 sweep (#465). Never merged: #458 reimplements
/// whichever of these the sweep keeps. Every field's default is the off value, and with all of them
/// off `BoatDynamics.advance` is the stock function.
public struct ProbeMechanics: Sendable, Equatable {
    /// M1. Speed loss uses `abs(rudder)` to this power. 1 is today's linear drag.
    public var dragExponent = 1.0
    /// M1. Extra drag coefficient on `(turn rate / top turn rate)²`. 0 is off.
    public var dragTurnRateTerm = 0.0
    /// M1. Extra drag, as a multiple of rudder drag, per degree the heading is past the new groove
    /// while the rudder is still held. 0 is off.
    public var overshootCost = 0.0
    /// M2. Half-width of the head-to-wind band, radians of sailing angle. 0 is off.
    public var windBandRadians = 0.0
    /// M2. Turn rate multiplier inside the band. 1 is off.
    public var windBandRateFactor = 1.0
    /// M3. Half-width of the exit-settle band around the new groove, radians. 0 is off.
    public var settleRadians = 0.0
    /// M3. Speeding-up time constant is multiplied by `1 - settleBonus` inside the settle band
    /// with the rudder nearly centred. 0 is off.
    public var settleBonus = 0.0
    /// M3. Speeding up is suspended this long once the rudder is still held past the groove. 0 is off.
    public var driveLagSeconds = 0.0
    /// M4. The off-plane target blends in over this many seconds instead of stepping. 0 is off.
    public var dePlaneRampSeconds = 0.0
    /// M4. By-the-lee loss uses degrees to this power, scaled to match today's loss at 10°. 1 is off.
    public var byTheLeeExponent = 1.0
    /// Degrees the heading is past the aim, in the turn's direction. The harness sets this each tick.
    public var degreesPastGroove = 0.0
    /// Absolute heading error from the aim, radians. The harness sets this each tick.
    public var aimErrorRadians = Double.pi

    public init() {}

    public var isOff: Bool {
        dragExponent == 1 && dragTurnRateTerm == 0 && overshootCost == 0
            && windBandRadians == 0 && windBandRateFactor == 1
            && settleRadians == 0 && settleBonus == 0 && driveLagSeconds == 0
            && dePlaneRampSeconds == 0 && byTheLeeExponent == 1
    }
}

/// Per-boat probe clocks. Stock dynamics do not read them.
public struct ProbeClock: Sendable, Equatable {
    public var offPlaneSeconds = 0.0
    public var driveLagRemaining = 0.0

    public init() {}
}

/// The harness's probe state for the race on this thread. `Race` reads it while integrating; a nil
/// slot leaves every boat on the stock dynamics.
public final class ProbeSession: @unchecked Sendable {
    public var mechanics: ProbeMechanics
    private var clocks: [ProbeClock] = []

    public init(mechanics: ProbeMechanics = ProbeMechanics()) {
        self.mechanics = mechanics
    }

    public func clock(for seat: Int) -> ProbeClock {
        while clocks.count <= seat { clocks.append(ProbeClock()) }
        return clocks[seat]
    }

    public func setClock(_ clock: ProbeClock, for seat: Int) {
        while clocks.count <= seat { clocks.append(ProbeClock()) }
        clocks[seat] = clock
    }

    public func resetClocks() { clocks.removeAll(keepingCapacity: true) }
}

public enum ProbeSlot {
    private static let key = "regatta.probe.session"

    public static var current: ProbeSession? {
        get { Thread.current.threadDictionary[key] as? ProbeSession }
        set {
            if let newValue {
                Thread.current.threadDictionary[key] = newValue
            } else {
                Thread.current.threadDictionary.removeObject(forKey: key)
            }
        }
    }
}
