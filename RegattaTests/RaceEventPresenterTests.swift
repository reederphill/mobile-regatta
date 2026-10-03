import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// Driver events into notices and haptics (#124): the #22 haptic table, plain words the first time a rule is called
/// (#23), one-line mark-room notices (#15), and nothing for a moment you see rather than feel.
@MainActor @Suite struct RaceEventPresenterTests {
    private static let config = RaceConfig(opponents: 2, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
    private static let me = 0
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func event(_ kind: RaceEvent.Kind) -> RaceEvent { RaceEvent(tick: 0, kind: kind) }

    private static func call(_ rule: RacingRule = .portStarboard, offender: Int, victim: Int, incident: Int = 1,
                             turns: Int = 1) -> RaceEvent {
        event(.ruleCall(RuleCall(incidentId: incident, tick: incident, rule: rule, offender: offender, victim: victim,
                                 leg: 0, turnsOwed: turns, startDeadlineTick: nil, completeDeadlineTick: nil)))
    }

    /// `events` presented, and every notice of them shown at once (`RaceEventPresenter.shown`).
    private static func show(_ events: [RaceEvent], on presenter: inout RaceEventPresenter,
                             autohelmHolding: Bool = false) -> Presentation {
        let out = presenter.present(events, autohelmHolding: autohelmHolding)
        for notice in out.notices { presenter.shown(notice.marks) }
        return out
    }

    /// A session whose haptics reach `recorder`, with the first countdown tick already played and forgotten.
    private static func session(_ recorder: HapticsTests.RecordingGenerator) -> GameSession {
        let session = GameSession(config: config, haptics: GatedHaptics(generator: recorder, isOn: true))
        session.now = { t0 }
        session.consume([])
        recorder.calls.removeAll()
        return session
    }

    /// Every #22 row, with #219's groove snap and #222's roll hit: the table says it, an event for you plays it, and
    /// the session plays it as the generator call it names.
    @Test func eventTableCoversEveryHapticRow() {
        let expected: [RaceCue: HapticPattern] = [
            .sequenceTick: .light, .gun: .heavy, .ocs: .notify(.warning), .callAgainstMe: .notify(.error),
            .callForMe: .notify(.success), .markTouch: .notify(.error), .penaltyDone: .notify(.success),
            .rounding: .light, .finish: .notify(.success), .protestFiled: .light, .contact: .heavy,
            .disqualified: .notify(.error), .grooveSnap: .light, .rollHit: .light,
        ]
        #expect(RaceCue.haptics == expected)
        #expect(Set(RaceCue.allCases) == Set(expected.keys), "every cue has a row")

        let me = Self.me
        let events: [RaceCue: RaceEvent.Kind] = [
            .gun: .gun, .ocs: .ocsNotice(recipient: me),
            .markTouch: .markTouch(seat: me, mark: "windward mark"), .penaltyDone: .penaltyServed(seat: me),
            .rounding: .rounded(seat: me, mark: "windward mark"), .finish: .finished(seat: me, place: 1),
            .protestFiled: .protestRecorded(seat: me, target: 1, matchedIncidentId: nil), .contact: .contact(SeatPair(me, 1)),
            .disqualified: .disqualified(seat: me, reason: "Unserved penalty"), .grooveSnap: .grooveSnap(seat: me),
            .rollHit: .rollHit(seat: me),
        ]
        for (cue, kind) in events {
            var presenter = RaceEventPresenter(me: me)
            #expect(presenter.present([Self.event(kind)]).cues == [cue], "\(cue)")
        }
        var presenter = RaceEventPresenter(me: me)
        #expect(presenter.present([Self.call(offender: me, victim: 1)]).cues == [.callAgainstMe])
        #expect(presenter.present([Self.call(offender: 1, victim: me, incident: 2)]).cues == [.callForMe])
        #expect(presenter.sequenceCue(raceTime: -30) == .sequenceTick)
        #expect(presenter.sequenceCue(raceTime: -29.5) == nil, "once a second")
        #expect(presenter.sequenceCue(raceTime: -20) == nil, "only 30, 10 and 5…1")
        for second in [10.0, 5, 4, 3, 2, 1] { #expect(presenter.sequenceCue(raceTime: -second) == .sequenceTick) }

        for (pattern, call) in [(HapticPattern.light, "impact 0.5"), (.heavy, "impact 1.0"),
                                (.notify(.success), "notify success"), (.notify(.warning), "notify warning"),
                                (.notify(.error), "notify error")] {
            let recorder = HapticsTests.RecordingGenerator()
            pattern.play(on: GatedHaptics(generator: recorder, isOn: true))
            #expect(recorder.calls == [call])
        }
        // Through the session, gated by Settings' Haptics (#110).
        let recorder = HapticsTests.RecordingGenerator()
        let session = Self.session(recorder)
        session.consume([Self.event(.ocsNotice(recipient: session.driver.myBoatIndex))])
        #expect(recorder.calls == ["notify warning"])
    }

    /// The first call of a rule number, for or against you, spells it out (#23); a later one posts no notice: the line,
    /// its badge and the haptic carry it. Reset hints spells it out again.
    @Test func secondCallOfSameRuleIsBadgeOnly() throws {
        let name = "RaceEventPresenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let me = Self.me
        var presenter = RaceEventPresenter(me: me, seen: RuleSeenStore(defaults: defaults))

        let first = Self.show([Self.call(offender: me, victim: 1, incident: 1)], on: &presenter)
        #expect(first.cues == [.callAgainstMe])
        let text = try #require(first.notices.first.map(\.text))
        #expect(first.notices.map(\.kind) == [.ruleCall])
        #expect(text.contains(RuleWords.plain(.portStarboard)) && text.contains("(rule 10)"), "\(text)")
        #expect(text.contains("one full circle") && !text.contains("360") && !text.contains("720"), "\(text)")

        // The same call delivered again (an online resync) shows nothing and plays nothing.
        #expect(Self.show([Self.call(offender: me, victim: 1, incident: 1)], on: &presenter) == Presentation())
        // The next rule 10 call, in your favour this time: felt, no notice.
        let second = Self.show([Self.call(offender: 1, victim: me, incident: 2)], on: &presenter)
        #expect(second.cues == [.callForMe] && second.notices.isEmpty)
        // Another number spells itself out, in your favour too.
        let other = Self.show([Self.call(.windwardLeeward, offender: 2, victim: me, incident: 3)], on: &presenter)
        #expect(other.notices.first?.text.contains("(rule 11)") == true && other.notices.first?.text.contains("fouled you") == true)
        // A mark touch is rule 31's first call, then felt alone.
        #expect(Self.show([Self.event(.markTouch(seat: me, mark: "pin"))], on: &presenter).notices.first?.text.contains("(rule 31)") == true)
        #expect(Self.show([Self.event(.markTouch(seat: me, mark: "pin"))], on: &presenter).notices.isEmpty)

        // Stored with hint progress: a new race on this device remembers, and Reset hints forgets.
        var nextRace = RaceEventPresenter(me: me, seen: RuleSeenStore(defaults: defaults))
        #expect(nextRace.present([Self.call(offender: me, victim: 1, incident: 9)]).notices.isEmpty)
        for key in [RuleSeenStore.rulesKey, RuleSeenStore.rulesAgainstKey, RuleSeenStore.autohelmKey] {
            #expect(key.hasPrefix(DeviceSettings.hintKeyPrefix))
        }
        DeviceSettings.resetHints(in: defaults)
        #expect(nextRace.present([Self.call(offender: me, victim: 1, incident: 10)]).notices.count == 1)

        // A call between two other boats posts nothing and plays nothing (#114).
        #expect(presenter.present([Self.call(.clearAstern, offender: 1, victim: 2, incident: 11)]) == Presentation())
    }

    /// Nothing fires for a tack tap, a puff or wind shadow (#22, #112, #220): puffs and shadow have no race event,
    /// and the moments you see on the water have no cue.
    @Test func noHapticForTackTapPuffOrShadow() {
        let me = Self.me
        var presenter = RaceEventPresenter(me: me)
        let seen: [RaceEvent.Kind] = [
            .tacked(seat: me), .gybed(seat: me), .rollMissed(seat: me), .penaltyStarted(seat: me),
            .penaltyReset(seat: me), .started(seat: me), .cleared(seat: me), .becameGhost(seat: me),
            .firstFinish(closeTick: 10), .obstructionContact(seat: me, kind: .land),
            .obstructionContact(seat: me, kind: .mark),
        ]
        #expect(presenter.present(seen.map(Self.event)).cues.isEmpty)

        let recorder = HapticsTests.RecordingGenerator()
        let session = Self.session(recorder)
        session.tackOrGybe()
        session.pressTack(at: 10)
        session.releaseTack(at: 11)
        // Your own tack, as the race reports it.
        session.consume([Self.event(.tacked(seat: session.driver.myBoatIndex))])
        #expect(recorder.calls.isEmpty, "\(recorder.calls)")
    }

    /// Your autohelm snapping to the groove clicks lightly (#219); another boat's doesn't.
    @Test func grooveSnapGivesLightHaptic() {
        var presenter = RaceEventPresenter(me: Self.me)
        #expect(presenter.present([Self.event(.grooveSnap(seat: Self.me))]).cues == [.grooveSnap])
        #expect(presenter.present([Self.event(.grooveSnap(seat: 1))]).cues.isEmpty)
        #expect(RaceCue.grooveSnap.haptic == .light)

        let recorder = HapticsTests.RecordingGenerator()
        let session = Self.session(recorder)
        let me = session.driver.myBoatIndex
        session.consume([Self.event(.grooveSnap(seat: (me + 1) % 3))])
        #expect(recorder.calls.isEmpty)
        session.consume([Self.event(.grooveSnap(seat: me))])
        #expect(recorder.calls == ["impact 0.5"])
    }

    /// Mark-room has no notice: the right-of-way glow shows who owes it (`Race.keepClearRelations(of:)`), so the
    /// record's event presents nothing, to either boat or to a third.
    @Test func markRoomNoticeIsSilent() {
        for (boat, over) in [(Self.me, 1), (1, Self.me), (1, 2)] {
            var presenter = RaceEventPresenter(me: Self.me)
            #expect(presenter.present([Self.event(.markRoomNotice(boat: boat, entitledOver: over, mark: "pin"))]) == Presentation())
        }
    }

    /// Your roll tap's hit plays a haptic (#222); a miss plays none, and nor does another boat's hit.
    @Test func rollHitGivesHapticMissDoesNot() {
        let recorder = HapticsTests.RecordingGenerator()
        let session = Self.session(recorder)
        let me = session.driver.myBoatIndex
        session.consume([Self.event(.rollMissed(seat: me))])
        session.consume([Self.event(.rollHit(seat: (me + 1) % 3))])
        #expect(recorder.calls.isEmpty)
        session.consume([Self.event(.rollHit(seat: me))])
        #expect(recorder.calls == ["impact 0.5"])
    }

    /// Your roll tack's result is read as well as seen (#222), overriding #124's "a miss has no cue": a hit and a miss each
    /// present a short `.roll` notice, a hit's with its haptic cue and a miss's with none, and another boat's roll presents
    /// nothing.
    @Test func yourRollTacksResultPresentsANotice() {
        let me = Self.me
        var presenter = RaceEventPresenter(me: me)
        let hit = presenter.present([Self.event(.rollHit(seat: me))])
        #expect(hit.cues == [.rollHit] && hit.notices == [PresentedNotice(kind: .roll, text: RuleWords.rollHit)])
        let miss = presenter.present([Self.event(.rollMissed(seat: me))])
        #expect(miss.cues.isEmpty && miss.notices == [PresentedNotice(kind: .roll, text: RuleWords.rollMissed)])
        #expect(presenter.present([Self.event(.rollHit(seat: me + 1)), Self.event(.rollMissed(seat: me + 1))]) == Presentation(),
                "another boat's roll")
    }

    /// #228: the first keep-clear call made while your autohelm held says so, once per device, in place of the rule's
    /// plain words; rules 10–13 only.
    @Test func autohelmKeepClearWordsShowOnce() {
        let me = Self.me
        var presenter = RaceEventPresenter(me: me)
        let rule15 = Self.show([Self.call(.acquiringRightOfWay, offender: me, victim: 1, incident: 1)], on: &presenter,
                               autohelmHolding: true)
        #expect(rule15.notices.first?.text.contains(RuleWords.autohelmKeepClear) == false, "not rule 15")
        let first = Self.show([Self.call(.windwardLeeward, offender: me, victim: 1, incident: 2)], on: &presenter,
                              autohelmHolding: true)
        let text = first.notices.first?.text ?? ""
        #expect(text.contains(RuleWords.autohelmKeepClear) && text.contains("(rule 11)"), "\(text)")
        #expect(presenter.seen.hasSeen(.rule(.windwardLeeward)) && presenter.seen.hasSeen(.ruleAgainst(.windwardLeeward)))
        #expect(text.contains(RuleWords.penaltyLine), "\(text)")
        let again = Self.show([Self.call(.portStarboard, offender: me, victim: 1, incident: 3)], on: &presenter,
                              autohelmHolding: true)
        #expect(again.notices.first?.text.contains(RuleWords.autohelmKeepClear) == false, "once per device")
        #expect(again.notices.first?.text.contains(RuleWords.plain(.portStarboard)) == true)
    }

    /// A contact and its call arrive on one tick: one haptic, the strongest; both cues are reported.
    @Test func oneBatchPlaysItsStrongestHaptic() {
        let recorder = HapticsTests.RecordingGenerator()
        let session = Self.session(recorder)
        let me = session.driver.myBoatIndex
        var cues: [RaceCue] = []
        session.onCue = { cues.append($0) }
        let other = (me + 1) % 3
        session.consume([Self.event(.contact(SeatPair(me, other))), Self.call(offender: me, victim: other)])
        #expect(recorder.calls == ["notify error"])
        #expect(cues == [.contact, .callAgainstMe])
        #expect(session.notice?.kind == .ruleCall)
    }

    /// The RTT warning (#18, #68) is one notice as it starts, again only after it clears, and it waits out a live Turn
    /// notice (#123) rather than going stale behind it: three stacked turns, 135 s, are well past its 30 s wait.
    @Test func lagWarningIsOneShotAndWaitsOutAPenalty() {
        var presenter = RaceEventPresenter(me: Self.me)
        #expect(presenter.lag(isWarning: false) == nil)
        #expect(presenter.lag(isWarning: true) == PresentedNotice(kind: .latency, text: RuleWords.lag))
        #expect(presenter.lag(isWarning: true) == nil, "one-shot")
        #expect(presenter.lag(isWarning: false) == nil)
        #expect(presenter.lag(isWarning: true)?.kind == .latency, "re-armed once it cleared")

        var slot = NoticeSlot()
        func at(_ s: Double) -> Date { Self.t0.addingTimeInterval(s) }
        slot.setLive(.penalty, text: "Turn · 15s / 30s", at: at(0))
        #expect(slot.current(at: at(0))?.kind == .penalty)
        slot.post(.latency, RuleWords.lag, at: at(1))
        for t in stride(from: 1.0, through: 136, by: 5) {
            slot.setLive(.penalty, text: "Turn · \(Int(136 - t))s", at: at(t))
            #expect(slot.current(at: at(t))?.kind == .penalty)
        }
        #expect(NoticeTable.rule(.latency).priority < NoticeTable.rule(.penalty).priority, "it never covers a turn")
        slot.setLive(.penalty, text: nil, at: at(136))
        #expect(slot.current(at: at(136))?.text == RuleWords.lag, "three turns later, still shown")

    }

    /// A rule's first call against you always spells it out with the penalty line (#23), even after a call of it in your
    /// favour already spelled it out; a later call against you is badge only.
    @Test func firstCallAgainstYouCarriesThePenaltyLineAfterOneForYou() throws {
        let me = Self.me
        var presenter = RaceEventPresenter(me: me)
        let forMe = Self.show([Self.call(offender: 1, victim: me, incident: 1)], on: &presenter)
        let forText = try #require(forMe.notices.first?.text)
        #expect(forText.contains(RuleWords.plain(.portStarboard)) && !forText.contains(RuleWords.penaltyLine))

        let against = Self.show([Self.call(offender: me, victim: 1, incident: 2)], on: &presenter)
        let text = try #require(against.notices.first?.text)
        #expect(text.contains(RuleWords.plain(.portStarboard)) && text.contains("(rule 10)"), "\(text)")
        #expect(text.contains(RuleWords.penaltyLine), "\(text)")
        #expect(Self.show([Self.call(offender: me, victim: 2, incident: 3)], on: &presenter).notices.isEmpty)
        #expect(Self.show([Self.call(offender: 2, victim: me, incident: 4)], on: &presenter).notices.isEmpty)
    }

    /// Plain words are seen only once they show (#23): a call the slot drops stale behind others (#114) leaves its rule
    /// unseen, and the next call of it spells it out.
    @Test func plainWordsTheSlotDropsLeaveTheRuleUnseen() throws {
        let store = RuleSeenStore()
        let session = GameSession(config: Self.config, rulesSeen: store)
        var time = Self.pastStartHint(session)
        session.now = { time }
        let me = session.driver.myBoatIndex
        let (one, two) = ((me + 1) % 3, (me + 2) % 3)
        // OCS shows for 6 s; the rule 11 call waits, then shows; the rule 10 call waits past its 6 s and is dropped.
        session.consume([Self.event(.ocsNotice(recipient: me)), Self.call(.windwardLeeward, offender: one, victim: me),
                         Self.call(offender: two, victim: me, incident: 2)])
        #expect(session.notice?.kind == .ocs)
        #expect(!store.hasSeen(.rule(.windwardLeeward)), "not seen while it waits")
        time += 6
        session.refreshHUD()
        #expect(session.notice?.text.contains("(rule 11)") == true, "\(String(describing: session.notice))")
        #expect(store.hasSeen(.rule(.windwardLeeward)))
        time += 6
        session.refreshHUD()
        #expect(session.notice == nil, "the rule 10 call went stale: \(String(describing: session.notice))")
        #expect(!store.hasSeen(.rule(.portStarboard)), "dropped unshown, so unseen")

        session.consume([Self.call(offender: two, victim: me, incident: 3)])
        #expect(session.notice?.text.contains(RuleWords.plain(.portStarboard)) == true)
        #expect(store.hasSeen(.rule(.portStarboard)))
    }

    /// The session feeds the driver's RTT warning (#68) to the presenter: one `.latency` notice as it starts.
    @Test func sessionPostsTheDriversLagWarningOnce() {
        let driver = FakeDriver(config: Self.config)
        let session = GameSession(driver: driver, roster: driver.practice.roster)
        let time = Self.pastStartHint(session)
        session.now = { time }
        session.refreshHUD()
        #expect(session.notice == nil)
        driver.lagWarning = true
        session.refreshHUD()
        #expect(session.notice?.kind == .latency && session.notice?.text == RuleWords.lag)
        let shown = session.notice?.id
        driver.lagWarning = true
        session.refreshHUD()
        #expect(session.notice?.id == shown, "one-shot while it lasts")
    }

    /// #228's words come from your boat's autohelm in the driver's frame as the call is consumed: holding, they show;
    /// with the rudder held off centre (no autohelm), the rule's plain words do.
    @Test func sessionReadsTheFramesAutohelmForKeepClearWords() throws {
        for holding in [true, false] {
            let driver = PracticeDriver(config: Self.config)
            let session = GameSession(driver: driver, roster: driver.roster)
            session.now = { Self.t0 }
            let me = driver.myBoatIndex
            // Hold the rudder off centre; then, for the autohelm, centre it again and let it capture.
            driver.submit(BoatInput(rudder: 1.0))
            driver.tick(5 * Race.dt + 1e-9)
            if holding {
                driver.submit(.neutral)
                driver.tick(5 * Race.dt + 1e-9)
            }
            _ = driver.drainEvents()
            #expect((driver.currentFrame.boats[me].autohelm != nil) == holding)
            session.consume([Self.call(offender: me, victim: (me + 1) % 3)])
            let text = try #require(session.notice?.text)
            #expect(text.contains(RuleWords.autohelmKeepClear) == holding, "\(text)")
            #expect(text.contains(RuleWords.plain(.portStarboard)) == !holding, "\(text)")
        }
    }

    /// A clock time after the start hint a new session posts on the wall clock has expired, with the slot cleared of it.
    private static func pastStartHint(_ session: GameSession) -> Date {
        let time = Date.now.addingTimeInterval(3_600)
        session.now = { time }
        session.refreshHUD()
        return time
    }

    /// A practice driver with an RTT warning you set: an online race's signal, without a server.
    @MainActor private final class FakeDriver: RaceDriver {
        let practice: PracticeDriver
        var lagWarning = false

        init(config: RaceConfig) { practice = PracticeDriver(config: config) }

        var myBoatIndex: Int { practice.myBoatIndex }
        var course: CourseLayout { practice.course }
        var venue: Venue { practice.venue }
        var boatClass: BoatClass { practice.boatClass }
        var isPausable: Bool { false }
        var currentFrame: TickFrame { practice.currentFrame }
        var previousFrame: TickFrame { practice.previousFrame }
        var alpha: Double { practice.alpha }
        func tick(_ dt: Double) -> [TickFrame] { practice.tick(dt) }
        func submit(_ input: BoatInput) { practice.submit(input) }
        func tap(_ tap: BoatTap) -> Bool { practice.tap(tap) }
        func drainEvents() -> [RaceEvent] { practice.drainEvents() }
    }

    /// The OCS notice is rule 29.1's, and no copy names a 360 or a 720 (#9).
    @Test func copyIsOneTurnAndOCSUnderRule29_1() {
        #expect(RuleWords.ocs.contains("29.1") && !RuleWords.ocs.contains("22"))
        let texts = RacingRule.allCases.flatMap { rule in
            [true, false].map { RuleWords.firstCall(rule, against: $0, other: "Boat 2", owesTurn: true) }
        } + [RuleWords.firstMarkTouch("pin"), RuleWords.ocs, RuleWords.lag]
        for text in texts { #expect(!text.contains("360") && !text.contains("720") && !text.contains("spin"), "\(text)") }
    }
}
