import RegattaCore

/// Who a race event is sent to. The race host sends each `Event` only to the clients of its audience's
/// seats (#18 reliable events; #65 targeted events).
public enum EventAudience: Equatable, Sendable {
    case everyone
    /// Only these seats' clients: a targeted event, such as the recall notice (#85, #9) or a mark-room
    /// notice (#91, #15).
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
        case .gun, .cleared, .started, .ruleCall, .markTouch, .obstructionContact, .contact, .penaltyStarted,
             .penaltyReset, .penaltyServed, .tacked, .gybed, .disqualified, .becameGhost, .rounded, .finished,
             .firstFinish, .raceClosed, .rollHit, .rollMissed:
            // A roll's hit or miss is seen by everyone, as her tack is (#121's wake; #117, #124 cue it).
            self = .everyone
        case .ocsNotice(let recipient):
            // The individual recall (rule 29.1) is told to the boat that was over, and only to her.
            self = .seats([recipient])
        case .markRoomNotice(let boat, let entitledOver, _):
            // A new rule 18 record is told to its two boats, and only to them (#91, #15).
            self = .seats([boat, entitledOver])
        case .protestRecorded(let seat, let target):
            // The acknowledgement goes to the protesting boat, and the protested boat is told (RRS 61.1).
            self = .seats([seat, target])
        case .grooveSnap(let seat):
            // The snap is felt by the boat that let go (#124), and nobody else.
            self = .seats([seat])
        }
    }
}

// Each kind's code is fixed for good: a new case takes the next free code (#63: later cases extend
// the codec), and a retired code is never reused. Code 4 was the pre-#73 `foul` (rule, offender,
// victim); a rule call is code 12. Code 11 was `raceClosed` without results; with them (#86) it is
// code 23. Code 17 was `markRoomNotice` with a list of recipients, never sent; with the entitled boat,
// the boat she is entitled over and the mark (#91) it is code 24. #263's roll hit and miss are 25 and 26. Seats, places, legs and turns are one
// byte; ticks are int32; mark names and reasons are strings.

extension RaceEvent.Kind {
    func encode(to w: inout WireWriter) throws {
        switch self {
        case .gun: w.u8(0)
        case .ocsNotice(let recipient):
            w.u8(1)
            try w.index(recipient, "recipient")
        case .cleared(let seat):
            w.u8(2)
            try w.index(seat, "seat")
        case .started(let seat):
            w.u8(3)
            try w.index(seat, "seat")
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
        case .protestRecorded(let seat, let target):
            w.u8(10)
            try w.index(seat, "seat")
            try w.index(target, "target")
        case .ruleCall(let call):
            w.u8(12)
            guard let incidentId = UInt16(exactly: call.incidentId) else { throw WireError.outOfRange("incidentId") }
            w.u16(incidentId)
            try w.i32(call.tick, "tick")
            w.u8(call.rule.wireCode)
            try w.index(call.offender, "offender")
            try w.index(call.victim, "victim")
            try w.index(call.leg, "leg")
            try w.index(call.turnsOwed, "turnsOwed")
            // #89: a flag, then the deadline pair when the call fixed its turn's clock.
            switch (call.startDeadlineTick, call.completeDeadlineTick) {
            case let (start?, complete?):
                w.u8(1)
                try w.i32(start, "startDeadlineTick")
                try w.i32(complete, "completeDeadlineTick")
            case (nil, nil):
                w.u8(0)
            default:
                throw WireError.outOfRange("deadlines")
            }
        case .obstructionContact(let seat, let kind):
            w.u8(13)
            try w.index(seat, "seat")
            w.u8(kind.wireCode)
        case .contact(let pair):
            w.u8(14)
            try w.index(pair.low, "seat")
            try w.index(pair.high, "seat")
        case .penaltyStarted(let seat):
            w.u8(15)
            try w.index(seat, "seat")
        case .penaltyReset(let seat):
            w.u8(16)
            try w.index(seat, "seat")
        case .markRoomNotice(let boat, let entitledOver, let mark):
            w.u8(24)
            try w.index(boat, "boat")
            try w.index(entitledOver, "entitledOver")
            try w.string(mark, limit: WireLimit.string, "mark")
        case .becameGhost(let seat):
            w.u8(18)
            try w.index(seat, "seat")
        case .firstFinish(let closeTick):
            w.u8(19)
            try w.i32(closeTick, "closeTick")
        case .tacked(let seat):
            w.u8(20)
            try w.index(seat, "seat")
        case .gybed(let seat):
            w.u8(21)
            try w.index(seat, "seat")
        case .grooveSnap(let seat):
            w.u8(22)
            try w.index(seat, "seat")
        case .raceClosed(let results):
            w.u8(23)
            try results.encode(to: &w)
        case .rollHit(let seat):
            w.u8(25)
            try w.index(seat, "seat")
        case .rollMissed(let seat):
            w.u8(26)
            try w.index(seat, "seat")
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .gun
        case 1: self = .ocsNotice(recipient: try r.index())
        case 2: self = .cleared(seat: try r.index())
        case 3: self = .started(seat: try r.index())
        case 5: self = .markTouch(seat: try r.index(), mark: try r.string(limit: WireLimit.string, "mark"))
        case 6: self = .penaltyServed(seat: try r.index())
        case 7: self = .rounded(seat: try r.index(), mark: try r.string(limit: WireLimit.string, "mark"))
        case 8: self = .finished(seat: try r.index(), place: try r.index())
        case 9: self = .disqualified(seat: try r.index(), reason: try r.string(limit: WireLimit.string, "reason"))
        case 10: self = .protestRecorded(seat: try r.index(), target: try r.index())
        case 12:
            let incidentId = Int(try r.u16())
            let tick = try r.i32()
            guard let rule = RacingRule(wireCode: try r.u8()) else { throw WireError.invalidValue("rule") }
            let offender = try r.index(), victim = try r.index(), leg = try r.index(), turnsOwed = try r.index()
            var deadlines: (start: Int, complete: Int)?
            switch try r.u8() {
            case 0: deadlines = nil
            case 1: deadlines = (try r.i32(), try r.i32())
            default: throw WireError.invalidValue("deadlines")
            }
            self = .ruleCall(RuleCall(
                incidentId: incidentId, tick: tick, rule: rule, offender: offender, victim: victim, leg: leg,
                turnsOwed: turnsOwed, startDeadlineTick: deadlines?.start, completeDeadlineTick: deadlines?.complete))
        case 13:
            let seat = try r.index()
            guard let kind = ObstructionKind(wireCode: try r.u8()) else { throw WireError.invalidValue("obstruction") }
            self = .obstructionContact(seat: seat, kind: kind)
        case 14:
            let low = try r.index(), high = try r.index()
            guard low < high else { throw WireError.invalidValue("contact") }
            self = .contact(SeatPair(low, high))
        case 15: self = .penaltyStarted(seat: try r.index())
        case 16: self = .penaltyReset(seat: try r.index())
        case 18: self = .becameGhost(seat: try r.index())
        case 19: self = .firstFinish(closeTick: try r.i32())
        case 20: self = .tacked(seat: try r.index())
        case 21: self = .gybed(seat: try r.index())
        case 22: self = .grooveSnap(seat: try r.index())
        case 23: self = .raceClosed(results: try RaceResults(from: &r))
        case 24:
            self = .markRoomNotice(boat: try r.index(), entitledOver: try r.index(),
                                   mark: try r.string(limit: WireLimit.string, "mark"))
        case 25: self = .rollHit(seat: try r.index())
        case 26: self = .rollMissed(seat: try r.index())
        default: throw WireError.invalidValue("event")
        }
    }
}

