import Foundation
import RegattaCore

/// Your owed penalty as the penalty arc and the Turn notice show it (#123, #15): until the turn is started the arc
/// counts down the start deadline, then the complete deadline, each a share of its own window. The windows are the
/// rules' (`raceFormat.penalty`), never literals; the seconds come from the race tick, not the wall clock.
///
/// Under a `tackAndGybe` penalty (fleet-rules@6, #489) there is one limit: the arc counts down the complete deadline
/// from the call, and inside it the turn's two marks (`marks`) light as the tack and the gybe are made.
nonisolated struct PenaltyReadout: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Owed, not yet started: the arc counts the start deadline.
        case start
        /// Started: the arc counts the complete deadline. Always, under a `tackAndGybe` penalty.
        case complete
    }

    /// A `tackAndGybe` turn's two marks inside the arc (#489): the screen-up half is the tack, the screen-down half
    /// the gybe, each lit once that crossing is made (`OwedPenalty.hasTacked`, `hasGybed`).
    struct TurnMarks: Equatable, Sendable {
        let isTackLit: Bool
        let isGybeLit: Bool
        /// The turn's way, as each lit half's barb points it: +1 clockwise on the screen, −1 anticlockwise, 0 before
        /// it is set (no barb). `OwedPenalty.direction`'s +1 is to starboard, the heading increasing, which is
        /// clockwise on a north-up chart; turning the camera turns the chart without mirroring it, so it stays
        /// clockwise on the screen whatever the camera's rotation.
        let direction: Int
    }

    let phase: Phase
    /// What's left of the current deadline's window, 0 to 1: the arc's sweep, a full circle at the call.
    let arcFraction: Double
    /// Whole seconds left to start and to complete, rounded up, never below 0.
    let startSecondsLeft: Int
    let completeSecondsLeft: Int
    let turnsOwed: Int
    /// The turn's marks under a `tackAndGybe` penalty; nil under a `fullCircle` one (fleet-rules@5 and before), whose
    /// arc draws as it always has.
    private(set) var marks: TurnMarks?

    init(owed: OwedPenalty, tick: Int, startSeconds: Double, completeSeconds: Double,
         turn: RulesConfig.PenaltyTurn = .fullCircle) {
        let toStart = Double(owed.startDeadlineTick - tick) / Double(Race.tickRate)
        let toComplete = Double(owed.completeDeadlineTick - tick) / Double(Race.tickRate)
        switch turn {
        case .fullCircle:
            phase = owed.isStarted ? .complete : .start
            marks = nil
        case .tackAndGybe:
            // One limit (`OwedPenalty.startDeadlineTick` is the complete deadline): no start phase.
            phase = .complete
            marks = TurnMarks(isTackLit: owed.hasTacked, isGybeLit: owed.hasGybed, direction: owed.direction)
        }
        let (left, window) = phase == .complete ? (toComplete, completeSeconds) : (toStart, startSeconds)
        arcFraction = window > 0 ? min(1, max(0, left / window)) : 0
        startSecondsLeft = Self.whole(toStart)
        completeSecondsLeft = Self.whole(toComplete)
        turnsOwed = owed.turnsOwed
    }

    /// Nothing owed, only a served turn's marks flashing.
    private init(servedMarks: TurnMarks) {
        phase = .complete
        arcFraction = 0
        startSecondsLeft = 0
        completeSecondsLeft = 0
        turnsOwed = 0
        marks = servedMarks
    }

    /// The readout for `seat` in `frame`, or nil while she owes nothing or is a ghost. Under a `tackAndGybe` penalty,
    /// while `served` flashes (`ServedTurnFlash`) both marks are lit, over the next owed turn's countdown or, owing
    /// none, alone (`turnsOwed` 0, no countdown).
    @MainActor init?(frame: TickFrame, seat: Int, served: ServedTurnFlash = ServedTurnFlash()) {
        guard frame.boats.indices.contains(seat), !frame.boats[seat].isGhost, let penalty = frame.penalty else { return nil }
        let owed = frame.owed.indices.contains(seat) ? frame.owed[seat] : nil
        let flashes = penalty.turn == .tackAndGybe && served.isShowing(at: frame.tick)
        if let owed {
            self.init(owed: owed, tick: frame.tick, startSeconds: penalty.start, completeSeconds: penalty.complete,
                      turn: penalty.turn)
            if flashes {
                marks = TurnMarks(isTackLit: true, isGybeLit: true,
                                  direction: owed.direction != 0 ? owed.direction : served.direction)
            }
        } else if flashes {
            self.init(servedMarks: TurnMarks(isTackLit: true, isGybeLit: true, direction: served.direction))
        } else {
            return nil
        }
    }

    // TODO-COPY (#171): the format is #15's.
    /// "Turn · 11s / 26s" before the turn is started, "Turn · 26s" once it is (and always under a `tackAndGybe`
    /// penalty, which has one limit), with " ×N" when N turns are owed.
    var noticeText: String {
        let clock = phase == .start ? "\(startSecondsLeft)s / \(completeSecondsLeft)s" : "\(completeSecondsLeft)s"
        return "Turn · \(clock)" + (turnsOwed > 1 ? " ×\(turnsOwed)" : "")
    }

    private static func whole(_ seconds: Double) -> Int {
        max(0, Int(seconds.rounded(.up)))
    }
}

