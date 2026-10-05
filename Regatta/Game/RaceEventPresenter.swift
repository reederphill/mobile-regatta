import Foundation
import RegattaCore

/// A race moment you feel (#22): each has one haptic, and #126's audio subscribes to the same cues
/// (`GameSession.onCue`). Puffs, wind shadow and the tack tap have no cue, so they can't fire one.
enum RaceCue: CaseIterable, Hashable {
    /// The sequence ticks: 30 s, 10 s, 5…1 s.
    case sequenceTick
    case gun
    /// You were over at the gun.
    case ocs
    case callAgainstMe
    case callForMe
    /// You touched a mark of your course (rule 31).
    case markTouch
    case penaltyDone
    case rounding
    case finish
    case protestFiled
    /// Your boat touched another.
    case contact
    case disqualified
    /// Your autohelm snapped to the groove (#219, #230).
    case grooveSnap
    /// Your roll tap hit (#222, #263); a miss has no haptic, only its notice.
    case rollHit

    /// The #22 table, completed by #219 (groove snap) and #222 (roll hit): one row a cue.
    static let haptics: [RaceCue: HapticPattern] = [
        .sequenceTick: .light,
        .gun: .heavy,
        .ocs: .notify(.warning),
        .callAgainstMe: .notify(.error),
        .callForMe: .notify(.success),
        .markTouch: .notify(.error),
        .penaltyDone: .notify(.success),
        .rounding: .light,
        .finish: .notify(.success),
        .protestFiled: .light,
        .contact: .heavy,
        .disqualified: .notify(.error),
        .grooveSnap: .light,
        // Untested on a device (#222): one constant to tune.
        .rollHit: .light,
    ]

    var haptic: HapticPattern {
        // Every cue has a row (`RaceEventPresenterTests.eventTableCoversEveryHapticRow`).
        Self.haptics[self]!
    }
}

/// A haptic of the #22 table.
enum HapticPattern: Equatable {
    /// A light click: impact 0.5.
    case light
    /// A heavy thump: impact 1.0 (the gun's).
    case heavy
    case notify(HapticNotification)

    /// Of several in one batch, the strongest plays: error > warning > success > heavy > light.
    var strength: Int {
        switch self {
        case .light: 0
        case .heavy: 1
        case .notify(.success): 2
        case .notify(.warning): 3
        case .notify(.error): 4
        }
    }

    func play(on haptics: any Haptics) {
        switch self {
        case .light: haptics.impact(intensity: 0.5)
        case .heavy: haptics.impact(intensity: 1)
        case .notify(let kind): haptics.notify(kind)
        }
    }

    /// The one pattern a batch of `cues` plays: the strongest, or none.
    static func strongest(of cues: [RaceCue]) -> HapticPattern? {
        cues.map(\.haptic).max { $0.strength < $1.strength }
    }
}

/// What one batch of race events shows and plays for you.
struct Presentation: Equatable {
    var cues: [RaceCue] = []
    var notices: [PresentedNotice] = []
}

struct PresentedNotice: Equatable {
    let kind: NoticeKind
    let text: String
    /// What it teaches: seen once it shows (`RaceEventPresenter.shown`), never if the slot drops it unshown.
    var marks: [SeenMark] = []
}

/// Turns the driver's race events into what you see and feel (#124): notices for the slot (#114), cues for haptics
/// and #126's audio. Shared by practice and online: online the events are the server's only (ADR 0005). It keeps
/// no game state (the session finishes your race); only what it has shown: the calls already presented (an online
/// call delivered again after a resync shows once), the plain words waiting in the slot, the countdown second and the
/// lag warning's edge.
///
/// Plain words are seen only once they show: the session reports each notice's `marks` as `shown` or `dropped`
/// (stale in the slot, #114), and a dropped one leaves its rule unseen for the next call. While one waits, a later
/// call of the same rule doesn't spell it out again.
///
/// Only events about you present: a call between two other boats posts nothing and plays nothing (#114). In
/// practice the driver drains every seat's events, so every one is filtered by `me`.
struct RaceEventPresenter {
    let me: Int
    /// A seat's label as the HUD shows it (`FleetRoster.label(of:playerSeat:)`).
    let name: (Int) -> String
    let seen: RuleSeenStore

    private var presentedCalls: Set<RuleCall> = []
    /// The server's ids of the events presented (`RaceEvent.id`, #96): online, an event delivered again is never
    /// presented twice. Offline events have none.
    private var presentedIds: Set<UInt32> = []
    /// Marks of notices posted and not yet shown or dropped, counted by notice.
    private var pending: [SeenMark: Int] = [:]
    private var lastCountdownSecond = Int.max
    private var isLagWarning = false

    init(me: Int, seen: RuleSeenStore = RuleSeenStore(), name: @escaping (Int) -> String = { "Boat \($0 + 1)" }) {
        self.me = me
        self.seen = seen
        self.name = name
    }

    /// `events`, oldest first. `autohelmHolding`: your boat's autohelm holds her (the rudder is centred) as they are
    /// presented, for #228's keep-clear words. The call carries no held-rudder fact: online this reads the prediction's
    /// boat when the server's call arrives.
    mutating func present(_ events: [RaceEvent], autohelmHolding: Bool = false) -> Presentation {
        var out = Presentation()
        for event in events { present(event, autohelmHolding: autohelmHolding, into: &out) }
        return out
    }