// Rule and obstruction codes are fixed for good, like event codes: a new case takes the next free code.

extension RacingRule {
    var wireCode: UInt8 {
        switch self {
        case .portStarboard: 0
        case .windwardLeeward: 1
        case .clearAstern: 2
        case .whileTacking: 3
        case .acquiringRightOfWay: 4
        case .changingCourse: 5
        case .markRoomApplies: 6
        case .givingMarkRoom: 7
        case .tackingInTheZone: 8
        case .returningToStart: 9
        case .takingAPenalty: 10
        case .sailingTheCourse: 11
        case .individualRecall: 12
        case .touchingMark: 13
        case .exoneratedCompelled: 14
        case .exoneratedEntitledRoom: 15
        }
    }

    init?(wireCode: UInt8) {
        guard let rule = RacingRule.allCases.first(where: { $0.wireCode == wireCode }) else { return nil }
        self = rule
    }
}

extension ObstructionKind {
    var wireCode: UInt8 {
        switch self {
        case .land: 0
        case .boundary: 1
        }
    }

    init?(wireCode: UInt8) {
        guard let kind = ObstructionKind.allCases.first(where: { $0.wireCode == wireCode }) else { return nil }
        self = kind
    }
}

// The results of a closed race (#86): whether it is rated, then each row in display order: the seat, its
// place, its result code, and its finish tick for a finisher only. Result codes are fixed for good like
// event codes.

extension RaceResults {
    func encode(to w: inout WireWriter) throws {
        w.bool(rated)
        try w.count(rows.count, limit: WireLimit.seats, "results")
        for row in rows {
            try w.index(row.seat, "seat")
            try w.index(row.place, "place")
            w.u8(row.code.wireCode)
            guard (row.code == .finished) == (row.finishTick != nil) else { throw WireError.outOfRange("finishTick") }
            if let tick = row.finishTick { try w.i32(tick, "finishTick") }
        }
    }

    init(from r: inout WireReader) throws {
        let rated = try r.bool("rated")
        let n = try r.count(limit: WireLimit.seats, "results")
        let rows = try (0..<n).map { _ in
            let seat = try r.index(), place = try r.index()
            guard let code = ResultCode(wireCode: try r.u8()) else { throw WireError.invalidValue("resultCode") }
            return SeatResult(seat: seat, place: place, code: code, finishTick: code == .finished ? try r.i32() : nil)
        }
        self.init(rows: rows, rated: rated)
    }
}

extension ResultCode {
    var wireCode: UInt8 {
        switch self {
        case .finished: 0
        case .byDistance: 1
        case .dsq: 2
        case .ocs: 3
        case .ret: 4
        }
    }

    init?(wireCode: UInt8) {
        guard let code = ResultCode.allCases.first(where: { $0.wireCode == wireCode }) else { return nil }
        self = code
    }
}