/// A `tackAndGybe` penalty turn just served (#489): the penalty arc lights both its marks for `seconds` of race time,
/// then shows the next owed turn (both grey) or nothing. The session tells it each serve of yours as it drains the
/// `penaltyServed` event (`served(at:)`, at the race tick it is shown on: online the server's word arrives after the
/// prediction's tick); the scene tells it your owed turn each frame (`follow`), so it keeps the way of a last turn,
/// whose way the race clears as it is served.
nonisolated struct ServedTurnFlash: Equatable, Sendable {
    /// About half a second (the owner's sketch, #489).
    static let seconds = 0.5

    /// The race tick the last serve was shown from; nil before any.
    private(set) var tick: Int?
    /// The way of the last turn you owed with one set: the served marks' barbs.
    private(set) var direction = 0

    init() {}

    /// Keeps `owed`'s way, when it has one.
    mutating func follow(_ owed: OwedPenalty?) {
        if let way = owed?.direction, way != 0 { direction = way }
    }

    /// A turn of yours was served, shown from race tick `tick`.
    mutating func served(at tick: Int) {
        self.tick = tick
    }

    /// Whether the flash shows at race tick `now`: from the serve's tick for `seconds`.
    func isShowing(at now: Int) -> Bool {
        guard let tick else { return false }
        return now >= tick && Double(now - tick) < Self.seconds * Double(Race.tickRate)
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

/// The right-of-way glow round one boat (#123): red where `me` must keep clear of her, green where she must keep
/// clear of `me`, `intensity` 0 to 1 (1 at the glow's full distance, 0 where it starts).
nonisolated struct RightOfWayGlow: Equatable, Sendable {
    let kind: RightOfWayGlyph
    let intensity: Double
}

/// Which boats glow to `me` this frame, and how strongly (#123): every other boat within `rangeHulls` of her with a
/// keep-clear relation, fading in from nothing at `rangeHulls` to full at `fullHulls` (centre to centre); none while
/// the frame carries no relations or she is a ghost. Online the relations are the server umpire's (#96).
nonisolated enum GlowSelection {
    static func glows(keepClear: [RightOfWay?]?, positions: [Vec2], me: Int, isGhost: Bool, rangeHulls: Double,
                      fullHulls: Double, hullLength: Double) -> [RightOfWayGlow?] {
        guard let keepClear, !isGhost, positions.indices.contains(me) else {
            return Array(repeating: nil, count: positions.count)
        }
        return positions.indices.map { seat in
            guard seat != me, keepClear.indices.contains(seat),
                  RightOfWayGlyph.isInRange(positions[me], positions[seat], rangeHulls: rangeHulls, hullLength: hullLength),
                  let kind = RightOfWayGlyph.glyph(for: keepClear[seat], me: me) else { return nil }
            let hulls = (positions[seat] - positions[me]).length / hullLength
            let intensity = fadeIn(hulls: hulls, rangeHulls: rangeHulls, fullHulls: fullHulls)
            return intensity > 0 ? RightOfWayGlow(kind: kind, intensity: intensity) : nil
        }
    }

    /// 0 at `rangeHulls` and beyond, 1 at `fullHulls` and inside, eased between (smoothstep) so the glow neither
    /// pops on at the edge nor stops growing abruptly at the end.
    static func fadeIn(hulls: Double, rangeHulls: Double, fullHulls: Double) -> Double {
        guard rangeHulls > fullHulls else { return hulls <= rangeHulls ? 1 : 0 }
        let t = min(1, max(0, (rangeHulls - hulls) / (rangeHulls - fullHulls)))
        return t * t * (3 - 2 * t)
    }
}
