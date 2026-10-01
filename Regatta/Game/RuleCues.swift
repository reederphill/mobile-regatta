import Foundation
import RegattaCore

/// Your owed penalty as the penalty arc and the Turn notice show it (#123, #15): until the turn is started the arc
/// counts down the start deadline, then the complete deadline, each a share of its own window. The windows are the
/// rules' (`raceFormat.penalty`), never literals; the seconds come from the race tick, not the wall clock.
nonisolated struct PenaltyReadout: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Owed, not yet started: the arc counts the start deadline.
        case start
        /// Started: the arc counts the complete deadline.
        case complete
    }

    let phase: Phase
    /// What's left of the current deadline's window, 0 to 1: the arc's sweep, a full circle at the call.
    let arcFraction: Double
    /// Whole seconds left to start and to complete, rounded up, never below 0.
    let startSecondsLeft: Int
    let completeSecondsLeft: Int
    let turnsOwed: Int

    init(owed: OwedPenalty, tick: Int, startSeconds: Double, completeSeconds: Double) {
        let toStart = Double(owed.startDeadlineTick - tick) / Double(Race.tickRate)
        let toComplete = Double(owed.completeDeadlineTick - tick) / Double(Race.tickRate)
        phase = owed.isStarted ? .complete : .start
        let (left, window) = owed.isStarted ? (toComplete, completeSeconds) : (toStart, startSeconds)
        arcFraction = window > 0 ? min(1, max(0, left / window)) : 0
        startSecondsLeft = Self.whole(toStart)
        completeSecondsLeft = Self.whole(toComplete)
        turnsOwed = owed.turnsOwed
    }

    /// The readout for `seat` in `frame`, or nil while she owes nothing or is a ghost.
    @MainActor init?(frame: TickFrame, seat: Int) {
        guard frame.owed.indices.contains(seat), let owed = frame.owed[seat], let penalty = frame.penalty,
              frame.boats.indices.contains(seat), !frame.boats[seat].isGhost else { return nil }
        self.init(owed: owed, tick: frame.tick, startSeconds: penalty.start, completeSeconds: penalty.complete)
    }

    // TODO-COPY (#124): the format is #15's; #124 polishes the words.
    /// "Turn · 11s / 26s" before the turn is started, "Turn · 26s" once it is, with " ×N" when N turns are owed.
    var noticeText: String {
        let clock = phase == .start ? "\(startSecondsLeft)s / \(completeSecondsLeft)s" : "\(completeSecondsLeft)s"
        return "Turn · \(clock)" + (turnsOwed > 1 ? " ×\(turnsOwed)" : "")
    }

    private static func whole(_ seconds: Double) -> Int {
        max(0, Int(seconds.rounded(.up)))
    }
}

/// The rule calls whose dashed line and rule-number badge show between the two boats (#123, #15), timed in race
/// time. Fed by the calls the session drains (the umpire's in practice, the server's online, so never before the
/// server calls it), or a frozen fixture's replayed calls.
nonisolated struct RuleCallLines: Equatable, Sendable {
    /// At most this many lines show at once, the newest (a placeholder).
    static let maxLines = 4
    /// Calls kept, newest last; older ones are long gone from the screen.
    static let kept = 16

    /// One line to draw.
    struct Line: Equatable, Sendable {
        let offender: Int
        let victim: Int
        /// The rule's number as the RRS writes it ("10", "16.1", "21.2").
        let badge: String
        /// 1, fading to 0 over the line's last seconds.
        let alpha: Double
    }

    private(set) var calls: [RuleCall] = []

    /// Records `call`. A call with no other boat (a mark touch) draws no line, so it isn't kept; nor is one already
    /// recorded (an online event delivered again after a resync).
    mutating func add(_ call: RuleCall) {
        guard call.offender != call.victim, !calls.contains(call) else { return }
        calls.append(call)
        if calls.count > Self.kept { calls.removeFirst(calls.count - Self.kept) }
    }

    /// The lines showing at race time `time`: calls younger than `seconds`, the newest first, at most `maxLines`,
    /// each fading out over its last `fadeSeconds`. A call from a tick after `time` (an online re-prediction a
    /// moment behind the server) shows in full.
    func active(at time: Double, seconds: Double, fadeSeconds: Double) -> [Line] {
        var lines: [Line] = []
        for call in calls.reversed() {
            let age = max(0, time - Double(call.tick) / Double(Race.tickRate))
            guard age < seconds else { continue }
            let left = seconds - age
            let alpha = fadeSeconds > 0 ? min(1, left / fadeSeconds) : 1
            lines.append(Line(offender: call.offender, victim: call.victim, badge: call.rule.rawValue, alpha: alpha))
            if lines.count == Self.maxLines { break }
        }
        return lines
    }
}

/// Which boats show a right-of-way glyph to `me` this frame, and which glyph (#123): every other boat within
/// `rangeHulls` of her with a keep-clear relation; none while the frame carries no relations (online until #96) or
/// she is a ghost.
nonisolated enum GlyphSelection {
    static func glyphs(keepClear: [RightOfWay?]?, positions: [Vec2], me: Int, isGhost: Bool, rangeHulls: Double,
                       hullLength: Double) -> [RightOfWayGlyph?] {
        guard let keepClear, !isGhost, positions.indices.contains(me) else {
            return Array(repeating: nil, count: positions.count)
        }
        return positions.indices.map { seat in
            guard seat != me, keepClear.indices.contains(seat),
                  RightOfWayGlyph.isInRange(positions[me], positions[seat], rangeHulls: rangeHulls, hullLength: hullLength)
            else { return nil }
            return RightOfWayGlyph.glyph(for: keepClear[seat], me: me)
        }
    }
}
