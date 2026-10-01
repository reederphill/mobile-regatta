import Foundation
import Testing
@testable import Regatta

/// The HUD's one notice line (#114): priority from the data table, hints held behind rule calls and OCS (#23), and
/// expiry.
@MainActor @Suite struct NoticeSlotTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func everyKindHasARowAndTheOrderIsTheTicket() {
        for kind in NoticeKind.allCases { #expect(NoticeTable.rows[kind] != nil, "\(kind)") }
        let order = NoticeKind.allCases.sorted { NoticeTable.rule($0).priority > NoticeTable.rule($1).priority }
        #expect(order == [.ocs, .ruleCall, .markRoom, .penalty, .latency, .hint])
        #expect(NoticeKind.allCases.filter { NoticeTable.rule($0).holdsHints } == [.ocs, .ruleCall])
    }

    @Test func aHigherNoticeReplacesALowerAndALowerWaits() {
        var slot = NoticeSlot()
        #expect(slot.post(.latency, "slow", at: Self.at(0))?.kind == .latency)
        #expect(slot.post(.ruleCall, "foul", at: Self.at(1))?.kind == .ruleCall)
        // The replaced latency warning is done, not queued.
        #expect(slot.waiting.isEmpty)
        // An equal one waits its turn.
        #expect(slot.post(.ruleCall, "second foul", at: Self.at(2))?.text == "foul")
        #expect(slot.current(at: Self.at(7))?.text == "second foul")
        #expect(slot.current(at: Self.at(13)) == nil)
    }

    @Test func hintsWaitBehindRuleCallsAndOCS() {
        var slot = NoticeSlot()
        #expect(slot.post(.hint, "steer", at: Self.at(0))?.kind == .hint)
        // OCS replaces the hint, and the hint waits to show again.
        #expect(slot.post(.ocs, "over", at: Self.at(1))?.kind == .ocs)
        #expect(slot.waiting.map(\.kind) == [.hint])
        // A rule call posted while OCS shows waits; the hint stays behind it.
        #expect(slot.post(.ruleCall, "foul", at: Self.at(2))?.kind == .ocs)
        #expect(slot.current(at: Self.at(7))?.kind == .ruleCall)
        // While the rule call shows, no hint, however long it has waited.
        for t in stride(from: 7.0, to: 13, by: 0.5) { #expect(slot.current(at: Self.at(t))?.kind == .ruleCall) }
        #expect(slot.current(at: Self.at(13))?.kind == .hint)
    }

    @Test func aHintNeverShowsWhileARuleCallWaits() {
        var slot = NoticeSlot()
        slot.post(.markRoom, "room", at: Self.at(0))
        slot.post(.hint, "steer", at: Self.at(0.5))
        slot.post(.ruleCall, "foul", at: Self.at(1))
        // The rule call outranks mark-room, which is replaced; the hint stays held.
        #expect(slot.current(at: Self.at(1))?.kind == .ruleCall)
        #expect(slot.current(at: Self.at(7))?.kind == .hint)
    }

    @Test func noticesExpireAndStaleOnesAreDropped() {
        var slot = NoticeSlot()
        let shown = slot.post(.penalty, "spin", at: Self.at(0))
        #expect(shown?.expires == Self.at(NoticeTable.rule(.penalty).seconds))
        #expect(slot.current(at: Self.at(4.9))?.kind == .penalty)
        #expect(slot.current(at: Self.at(5)) == nil)
        // A mark-room notice that waits past its max wait is dropped: it would be about a mark long gone.
        slot.post(.ruleCall, "foul", at: Self.at(10))
        slot.post(.markRoom, "room", at: Self.at(10))
        #expect(slot.current(at: Self.at(16)) == nil)
        #expect(slot.waiting.isEmpty)
    }
}
