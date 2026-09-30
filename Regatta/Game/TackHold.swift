import RegattaCore

/// The Tack/Gybe button is hold and release (#222): pressing it sends the tap that starts the tack or gybe, and
/// letting go after a hold is the roll, a second tap the sim times against the boom crossing (#263). A quick tap is a
/// plain tack, so rolling is always the player's choice. The client decides only whether to send the roll, from its
/// view of the boat; it adds no timing of its own. Times are wall-clock seconds.
nonisolated struct TackHold {
    /// A release this long after the press or later is a roll; sooner, a plain tack.
    static let rollHoldSeconds = 0.3

    /// When the press that sent a tap happened; nil while the button isn't held or its press was ignored.
    private var pressedAt: Double?

    /// The button goes down at `time`. Returns whether to send the tap: not while the boat is already in a tack or
    /// gybe (`inManoeuvre`), where a tap would be read as a roll or a gybe's second tap.
    mutating func press(at time: Double, inManoeuvre: Bool) -> Bool {
        guard !inManoeuvre else {
            pressedAt = nil
            return false
        }
        pressedAt = time
        return true
    }

    /// The press's tap was refused (e.g. a bot sails your seat under `-demo`): its release sends nothing.
    mutating func pressRefused() {
        pressedAt = nil
    }

    /// The button comes up at `time`. Returns whether to send the roll: held at least `rollHoldSeconds`, and the
    /// boat still in the tack the press began (`inTack`: a gybe has no roll, and a tack already over would read
    /// the tap as a new one).
    mutating func release(at time: Double, inTack: Bool) -> Bool {
        defer { pressedAt = nil }
        guard let pressedAt else { return false }
        return time - pressedAt >= Self.rollHoldSeconds && inTack
    }

    /// Whether `boat` is in a tack a roll tap can roll: the sim's own test (`Race.isInTack`, #263).
    static func isInTack(_ boat: Boat) -> Bool {
        if boat.isTacking { return true }
        guard let helm = boat.autohelm, helm.isTapping else { return false }
        return !helm.target.isDownwind
    }

    /// Whether `boat` is in a tack or a gybe: through head to wind, or her autohelm sailing a tap's turn.
    static func isInManoeuvre(_ boat: Boat) -> Bool {
        boat.isTacking || boat.autohelm?.isTapping == true
    }
}
