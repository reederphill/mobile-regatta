import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// The queue from the Race online tap to the briefing (#140): the bar's states, the lock banner's haptic, the takeover,
/// leaving, the background, a lost connection and the refusals.
@MainActor @Suite struct QueueControllerTests {
    final class FakeClock {
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        func advance(_ seconds: Double) { date.addTimeInterval(seconds) }
    }

    final class RecordingHaptics: Haptics {
        var impacts: [Double] = []
        func impact(intensity: Double) { impacts.append(intensity) }
        func notify(_ kind: HapticNotification) {}
    }

    /// A controller on a scenario's scripted queue and race session, an app model as its host, a clock the test moves
    /// (`tick()` by hand) and what it said to the haptics, VoiceOver and `OnlineStatus`.
    @MainActor final class Rig {
        let clock: FakeClock
        let haptics = RecordingHaptics()
        let model: AppModel
        let services: ServiceSet
        let controller: QueueController
        /// The race sequence the takeover hands over to (#141), on scripted links.
        let race: OnlineRaceController
        private(set) var links: [ScriptedRaceLink] = []
        var announced: [String] = []
        var states: [QueueState] = []

        init(_ scenario: FakeServiceScenario = .joinable, raceSession: (any RaceSessionService)? = nil, model: AppModel = AppModel()) {
            self.model = model
            let services = ServiceSet.fake(scenario)
            self.services = services
            let clock = FakeClock()
            self.clock = clock
            race = OnlineRaceController(raceSession: raceSession ?? services.raceSession, makeLink: { _ in ScriptedRaceLink() },
                                        now: { clock.date }, sleep: { _ in }, tickInterval: nil)
            controller = QueueController(queue: services.queue, raceSession: raceSession ?? services.raceSession,
                                         sequence: race, now: { clock.date }, tickInterval: nil)
            race.queue = controller
            race.attach(host: model)
            race.makeLink = { [unowned self] _ in
                let link = ScriptedRaceLink()
                links.append(link)
                return link
            }
            controller.attach(host: model, haptics: haptics)
            controller.announce = { [unowned self] in self.announced.append($0) }
            controller.onState = { [unowned self] in self.states.append($0) }
        }

        func queued(_ players: Int, _ seconds: Int) async {
            await controller.receive(.queued(QueuedStatus(queuedPlayers: players, secondsToLock: seconds)))
        }

        /// Joined and waiting with three others, 25 s to the lock.
        func joinAndWait() async {
            await controller.join()
            await queued(4, 25)
        }

        /// Through fleet lock, into the briefing.
        func lock() async {
            await joinAndWait()
            await controller.receive(.fleetLocked)
        }

        func display() -> QueueBarState.Display? { controller.bar?.display(at: clock.date) }
    }

    private static let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    @Test func joinShowsJoiningThenQueued() async {
        let rig = Rig()
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        await rig.controller.join()
        #expect(rig.controller.bar == .joining)
        #expect(rig.controller.entry == .queued, "the bar stands in for Race online")
        #expect(rig.display()?.title == "Joining" && rig.display()?.canLeave == false)
        // The stream's idle, read before the join landed, changes nothing.
        await rig.controller.receive(.idle)
        #expect(rig.controller.bar == .joining)

        await rig.queued(3, 25)
        #expect(rig.controller.bar == .waiting(players: 3, lockAt: rig.clock.date.addingTimeInterval(25)))
        #expect(rig.announced == ["Joined the queue"])
        #expect(rig.model.notice == nil)

        // A join that hears nothing back gives up after 8 s.
        let silent = Rig()
        await silent.controller.join()
        silent.clock.advance(7.5)
        silent.controller.tick()
        #expect(silent.controller.bar == .joining)
        silent.clock.advance(0.5)
        silent.controller.tick()
        #expect(silent.controller.bar == nil && silent.controller.entry == .ready)
        #expect(silent.model.notice == .couldNotJoin)
    }