    // An exhaustive switch: a new `RaceEvent.Kind` doesn't compile until it has a row here.
    private mutating func present(_ event: RaceEvent, autohelmHolding: Bool, into out: inout Presentation) {
        if let id = event.id, !presentedIds.insert(id).inserted { return }
        switch event.kind {
        case .gun:
            out.cues.append(.gun)
        case .ocsNotice(let seat):
            guard seat == me else { return }
            out.cues.append(.ocs)
            out.notices.append(PresentedNotice(kind: .ocs, text: RuleWords.ocs))
        case .ruleCall(let call):
            guard call.offender == me || call.victim == me, presentedCalls.insert(call).inserted else { return }
            let against = call.offender == me
            out.cues.append(against ? .callAgainstMe : .callForMe)
            if let notice = callNotice(call, against: against, autohelmHolding: autohelmHolding) {
                out.notices.append(notice)
            }
        case .markTouch(let seat, let mark):
            guard seat == me else { return }
            out.cues.append(.markTouch)
            // Rule 31 is always against you: its first touch spells it out with the penalty line.
            if !hasSeen(.ruleAgainst(.touchingMark)) {
                out.notices.append(notice(.ruleCall, RuleWords.firstMarkTouch(mark),
                                          marks: [.rule(.touchingMark), .ruleAgainst(.touchingMark)]))
            }
        case .penaltyServed(let seat):
            if seat == me { out.cues.append(.penaltyDone) }
        case .rounded(let seat, _):
            if seat == me { out.cues.append(.rounding) }
        case .finished(let seat, _):
            if seat == me { out.cues.append(.finish) }
        case .disqualified(let seat, _):
            if seat == me { out.cues.append(.disqualified) }
        case .protestRecorded(let seat, _, _):
            if seat == me { out.cues.append(.protestFiled) }
        case .contact(let pair):
            if pair.contains(me) { out.cues.append(.contact) }
        case .grooveSnap(let seat):
            if seat == me { out.cues.append(.grooveSnap) }
        case .rollHit(let seat):
            guard seat == me else { return }
            out.cues.append(.rollHit)
            out.notices.append(PresentedNotice(kind: .roll, text: RuleWords.rollHit))
        case .rollMissed(let seat):
            // Overrides #124: a miss has no haptic, but it is read, as a hit is (`BoatNode`'s ring shows it too).
            if seat == me { out.notices.append(PresentedNotice(kind: .roll, text: RuleWords.rollMissed)) }
        case .markRoomNotice(let boat, let entitledOver, let mark):
            guard boat == me || entitledOver == me else { return }
            let text = RuleWords.markRoom(at: mark, entitled: boat == me, other: name(boat == me ? entitledOver : boat))
            out.notices.append(PresentedNotice(kind: .markRoom, text: text))
        case .tacked, .gybed, .penaltyStarted, .penaltyReset, .started, .cleared, .becameGhost,
             .firstFinish, .raceClosed:
            // Seen on the water or in the results, not felt (#22).
            break
        case .obstructionContact:
            // Land, the boundary or a free mark: visible on the water. #22's Contact is boat to boat.
            break
        }
    }

    /// A call's notice: plain words the first time its rule number is called on you (#23), and the first time it is
    /// called against you, with the penalty line; or #228's autohelm words the first time a keep-clear call catches
    /// your autohelm holding. Nil after that, when the line and badge carry it.
    private mutating func callNotice(_ call: RuleCall, against: Bool, autohelmHolding: Bool) -> PresentedNotice? {
        let other = name(against ? call.victim : call.offender)
        let owesTurn = call.turnsOwed > 0
        let rule = call.rule
        if against, autohelmHolding, RuleWords.keepClearRules.contains(rule), !hasSeen(.autohelmKeepClear) {
            let text = RuleWords.firstCall(rule, against: true, other: other, owesTurn: owesTurn, autohelm: true)
            return notice(.ruleCall, text, marks: [.autohelmKeepClear, .rule(rule), .ruleAgainst(rule)])
        }
        let marks: [SeenMark] = against ? [.rule(rule), .ruleAgainst(rule)] : [.rule(rule)]
        guard !hasSeen(marks[marks.count - 1]) else { return nil }
        return notice(.ruleCall, RuleWords.firstCall(rule, against: against, other: other, owesTurn: owesTurn),
                      marks: marks)
    }

    private func hasSeen(_ mark: SeenMark) -> Bool {
        pending[mark] != nil || seen.hasSeen(mark)
    }

    /// A notice teaching `marks`, pending until it shows or drops.
    private mutating func notice(_ kind: NoticeKind, _ text: String, marks: [SeenMark]) -> PresentedNotice {
        for mark in marks { pending[mark, default: 0] += 1 }
        return PresentedNotice(kind: kind, text: text, marks: marks)
    }

    /// A notice teaching `marks` showed: they are seen on this device.
    mutating func shown(_ marks: [SeenMark]) {
        for mark in marks { seen.markSeen(mark) }
        release(marks)
    }

    /// A notice teaching `marks` went stale unshown: the next call teaches them again.
    mutating func dropped(_ marks: [SeenMark]) {
        release(marks)
    }

    private mutating func release(_ marks: [SeenMark]) {
        for mark in marks {
            guard let count = pending[mark] else { continue }
            pending[mark] = count > 1 ? count - 1 : nil
        }
    }

    /// The sequence tick at race time `time` (negative before the gun): at 30 s, 10 s and 5…1 s, once each.
    mutating func sequenceCue(raceTime time: Double) -> RaceCue? {
        guard time < 0 else { return nil }
        let second = Int(ceil(-time))
        guard second != lastCountdownSecond else { return nil }
        lastCountdownSecond = second
        return second <= 5 || second == 10 || second == 30 ? .sequenceTick : nil
    }

    /// The RTT warning (#18, #68): one `.latency` notice as it starts, re-armed once it clears.
    mutating func lag(isWarning: Bool) -> PresentedNotice? {
        defer { isLagWarning = isWarning }
        return isWarning && !isLagWarning ? PresentedNotice(kind: .latency, text: RuleWords.lag) : nil
    }
}
