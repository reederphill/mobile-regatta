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

    /// The start-sequence hint says how this scheme eases (#453): there is no Ease button.
    @Test func startSequenceHintSaysHowThisSchemeEases() {
        let text = HintCatalogue.hint(.startSequence).text
        #expect(text.text(for: .halves) == "Hold both sides to ease.")
        #expect(text.text(for: .tiller) == "Pull down to ease.")
        for steering in DeviceSettings.Steering.allCases {
            #expect(!text.text(for: steering).contains("Hold Ease"), "no Ease button to hold")
        }
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

    /// A fresh session posts the steering hint at tick 0, before the clock shows, and it is still up however long the
    /// scene takes to start: its 4 s run from the race's first frame (`sceneStarted`), then it goes for the race (the
    /// first race's "within 2 s" UI test, #129, where launching took longer than the hint's 4 s).
    @Test func theSteeringHintPostedAtSetUpShowsItsTimeOnceTheSceneStarts() throws {
        let config = RaceConfig(opponents: 2, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let session = GameSession(config: config, hints: HintEngine(progress: HintProgressStore()))
        let steering = HintCatalogue.hint(.raceStart).text.text(for: session.controls.steering)
        #expect(session.driver.currentFrame.time == -30, "set up, nothing stepped")
        #expect(session.notice?.kind == .hint && session.notice?.text == steering)
        #expect(steering.contains("Settings"))

        // The scene's first frame comes 10 s after setting up: the hint is still up, for its full time from there.
        var time = Date.now.addingTimeInterval(10)
        session.now = { time }
        session.sceneStarted()
        session.refreshHUD()
        #expect(session.notice?.text == steering, "\(String(describing: session.notice))")
        time += 3.9
        session.refreshHUD()
        #expect(session.notice?.text == steering)
        time += 0.2
        session.refreshHUD()
        #expect(session.notice?.text != steering, "gone after its 4 s")
        // Once a race: not again, and a later sceneStarted (the scene can't restart) changes nothing.
        for _ in 0..<40 {
            time += 0.5
            session.sceneStarted()
            session.refreshHUD()
            #expect(session.notice?.text != steering)
        }
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

    // MARK: The engine end to end

    /// A practice race whose hints run as `GameSession.refreshHints` runs them: the driver ticked at 15 Hz on a test
    /// clock, its events fed in, the slot advanced, and each hint the engine returns posted.
    @MainActor final class Rig {
        let driver: PracticeDriver
        let engine: HintEngine
        var slot = NoticeSlot()
        var clock = HintSchedulerTests.t0
        var hintsOn = true
        var isFirstRace = false
        var rudder = 0.0
        /// Each hint posted, with the race time it posted at.
        private(set) var posts: [(id: HintID, time: Double)] = []
        private(set) var retired: [(id: HintID, mode: HintRetirement)] = []

        init(progress: HintProgressStore, prestartSeconds: Double = 10, catalogue: [Hint] = HintCatalogue.engine,
             isFirstRaceOnDevice: Bool = false, files: PracticeFiles = .defaults) {
            var config = RaceConfig(opponents: 2, prestartSeconds: prestartSeconds, seed: 1,
                                    windSeed: RaceConfig.windSeed(pinnedTo: 1))
            config.files = files
            driver = PracticeDriver(config: config)
            engine = HintEngine(progress: progress, catalogue: catalogue, isFirstRaceOnDevice: isFirstRaceOnDevice)
            engine.onRetired = { [unowned self] id, mode in retired.append((id, mode)) }
            refresh()
        }

        func posted(_ id: HintID) -> [Double] { posts.filter { $0.id == id }.map(\.time) }

        func run(_ seconds: Double) {
            for _ in 0..<Int((seconds * 15).rounded()) {
                driver.submit(BoatInput(rudder: rudder))
                driver.tick(1.0 / 15)
                clock = clock.addingTimeInterval(1.0 / 15)
                engine.consume(driver.drainEvents(), me: driver.myBoatIndex, hintsOn: hintsOn)
                refresh()
            }
        }

        func refresh() {
            _ = slot.current(at: clock)
            let next = engine.refresh(world: driver.renderWorld, slot: slot, now: clock, hintsOn: hintsOn,
                                      showsLaylines: true, isFirstRace: isFirstRace)
            if let held = engine.takeDownDue() {
                slot.takeDown(held, at: clock)
                _ = slot.current(at: clock)
            }
            guard let next else { return }
            let noticeID = slot.nextID
            slot.post(.hint, next.hint.id.rawValue, at: clock, leader: next.leader, held: next.held)
            engine.posted(next.hint.id, noticeID: noticeID, held: next.held)
            posts.append((next.hint.id, driver.renderWorld.time))
        }
    }

    /// The letting-go hint waits until it's relevant (owner ruling 2026-10-05): a first-race player who never steers
    /// never sees it, however long they sail; the held steering hint stays up meanwhile.
    @Test func handsOffFirstRaceNeverShowsLettingGo() {
        for isFirstRaceOnDevice in [true, false] {
            let progress = HintProgressStore()
            let rig = Rig(progress: progress, isFirstRaceOnDevice: isFirstRaceOnDevice)
            rig.isFirstRace = true
            rig.run(10 + 60)
            #expect(!rig.engine.observations.hasSteered)
            #expect(rig.posted(.lettingGo).isEmpty, "\(rig.posts)")
            #expect(!progress.isLearned(.lettingGo))
            #expect(rig.posted(.raceStart).count == 1)
        }
    }

    /// After the first steer takes the held steering hint down, letting go shows once you've steered without a break
    /// for the first race's threshold, and not before.
    /// On skiff@6 (#437): letting go is for a class whose autohelm holds a centred rudder; skiff@7's is centredRudder.
    @Test func firstRaceLettingGoShowsAfterTheFirstSteerAndTheSteeringThreshold() throws {
        let progress = HintProgressStore()
        let rig = Rig(progress: progress, isFirstRaceOnDevice: true, files: try HintTriggerTests.autohelmOnFiles())
        rig.isFirstRace = true
        rig.run(10 + 2)
        #expect(rig.slot.showing?.text == HintID.raceStart.rawValue)
        let firstSteer = rig.driver.renderWorld.time
        rig.rudder = Autohelm.deadBand + 0.05
        rig.run(0.5)
        #expect(rig.engine.heldNoticeID == nil, "the steering hint goes on the first steer")
        #expect(rig.posted(.lettingGo).isEmpty)
        rig.run(20)
        let shown = rig.posted(.lettingGo)
        #expect(shown.count == 1, "\(rig.posts)")
        let time = try #require(shown.first)
        #expect(time >= firstSteer + HintTuning.standard.lettingGoFirstRaceSeconds - 0.1, "letting go at \(time) s")
        #expect(rig.posts.filter { $0.id == .lettingGo || $0.id == .raceStart }.map(\.id) == [.raceStart, .lettingGo])
    }

    /// The device's first race is the engine's, whatever the session says (nothing sets `GameSession.isFirstRace`): on
    /// the default class (skiff@8, hand steering) the centred-rudder hint shows after the first race's 5 s of steering,
    /// not the later races' 20 s (#437).
    @Test func firstRaceOnDeviceShowsCentredRudderAfterFiveSecondsOfSteering() throws {
        let rig = Rig(progress: HintProgressStore(), isFirstRaceOnDevice: true)
        #expect(!rig.isFirstRace)
        rig.run(10 + 2)
        rig.rudder = Autohelm.deadBand + 0.05
        let firstSteer = rig.driver.renderWorld.time
        rig.run(12)
        let shown = rig.posted(.centredRudder)
        #expect(shown.count == 1, "\(rig.posts)")
        let time = try #require(shown.first)
        #expect(time >= firstSteer + HintTuning.standard.lettingGoFirstRaceSeconds - 0.1 && time < firstSteer + 12, "at \(time) s")
        #expect(rig.posted(.lettingGo).isEmpty)
    }

    /// A situation that lasts shows its hint once, not again at every gap: it shows again only after its trigger has
    /// been off for `rearmSeconds`. The steering hint shows once a race.
    @Test func aLastingSituationShowsItsHintOncePerEpisode() {
        final class Flag { var on = true }
        let flag = Flag()
        let lasting = Hint(id: .puff, delivery: .engine, text: HintText("puff"), isPlaceholderCopy: true,
                           learning: .never, trigger: { _, _ in flag.on ? HintFiring(leader: nil) : nil })
        let progress = HintProgressStore()
        let rig = Rig(progress: progress, prestartSeconds: 60, catalogue: [HintCatalogue.hint(.raceStart), lasting])
        rig.run(30)
        #expect(rig.posted(.raceStart).count == 1)
        #expect(rig.posted(.puff).count == 1, "\(rig.posts)")
        #expect(progress.timesShown(.puff) == 1)
        // Off for less than the re-arm time: still spent.
        flag.on = false
        rig.run(HintTuning.standard.rearmSeconds - 2)
        flag.on = true
        rig.run(10)
        #expect(rig.posted(.puff).count == 1)
        // Off long enough: a new episode shows it again (its second showing, which retires it).
        flag.on = false
        rig.run(HintTuning.standard.rearmSeconds + 1)
        flag.on = true
        rig.run(5)
        #expect(rig.posted(.puff).count == 2)
        #expect(rig.retired.filter { $0.id == .puff }.map(\.mode) == [.shownTwice])
        #expect(rig.posted(.raceStart).count == 1)
    }

    /// A hint learned by its showing (the centred-rudder hint, #436) shows once and retires as it shows, learned.
    @Test func aHintLearnedByShowingRetiresAsItShows() {
        let always = Hint(id: .centredRudder, delivery: .engine, text: HintText("centred"), isPlaceholderCopy: true,
                          learning: .shown, trigger: { _, _ in HintFiring(leader: nil) })
        let progress = HintProgressStore()
        let rig = Rig(progress: progress, prestartSeconds: 60, catalogue: [HintCatalogue.hint(.raceStart), always])
        rig.run(40)
        #expect(rig.posted(.centredRudder).count == 1, "\(rig.posts)")
        #expect(progress.isLearned(.centredRudder) && progress.timesShown(.centredRudder) == 1)
        #expect(rig.retired.filter { $0.id == .centredRudder }.map(\.mode) == [.learned])
    }

    /// Hints switched off and back on: nothing is observed meanwhile, and the next tick adds no long gap to the
    /// counters (or the wind smoothing).
    @Test func hintsOffThenOnAddsNoGap() {
        let rig = Rig(progress: HintProgressStore())
        rig.rudder = Autohelm.deadBand + 0.05
        rig.run(10 + 3)
        let steered = rig.engine.observations.steeringSeconds
        #expect(steered > 2)
        rig.hintsOn = false
        rig.run(20)
        #expect(rig.engine.observations.lastTick == nil)
        #expect(rig.engine.observations.steeringSeconds == steered)
        rig.hintsOn = true
        rig.run(1.0 / 15)
        #expect(rig.engine.observations.steeringSeconds - steered < 0.1)
    }

    /// Through `HintEngine.refresh` on a real race: the steering hint is picked, posted, counted as it shows and
    /// settled as it goes; its second showing (the next race) retires it and tells analytics once; steering both ways
    /// retires it as learned, once.
    @Test func refreshPicksPostsSettlesAndRetiresOnce() {
        let progress = HintProgressStore()
        let first = Rig(progress: progress)
        #expect(first.posted(.raceStart).count == 1)
        #expect(first.engine.scheduler.tracked?.id == .raceStart)
        // Counted on the refresh that sees it showing.
        #expect(progress.timesShown(.raceStart) == 0)
        first.run(1.0 / 15)
        #expect(progress.timesShown(.raceStart) == 1)
        first.run(5)
        #expect(first.engine.scheduler.tracked == nil && first.engine.scheduler.lastEnded != nil)
        #expect(first.retired.isEmpty)

        let second = Rig(progress: progress)
        second.run(1.0 / 15)
        #expect(progress.timesShown(.raceStart) == 2)
        second.run(20)
        #expect(second.posted(.raceStart).count == 1)
        #expect(second.retired.filter { $0.id == .raceStart }.map(\.mode) == [.shownTwice])

        let learner = Rig(progress: HintProgressStore())
        learner.rudder = 1
        learner.run(1)
        learner.rudder = -1
        learner.run(1)
        learner.run(3)
        #expect(learner.retired.filter { $0.id == .raceStart }.map(\.mode) == [.learned])
    }

    /// Hints off: the hint already posted still settles (counted, then let go), but nothing new is observed, learned
    /// or picked.
    @Test func hintsOffStillSettlesAndObservesNothing() {
        let progress = HintProgressStore()
        let rig = Rig(progress: progress)
        #expect(rig.engine.scheduler.tracked?.id == .raceStart)
        rig.hintsOn = false
        rig.rudder = 1
        rig.run(1)
        rig.rudder = -1
        rig.run(5)
        #expect(rig.engine.scheduler.tracked == nil)
        #expect(progress.timesShown(.raceStart) == 1)
        #expect(rig.engine.observations.lastTick == nil)
        #expect(!rig.engine.observations.steeredBothWays(.standard))
        #expect(!progress.isLearned(.raceStart))
        #expect(rig.posts.count == 1 && rig.retired.isEmpty)
    }

    // MARK: The first race's steering hint (owner ruling 2026-10-05)

    /// In the first race the steering hint stays up until you steer: 30 s of race time hands off and it is still the
    /// notice showing, counted once, with no other hint posted past it.
    @Test func firstRaceSteeringHintStaysWithoutInput() throws {
        let progress = HintProgressStore()
        let rig = Rig(progress: progress, isFirstRaceOnDevice: true)
        let held = try #require(rig.engine.heldNoticeID)
        for _ in 0..<(10 + 31) {
            rig.run(1)
            #expect(rig.slot.showing?.id == held && rig.slot.showing?.text == HintID.raceStart.rawValue,
                    "at \(rig.driver.renderWorld.time) s: \(String(describing: rig.slot.showing))")
        }
        #expect(rig.driver.renderWorld.time >= 30)
        #expect(!rig.engine.observations.hasSteered)
        #expect(progress.timesShown(.raceStart) == 1)
        #expect(rig.posts.map(\.id) == [.raceStart], "\(rig.posts)")
        #expect(rig.retired.isEmpty)
    }

    /// It goes on your first steer (a rudder just past the autohelm's dead band, one way), retires as learned, tells
    /// analytics once, and doesn't show in a later race.
    @Test func firstRaceSteeringHintGoesOnFirstSteerAndRetiresLearnedOnce() {
        let progress = HintProgressStore()
        let rig = Rig(progress: progress, isFirstRaceOnDevice: true)
        rig.run(10 + 5)
        #expect(rig.slot.showing?.text == HintID.raceStart.rawValue)
        rig.rudder = Autohelm.deadBand + 0.05
        #expect(rig.rudder < HintTuning.standard.steerRudderShare, "a first steer, not both ways")
        rig.run(0.5)
        #expect(rig.slot.showing?.text != HintID.raceStart.rawValue && rig.slot.waiting.isEmpty)
        #expect(rig.engine.heldNoticeID == nil)
        #expect(progress.isLearned(.raceStart))
        rig.rudder = 0
        rig.run(20)
        #expect(rig.posted(.raceStart).count == 1)
        #expect(rig.retired.filter { $0.id == .raceStart }.map(\.mode) == [.learned])
        // Other hints may follow once it has gone.
        #expect(rig.engine.scheduler.tracked?.id != .raceStart)

        let later = Rig(progress: progress)
        later.run(10 + 10)
        #expect(later.posted(.raceStart).isEmpty)
        #expect(!later.retired.contains { $0.id == .raceStart })
    }

    /// It gives way to a rule call or OCS notice and comes back after it, still held, not counted again.
    @Test func firstRaceSteeringHintYieldsToRuleCallsAndComesBack() {
        for kind in [NoticeKind.ruleCall, .ocs] {
            let progress = HintProgressStore()
            let rig = Rig(progress: progress, isFirstRaceOnDevice: true)
            rig.run(3)
            rig.slot.post(kind, "call", at: rig.clock)
            rig.run(1)
            #expect(rig.slot.showing?.kind == kind)
            rig.run(NoticeTable.rule(kind).seconds + 1)
            #expect(rig.slot.showing?.text == HintID.raceStart.rawValue, "\(kind): \(String(describing: rig.slot.showing))")
            rig.run(20)
            #expect(rig.slot.showing?.text == HintID.raceStart.rawValue)
            #expect(progress.timesShown(.raceStart) == 1)
            #expect(rig.posts.map(\.id) == [.raceStart])
        }
    }

    /// Later races keep the usual 4 s: an engine not told it's the first race shows the steering hint for its time.
    @Test func laterRaceSteeringHintShowsItsUsualTime() {
        let rig = Rig(progress: HintProgressStore())
        #expect(rig.engine.heldNoticeID == nil)
        rig.run(NoticeTable.rule(.hint).seconds + 0.5)
        #expect(rig.slot.showing?.text != HintID.raceStart.rawValue)
    }

    /// The app's engine is the first race's while the steering hint has never shown on the device; through a session,
    /// the hint stays up over 30 s of a hands-off race's refreshes.
    @Test func sessionHoldsTheFirstRaceSteeringHint() {
        let progress = HintProgressStore()
        #expect(HintEngine.isFirstRace(progress))
        let config = RaceConfig(opponents: 2, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let session = GameSession(config: config, hints: HintEngine(progress: progress, isFirstRaceOnDevice: true))
        let steering = HintCatalogue.hint(.raceStart).text.text(for: session.controls.steering)
        var time = Date.now
        session.now = { time }
        session.sceneStarted()
        for _ in 0..<(30 * 15) {
            time += 1.0 / 15
            session.refreshHUD()
            #expect(session.notice?.text == steering)
        }
        #expect(!HintEngine.isFirstRace(progress))
    }
}