    @Test func aloneAndOthersAndHoldReadDifferently() async {
        let rig = Rig()
        await rig.controller.join()
        await rig.queued(3, 42)
        #expect(rig.display() == QueueBarState.Display(kind: .others, title: "In the queue", detail: "3 waiting", seconds: "42 s",
                                                       chip: "3 · 42 s", spoken: "Queued, 3 waiting, 42 seconds"))
        #expect(rig.display()?.canLeave == true && rig.display()?.isBanner == false)
        // The seconds count down on the device between pushes.
        rig.clock.advance(2)
        #expect(rig.display()?.seconds == "40 s")

        await rig.queued(1, 40)
        #expect(rig.display()?.kind == .alone)
        #expect(rig.display()?.detail == "Just you" && rig.display()?.seconds == "40 s")

        // Only a hold waits more than a minute: it says so, keeps the count, and shows no seconds until it is down to 60.
        await rig.queued(3, 150)
        #expect(rig.display() == QueueBarState.Display(kind: .hold, title: "Waiting for finishers", detail: "3 waiting",
                                                       chip: "3 · waiting", spoken: "Queued, waiting for finishers, 3 waiting"))
        #expect(rig.display()?.canLeave == true && rig.display()?.isBanner == false)
        rig.clock.advance(90)
        #expect(rig.display()?.kind == .others && rig.display()?.seconds == "60 s")
        // The hold moves the lock back again: the seconds hide again.
        await rig.queued(3, 75)
        #expect(rig.display()?.kind == .hold && rig.display()?.seconds == nil)
        // Alone in a hold, the count still reads as it does alone.
        await rig.queued(1, 75)
        #expect(rig.display()?.title == "Waiting for finishers" && rig.display()?.detail == "Just you")
    }

    @Test func lockSoonHapticFiresOnceAndRearmsOnlyAfterTwentySeconds() async {
        let rig = Rig()
        await rig.joinAndWait()
        rig.clock.advance(14)
        rig.controller.tick()
        #expect(rig.haptics.impacts.isEmpty && rig.display()?.kind == .others)
        rig.clock.advance(1)
        rig.controller.tick()
        #expect(rig.haptics.impacts == [0.4], "one light haptic 10 s before the lock")
        #expect(rig.display()?.isBanner == true && rig.display()?.title == "Race in 10" && rig.display()?.canLeave == true)
        #expect(rig.announced.last == "Race in 10 seconds")
        rig.clock.advance(3)
        rig.controller.tick()
        // The lock moves back a little, and comes close again: no second haptic.
        await rig.queued(4, 18)
        #expect(rig.display()?.isBanner == false)
        rig.clock.advance(9)
        rig.controller.tick()
        #expect(rig.haptics.impacts == [0.4])
        // A hold moves it back past 20 s: the banner's haptic comes again.
        await rig.queued(4, 45)
        rig.clock.advance(36)
        rig.controller.tick()
        #expect(rig.haptics.impacts == [0.4, 0.4])
        // A push that lands inside the last 10 s fires it without waiting for a tick.
        let late = Rig()
        await late.controller.join()
        await late.queued(4, 8)
        #expect(late.haptics.impacts == [0.4])
    }

    @Test func lockingThenFleetLockedTakesOver() async {
        let rig = Rig()
        await rig.joinAndWait()
        await rig.queued(4, 0)
        #expect(rig.display()?.kind == .locking)
        #expect(rig.display()?.title == "Setting the fleet" && rig.display()?.canLeave == false)
        // Past zero on the device's clock it is still the fleet being set.
        rig.clock.advance(2)
        #expect(rig.display()?.kind == .locking)

        await rig.controller.receive(.fleetLocked)
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        #expect(rig.race.phase == .briefing && rig.links.count == 1, "the race sequence has it from here")
        #expect(rig.model.phase == .raceSequence)
        #expect(rig.model.briefing?.isFleetLocked == true)
        #expect(rig.haptics.impacts.last == 1, "a heavy haptic at the lock")
        #expect(rig.announced.last == "Fleet set, briefing")
        #expect(!rig.controller.showsChip)
    }

    @Test func takeOverDismissesPagesSheetsAndDropsAPracticeRaceWithNoResults() async throws {
        let rig = Rig()
        await rig.joinAndWait()
        rig.model.path = [.settings]
        rig.model.startRaceSequence(GameSession(config: Self.config))
        rig.model.sheet = .boatCard(LobbyAuthor(gamePlayerID: GamePlayerID("G:fake-2"), nickname: "Wren", rating: Rating(value: 1610, isProvisional: false),
                                                chip: LiveryChip(deck: SwatchID("charcoal"), sail: SwatchID("white"))))
        let lastRace = rig.model.lastRace
        #expect(rig.model.isPracticeShowing && rig.controller.showsChip, "the chip rides over the practice race")

        await rig.controller.receive(.fleetLocked)
        #expect(rig.model.path.isEmpty && rig.model.sheet == nil)
        #expect(rig.model.phase == .raceSequence)
        guard case .briefing(let briefing, let config)? = rig.model.race else {
            Issue.record("the takeover shows \\(String(describing: rig.model.race))")
            return
        }
        let payload = FakeServiceScenario.briefing()
        #expect(briefing.isFleetLocked && briefing.mode == .online(seconds: 15))
        #expect(briefing.fleet.count == 6 && briefing.setup == payload.setup)
        #expect(config.seed == payload.setup.raceSeed.value && config.opponents == 5)
        #expect(rig.model.session == nil, "the practice race is gone")
        #expect(rig.model.lastRace == lastRace, "nothing of a race left midway is kept")
        #expect(!rig.model.isPracticeShowing)
    }

    /// A practice race she had finished when the fleet locked keeps its results as Home's Last race, as leaving it
    /// does; the takeover itself is the same.
    @Test func aFinishedPracticeRaceKeepsItsResultsRow() async throws {
        let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting", "-seed", "1"]))
        let rig = Rig(model: model)
        await rig.joinAndWait()
        model.beginPractice()
        model.finishBriefing()
        let session = try #require(model.session)
        session.playerDone = true
        #expect(model.lastRace == nil && rig.controller.showsChip)

        await rig.controller.receive(.fleetLocked)
        let kept = try #require(model.lastRace, "the race she was done in left no results row")
        #expect(kept.rows.count == model.practiceSetup.fleetSize)
        #expect(kept.isFinal, "closed as it was left, as Leave race closes it")
        #expect(model.session == nil && model.briefing?.isFleetLocked == true)
    }

    @Test func takeOverLocksTheLivery() async {
        let rig = Rig()
        #expect(!rig.model.isLiveryLocked)
        await rig.lock()
        #expect(rig.model.isLiveryLocked && rig.model.myBoat.isFleetLocked)

        // The briefing's Leave asks first; Stay keeps the seat.
        rig.race.askToLeave()
        #expect(rig.race.isConfirmingLeave)
        rig.race.stay()
        #expect(!rig.race.isConfirmingLeave && rig.model.phase == .raceSequence)

        rig.race.askToLeave()
        rig.race.leaveRace()
        #expect(rig.model.phase == .home && rig.model.race == nil)
        #expect(!rig.model.isLiveryLocked)
        #expect(rig.race.phase == .idle && rig.model.notice == nil)
        // Race online is off, wordless, until the server says where she stands: 3 s at most.
        #expect(rig.controller.entry == .settling)
        rig.clock.advance(3)
        rig.controller.tick()
        #expect(rig.controller.entry == .ready)

        // Or as soon as the server says: here, the cooldown.
        let third = Rig()
        await third.lock()
        third.race.leaveRace()
        await third.controller.receive(.unavailable(.cooldown(secondsRemaining: 300)))
        #expect(third.controller.entry == .ready)
        #expect(third.states.last == .unavailable(.cooldown(secondsRemaining: 300)), "Race online's line counts it down")
    }

    /// The briefing's own countdown ran out before the race link was up: the cover stays, joining (#141).
    @Test func briefingEndWithoutALinkStaysInTheCoverJoining() async {
        let rig = Rig()
        await rig.lock()
        rig.race.briefingEnded()
        #expect(rig.race.phase == .joining && rig.model.phase == .raceSequence && rig.model.isLiveryLocked)
        #expect(rig.model.notice == nil && rig.controller.entry == .ready)
    }

    @Test func cooldownCountsDownToReady() async {
        let rig = Rig(.cooldown)
        await rig.controller.receive(.unavailable(.cooldown(secondsRemaining: 20)))
        #expect(rig.states == [.unavailable(.cooldown(secondsRemaining: 20))])
        #expect(RestrictionLine(queue: rig.states[0], now: rig.clock.date)?.text(now: rig.clock.date.addingTimeInterval(8)) == "Cooling off 0:12")
        rig.clock.advance(19)
        rig.controller.tick()
        #expect(rig.states.count == 1)
        rig.clock.advance(1)
        rig.controller.tick()
        #expect(rig.states.last == .idle, "ready at zero, without the server's word")
        #expect(rig.model.notice == nil && rig.controller.entry == .ready)
        rig.controller.tick()
        #expect(rig.states.count == 2, "once")
    }

    @Test func suspensionAndAttestationAndUpdateLines() async {
        let refusals: [(FakeServiceScenario, QueueRefusal)] = [
            (.suspended, .suspended(until: FakeServiceScenario.suspendedUntil)), (.suspendedPermanent, .suspended(until: nil)),
            (.cannotRace, .attestationFailed), (.updateRequired, .updateRequired),
        ]
        for (scenario, refusal) in refusals {
            let rig = Rig(scenario)
            await rig.controller.receive(.unavailable(refusal))
            #expect(rig.controller.bar == nil && rig.controller.entry == .ready, "\\(scenario)")
            #expect(RestrictionLine(queue: rig.states[0], now: rig.clock.date) != nil, "\\(scenario): Race online says why")
            #expect(rig.model.notice == nil)
        }
    }

    @Test func refusedJoinLandsOnTheEntry() async {
        let rig = Rig(.cooldown)
        await rig.controller.join()
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        #expect(rig.states == [.unavailable(.cooldown(secondsRemaining: FakeServiceScenario.cooldownSeconds))])
        #expect(rig.model.notice == nil, "the line under Race online says it")
    }

    @Test func leaveFromTheBarGoesIdleAtOnce() async throws {
        let rig = Rig()
        await rig.joinAndWait()
        rig.controller.leave()
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready && rig.model.notice == nil)
        await rig.controller.leaving?.value
        // The queue heard: she can join again.
        try await rig.services.queue.join()
    }

    @Test func backgroundWhileQueuedLeavesAndPostsTheNotice() async throws {
        let rig = Rig()
        // The app's stand-in: what a background task holds open.
        var held = 0
        var sentWhileHeld = false
        rig.controller.whileAwake = { work in
            held += 1
            return Task {
                await work()
                // The queue has heard by the time the hold ends: a second leave is refused.
                do { try await rig.services.queue.leave() } catch QueueError.notQueued { sentWhileHeld = true } catch {}
                held -= 1
            }
        }
        await rig.joinAndWait()
        rig.controller.sceneChanged(isBackground: true)
        #expect(held == 1, "the leave runs under a background task")
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        #expect(rig.model.notice == AppModel.Notice(title: "You left the queue", message: "The app went to the background."))
        await rig.controller.leaving?.value
        #expect(held == 0 && sentWhileHeld, "the leave was sent before the hold ended")
        try await rig.services.queue.join()
        // Coming back changes nothing more.
        rig.controller.sceneChanged(isBackground: false)
        #expect(rig.controller.bar == nil)
    }

    /// Owner, 2026-10-11 (#147's ruling): after fleet lock the background is a drop, not a leave. Her seat is kept and
    /// she is back in the race if she returns before the gun.
    @Test func backgroundAfterLockKeepsTheSeat() async {
        let rig = Rig()
        await rig.lock()
        var held = 0
        rig.controller.whileAwake = { work in
            held += 1
            return Task { await work() }
        }
        rig.controller.sceneChanged(isBackground: true)
        rig.race.sceneChanged(isBackground: true)
        #expect(rig.race.phase == .briefing && rig.controller.leaving == nil && held == 0)
        #expect(rig.links.last?.drops == 1 && rig.links.last?.leaves == 0)
        #expect(rig.model.phase == .raceSequence && rig.model.briefing?.isFleetLocked == true)
        #expect(rig.model.isLiveryLocked && rig.model.notice == nil)
        rig.controller.sceneChanged(isBackground: false)
        #expect(rig.race.phase == .briefing)
    }

    @Test func connectionLostDropsTheQueueAndRegainPostsTheNotice() async {
        let rig = Rig()
        await rig.joinAndWait()
        rig.controller.connectionChanged(isOnline: false)
        #expect(rig.controller.bar == .connectionLost)
        #expect(rig.display()?.title == "Connection lost" && rig.display()?.canLeave == false)
        #expect(rig.model.notice == nil)
        // What the stream still says of the old place is ignored: no silent re-queue.
        await rig.queued(4, 20)
        await rig.controller.receive(.fleetLocked)
        #expect(rig.controller.bar == .connectionLost && rig.model.phase == .home)

        rig.controller.connectionChanged(isOnline: true)
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        #expect(rig.model.notice == AppModel.Notice(title: "You left the queue", message: "The connection dropped."))
    }

    @Test func connectionLostInTheTakeoverKeepsTheBriefing() async {
        let rig = Rig()
        await rig.lock()
        rig.controller.connectionChanged(isOnline: false)
        rig.race.connectionChanged(isOnline: false)
        rig.clock.advance(1.5)
        rig.race.tick()
        #expect(!rig.race.isReconnecting)
        rig.clock.advance(0.5)
        rig.race.tick()
        #expect(rig.race.isReconnecting, "the line after 2 s")
        #expect(rig.model.phase == .raceSequence && rig.model.briefing?.isFleetLocked == true)
        rig.controller.connectionChanged(isOnline: true)
        rig.race.connectionChanged(isOnline: true)
        #expect(!rig.race.isReconnecting)
        #expect(rig.model.phase == .raceSequence && rig.model.notice == nil)
    }

    @Test func staleFleetLockedAfterLeavingIsIgnored() async {
        let rig = Rig()
        await rig.joinAndWait()
        rig.controller.leave()
        // The server hadn't heard yet.
        await rig.queued(4, 3)
        #expect(rig.controller.bar == nil, "the bar doesn't come back")
        await rig.controller.receive(.fleetLocked)
        #expect(rig.model.phase == .home && rig.race.phase == .idle)
        #expect(rig.haptics.impacts.isEmpty)

        // And after leaving a locked fleet, its lock said again is no new one.
        let locked = Rig()
        await locked.lock()
        locked.race.leaveRace()
        await locked.controller.receive(.fleetLocked)
        #expect(locked.model.phase == .home && locked.race.phase == .idle)
    }

    @Test func raceAgainJoinsThroughTheController() async {
        let rig = Rig()
        rig.model.path = [.settings]
        rig.model.startRaceSequence(GameSession(config: Self.config))
        await rig.controller.raceAgain()
        #expect(rig.model.phase == .home && rig.model.path.isEmpty)
        #expect(rig.controller.bar == .joining, "home, with the queue joining")

        // A refusal lands on Race online's line.
        let refused = Rig(.suspended)
        refused.model.startRaceSequence(GameSession(config: Self.config))
        await refused.controller.raceAgain()
        #expect(refused.model.phase == .home && refused.controller.bar == nil)
        #expect(refused.states == [.unavailable(.suspended(until: FakeServiceScenario.suspendedUntil))])
    }

    @Test func handOffWithoutBriefingGoesHomeWithANotice() async {
        let bare = ScriptedRaceSessionService(RaceSessionScenario(handOff: HandOff(raceID: RaceID("r"), token: RaceToken(bytes: [1]))))
        for session in [bare, ScriptedRaceSessionService(RaceSessionScenario())] {
            let rig = Rig(raceSession: session)
            await rig.lock()
            #expect(rig.model.phase == .home && rig.race.phase == .idle)
            #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
            #expect(rig.model.notice == AppModel.Notice(title: "Couldn't start the race", message: "Try Race online again."))
            #expect(!rig.model.isLiveryLocked)
        }
    }

    /// A gate refusal while queued (signed out of Game Center, say): out of the queue, and Home says so.
    @Test func aRefusalWhileQueuedLeavesTheQueue() async {
        let rig = Rig()
        await rig.joinAndWait()
        await rig.controller.receive(.unavailable(.notSignedIn))
        #expect(rig.controller.bar == nil && rig.model.notice == .leftQueue)
    }
}

