import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// When hints show and stop (#23, #129): one at a time, at least 3 s apart, held behind rule calls and OCS, retired
/// once learned or shown twice, per device, with Reset hints and Hints off.
@MainActor @Suite struct HintSchedulerTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// Posts `id` to `slot` at `time` as the session does, and settles it there.
    private static func post(_ id: HintID, _ slot: inout NoticeSlot, _ scheduler: inout HintScheduler, at time: Date,
                             progress: HintProgressStore) {
        let noticeID = slot.nextID
        slot.post(.hint, id.rawValue, at: time)
        scheduler.posted(id, noticeID: noticeID)
        _ = scheduler.settle(slot: slot, now: time, progress: progress)
    }

    /// Advances `slot` to `time` and settles the scheduler there; returns what the settle retired.
    @discardableResult private static func advance(_ slot: inout NoticeSlot, _ scheduler: inout HintScheduler,
                                                   to time: Date, progress: HintProgressStore) -> HintID? {
        _ = slot.current(at: time)
        return scheduler.settle(slot: slot, now: time, progress: progress)
    }

    @Test func spacingAtLeast3s() {
        let progress = HintProgressStore()
        var slot = NoticeSlot()
        var scheduler = HintScheduler()
        let eligible: [HintID] = [.raceStart, .puff]
        #expect(scheduler.pick(eligible, slot: slot, now: Self.t0, hintsOn: true, progress: progress) == .raceStart)
        Self.post(.raceStart, &slot, &scheduler, at: Self.t0, progress: progress)
        // One at a time: nothing while it shows.
        #expect(scheduler.pick(eligible, slot: slot, now: Self.at(1), hintsOn: true, progress: progress) == nil)
        // About 4 s each.
        #expect(NoticeTable.rule(.hint).seconds == 4)
        Self.advance(&slot, &scheduler, to: Self.at(4), progress: progress)
        #expect(slot.showing == nil)
        for t in stride(from: 4.0, to: 7, by: 0.25) {
            #expect(scheduler.pick(eligible, slot: slot, now: Self.at(t), hintsOn: true, progress: progress) == nil,
                    "\(t) s: within 3 s of the last hint going")
        }
        #expect(scheduler.pick(eligible, slot: slot, now: Self.at(7), hintsOn: true, progress: progress) == .raceStart)
        #expect(scheduler.pick([.puff], slot: slot, now: Self.at(7), hintsOn: true, progress: progress) == .puff)
    }

    @Test func heldBehindRuleCall() {
        let progress = HintProgressStore()
        for kind in [NoticeKind.ruleCall, .ocs] {
            var slot = NoticeSlot()
            var scheduler = HintScheduler()
            slot.post(kind, "foul", at: Self.t0)
            // While it shows...
            for t in stride(from: 0.0, to: 6, by: 0.5) {
                Self.advance(&slot, &scheduler, to: Self.at(t), progress: progress)
                #expect(scheduler.pick([.raceStart], slot: slot, now: Self.at(t), hintsOn: true, progress: progress) == nil)
            }
            // ...and while one waits behind another notice.
            slot.post(.ocs, "over", at: Self.at(5))
            slot.post(.ruleCall, "foul", at: Self.at(5.5))
            #expect(slot.waiting.contains { $0.kind == .ruleCall })
            #expect(scheduler.pick([.raceStart], slot: slot, now: Self.at(5.5), hintsOn: true, progress: progress) == nil)
            Self.advance(&slot, &scheduler, to: Self.at(11), progress: progress)
            #expect(slot.showing?.kind == .ruleCall)
            #expect(scheduler.pick([.raceStart], slot: slot, now: Self.at(11), hintsOn: true, progress: progress) == nil)
            Self.advance(&slot, &scheduler, to: Self.at(17), progress: progress)
            #expect(slot.showing == nil)
            #expect(scheduler.pick([.raceStart], slot: slot, now: Self.at(17), hintsOn: true, progress: progress)
                    == .raceStart, "\(kind)")
        }
    }

    @Test func retiresAfterTwoShows() {
        let progress = HintProgressStore()
        var slot = NoticeSlot()
        var scheduler = HintScheduler()
        Self.post(.puff, &slot, &scheduler, at: Self.t0, progress: progress)
        // A hint replaced by OCS and shown again counts once.
        slot.post(.ocs, "over", at: Self.at(1))
        Self.advance(&slot, &scheduler, to: Self.at(1), progress: progress)
        #expect(Self.advance(&slot, &scheduler, to: Self.at(7), progress: progress) == nil)
        #expect(slot.showing?.kind == .hint)
        #expect(progress.timesShown(.puff) == 1)
        Self.advance(&slot, &scheduler, to: Self.at(11), progress: progress)
        #expect(scheduler.tracked == nil)
        #expect(!progress.isRetired(.puff))

        Self.post(.puff, &slot, &scheduler, at: Self.at(20), progress: progress)
        #expect(progress.timesShown(.puff) == 2)
        #expect(progress.isRetired(.puff))
        Self.advance(&slot, &scheduler, to: Self.at(24), progress: progress)
        #expect(scheduler.pick([.puff], slot: slot, now: Self.at(40), hintsOn: true, progress: progress) == nil)

        // The engine tells analytics once, as the second showing retires it.
        let engine = HintEngine(progress: HintProgressStore())
        var told: [(HintID, HintRetirement)] = []
        engine.onRetired = { told.append(($0, $1)) }
        var scheduler2 = HintScheduler()
        var slot2 = NoticeSlot()
        for start in [0.0, 10] {
            let noticeID = slot2.nextID
            slot2.post(.hint, "puff", at: Self.at(start))
            scheduler2.posted(.puff, noticeID: noticeID)
            if let retired = scheduler2.settle(slot: slot2, now: Self.at(start), progress: engine.progress) {
                engine.onRetired?(retired, .shownTwice)
            }
            Self.advance(&slot2, &scheduler2, to: Self.at(start + 5), progress: engine.progress)
        }
        #expect(told.map(\.0) == [.puff] && told.map(\.1) == [.shownTwice])
    }

    /// A hint that waits behind rule calls until it goes stale never showed: it isn't counted.
    @Test func aHintDroppedStaleIsNotCounted() {
        let progress = HintProgressStore()
        var slot = NoticeSlot()
        var scheduler = HintScheduler()
        slot.post(.ruleCall, "foul", at: Self.t0)
        Self.post(.puff, &slot, &scheduler, at: Self.t0, progress: progress)
        for t in stride(from: 0.0, to: 66, by: 3) {
            slot.post(.ruleCall, "foul", at: Self.at(t))
            Self.advance(&slot, &scheduler, to: Self.at(t), progress: progress)
            #expect(slot.showing?.kind != .hint)
        }
        #expect(scheduler.tracked == nil)
        #expect(progress.timesShown(.puff) == 0)
    }

    @Test func retiresOnLearned() {
        let progress = HintProgressStore()
        let engine = HintEngine(progress: progress)
        var told: [(HintID, HintRetirement)] = []
        engine.onRetired = { told.append(($0, $1)) }
        let me = 2
        // Someone else's tack teaches you nothing.
        engine.consume([RaceEvent(tick: 0, kind: .tacked(seat: 1))], me: me, hintsOn: true)
        #expect(!progress.isRetired(.noGo))
        // Learned before it ever showed: a player who already tacks never needs it.
        engine.consume([RaceEvent(tick: 1, kind: .tacked(seat: me))], me: me, hintsOn: true)
        #expect(progress.isLearned(.noGo))
        engine.consume([RaceEvent(tick: 2, kind: .tacked(seat: me))], me: me, hintsOn: true)
        engine.consume([RaceEvent(tick: 3, kind: .rounded(seat: me, mark: "W"))], me: me, hintsOn: true)
        engine.consume([RaceEvent(tick: 4, kind: .grooveSnap(seat: me))], me: me, hintsOn: true)
        #expect(told.map(\.0) == [.noGo, .markZone, .lettingGo])
        #expect(told.allSatisfy { $0.1 == .learned })
        let slot = NoticeSlot()
        #expect(engine.scheduler.pick([.noGo, .markZone, .lettingGo], slot: slot, now: Self.t0, hintsOn: true,
                                      progress: progress) == nil)
        // Already shown twice: learning it later retires nothing more.
        progress.markShown(.layline)
        progress.markShown(.layline)
        #expect(!HintScheduler().learn(.layline, hintsOn: true, progress: progress))
    }

    @Test func resetRestoresAndOffSuppresses() throws {
        let name = "HintSchedulerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let progress = HintProgressStore(defaults: defaults)
        let scheduler = HintScheduler()
        let slot = NoticeSlot()
        progress.markShown(.raceStart)
        progress.markShown(.raceStart)
        progress.markLearned(.noGo)
        #expect(progress.isRetired(.raceStart) && progress.isRetired(.noGo))
        // Per device: a new store over the same defaults reads it.
        #expect(HintProgressStore(defaults: defaults).isRetired(.raceStart))
        #expect(scheduler.pick([.raceStart, .noGo], slot: slot, now: Self.t0, hintsOn: true, progress: progress) == nil)

        DeviceSettings.resetHints(in: defaults)
        #expect(progress.timesShown(.raceStart) == 0 && !progress.isLearned(.noGo))
        #expect(scheduler.pick([.raceStart, .noGo], slot: slot, now: Self.t0, hintsOn: true, progress: progress)
                == .raceStart)
        // Hints off: none picked, and nothing is learned meanwhile.
        #expect(scheduler.pick([.raceStart, .noGo], slot: slot, now: Self.t0, hintsOn: false, progress: progress) == nil)
        #expect(!scheduler.learn(.noGo, hintsOn: false, progress: progress))
        #expect(!progress.isLearned(.noGo))
    }

    /// The session posts the steering hint at once (the first race's "within 2 s", #129), in the scheme in use, and
    /// none with Hints off.
    @Test func sessionPostsTheSteeringHintAtOnceAndNoneWithHintsOff() {
        let config = RaceConfig(opponents: 2, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        for steering in DeviceSettings.Steering.allCases {
            let session = GameSession(config: config, controls: ControlSettings(steering: steering),
                                      hints: HintEngine(progress: HintProgressStore()))
            #expect(session.notice?.kind == .hint)
            #expect(session.notice?.text == HintCatalogue.hint(.raceStart).text.text(for: steering))
        }
        let off = GameSession(config: config, controls: ControlSettings(showsHints: false),
                              hints: HintEngine(progress: HintProgressStore()))
        #expect(off.notice == nil)
        // No engine (tests, fixtures): no hint either.
        #expect(GameSession(config: config).notice == nil)
    }

    /// A session's hint retirements reach `onHintRetired` with the catalogue's id (#128).
    @Test func sessionForwardsRetirements() {
        let config = RaceConfig(opponents: 2, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let session = GameSession(config: config, hints: HintEngine(progress: HintProgressStore()))
        var told: [String] = []
        session.onHintRetired = { hint, mode in told.append("\(hint) \(mode.rawValue)") }
        session.consume([RaceEvent(tick: 1, kind: .tacked(seat: session.driver.myBoatIndex))])
        #expect(told == ["no_go learned"])
    }
}
