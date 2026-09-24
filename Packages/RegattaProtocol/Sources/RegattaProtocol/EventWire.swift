import RegattaCore

/// Who a race event is sent to. The race host sends each `Event` only to the clients of its audience's
/// seats (#18 reliable events; #65 targeted events).
public enum EventAudience: Equatable, Sendable {
    case everyone
    /// Only these seats' clients: a targeted event, such as the recall notice (#85, #9) or a mark-room
    /// notice (#96, #15).
    case seats([Int])

    public func includes(seat: Int) -> Bool {
        switch self {
        case .everyone: true
        case .seats(let seats): seats.contains(seat)
        }
    }

    /// The audience of each kind. Exhaustive: a new `RaceEvent.Kind` case doesn't compile until it has one.
    public init(_ kind: RaceEvent.Kind) {
        switch kind {
        case .gun, .ocs, .cleared, .started, .foul, .markTouch, .penaltyServed, .rounded, .finished,
             .disqualified, .raceOver:
            // `.ocs` is today's broadcast; #85 adds the targeted `ocsNotice` beside it.
            self = .everyone
        case .protest(let seat, let target):
            // The acknowledgement goes to the protesting boat, and the protested boat is told (RRS 61.1).
            self = .seats([seat, target])
        }
    }
}

// Each kind's code is fixed for good: a new case takes the next free code (#63: later cases extend
// the codec). Seats and places are one byte; mark names and reasons are strings.

extension RaceEvent.Kind {
    func encode(to w: inout WireWriter) throws {
        switch self {
        case .gun: w.u8(0)
        case .ocs(let seat):
            w.u8(1)
            try w.index(seat, "seat")
        case .cleared(let seat):
            w.u8(2)
            try w.index(seat, "seat")
        case .started(let seat):
            w.u8(3)
            try w.index(seat, "seat")
        case .foul(let call):
            w.u8(4)
            try w.index(call.rule.rawValue, "rule")
            try w.index(call.offender, "offender")
            try w.index(call.victim, "victim")
        case .markTouch(let seat, let mark):
            w.u8(5)
            try w.index(seat, "seat")
            try w.string(mark, limit: WireLimit.string, "mark")
        case .penaltyServed(let seat):
            w.u8(6)
            try w.index(seat, "seat")
        case .rounded(let seat, let mark):
            w.u8(7)
            try w.index(seat, "seat")
            try w.string(mark, limit: WireLimit.string, "mark")
        case .finished(let seat, let place):
            w.u8(8)
            try w.index(seat, "seat")
            try w.index(place, "place")
        case .disqualified(let seat, let reason):
            w.u8(9)
            try w.index(seat, "seat")
            try w.string(reason, limit: WireLimit.string, "reason")
        case .protest(let seat, let target):
            w.u8(10)
            try w.index(seat, "seat")
            try w.index(target, "target")
        case .raceOver: w.u8(11)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .gun
        case 1: self = .ocs(seat: try r.index())
        case 2: self = .cleared(seat: try r.index())
        case 3: self = .started(seat: try r.index())
        case 4:
            guard let rule = RacingRule(rawValue: Int(try r.u8())) else { throw WireError.invalidValue("rule") }
            self = .foul(RuleCall(rule: rule, offender: try r.index(), victim: try r.index()))
        case 5: self = .markTouch(seat: try r.index(), mark: try r.string(limit: WireLimit.string, "mark"))
        case 6: self = .penaltyServed(seat: try r.index())
        case 7: self = .rounded(seat: try r.index(), mark: try r.string(limit: WireLimit.string, "mark"))
        case 8: self = .finished(seat: try r.index(), place: try r.index())
        case 9: self = .disqualified(seat: try r.index(), reason: try r.string(limit: WireLimit.string, "reason"))
        case 10: self = .protest(seat: try r.index(), target: try r.index())
        case 11: self = .raceOver
        default: throw WireError.invalidValue("event")
        }
    }
}