/// The online session under the queue (#162): her place lives on its connection.
extension QueueControllerTests {
    @Test func sessionLostWhileQueuedIsAConnectionLoss() async {
        let rig = Rig()
        // Not open while she waits for nothing: nothing to lose.
        rig.controller.sessionChanged(isOpen: false)
        rig.controller.sessionChanged(isOpen: true)
        #expect(rig.controller.bar == nil && rig.model.notice == nil)

        await rig.joinAndWait()
        rig.controller.sessionChanged(isOpen: false)
        #expect(rig.controller.bar == .connectionLost)
        #expect(rig.display()?.title == "Connection lost" && rig.display()?.canLeave == false)
        #expect(rig.model.notice == nil)
        // The device's path going as well changes nothing more.
        rig.controller.connectionChanged(isOnline: false)
        #expect(rig.controller.bar == .connectionLost && rig.model.notice == nil)
    }

    @Test func sessionBackAfterALossPostsLeftTheQueue() async {
        let rig = Rig()
        await rig.joinAndWait()
        rig.controller.sessionChanged(isOpen: false)
        // What the new connection's stream says of the queue is no place of hers: no silent re-queue.
        await rig.queued(4, 20)
        #expect(rig.controller.bar == .connectionLost)
        rig.controller.sessionChanged(isOpen: true)
        #expect(rig.controller.bar == nil && rig.controller.entry == .ready)
        #expect(rig.model.notice == AppModel.Notice(title: "You left the queue", message: "The connection dropped."))
    }
}
