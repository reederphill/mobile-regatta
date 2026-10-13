import Foundation
import RegattaClient
import RegattaCore
import RegattaProtocol
import RegattaServices
import Testing
@testable import Regatta

/// A race link the test scripts (#141): what the controller reads of it is set by hand, and what it asked is counted.
@MainActor final class ScriptedRaceLink: RaceLinking {
    var status = RaceLinkStatus.joining
    var tick: Int?
    var ending: RaceClient.Ending?
    var isPlayerDone = false
    var wantsToken = false
    var launch: OnlineLaunch? { nil }
    var kept: RaceResultViewModel?
    private(set) var started = false
    private(set) var leaves = 0
    private(set) var drops = 0
    private(set) var closes = 0
    private(set) var provided: [RaceToken] = []

    func start() { started = true }
    func pump(isShown: Bool) {}
    func provide(_ token: RaceToken) {
        provided.append(token)
        wantsToken = false
    }
    func leave() async { leaves += 1 }
    func drop() {
        drops += 1
        status = .reconnecting
    }
    func close() { closes += 1 }
    func resultsToKeep() -> RaceResultViewModel? { kept }

    /// Joined, with the race clock at `tick`.
    func up(at tick: Int) {
        status = .up
        self.tick = tick
    }
}

/// Whether the fake host answers yet.
nonisolated final class AnsweringSwitch {
    var isOn = false
}

/// A connection to the fake host that has the host answer whenever the client looks, once `answers` is on: the
/// handshake needs no clock and no second task, however busy the main actor is with the suites beside this one.
nonisolated final class AnsweredConnection: RaceConnection {
    private let connection: FakeRaceConnection
    private let host: FakeRaceHost
    private let answers: AnsweringSwitch

    init(_ connection: FakeRaceConnection, host: FakeRaceHost, answers: AnsweringSwitch) {
        (self.connection, self.host, self.answers) = (connection, host, answers)
    }

    var isConnected: Bool {
        if answers.isOn { host.poll() }
        return connection.isConnected
    }

    func send(_ frame: [UInt8]) { connection.send(frame) }

    func receive() -> [[UInt8]] {
        if answers.isOn { host.poll() }
        return connection.receive()
    }

    func close() { connection.close() }
}

/// A race session the test changes as it goes.
nonisolated final class MutableRaceSession: RaceSessionService, @unchecked Sendable {
    var handOffAnswer: HandOff?
    var offer: RejoinOffer?
    var last: LastRace?
    private(set) var rejoinsAsked = 0
    private var ratings: [AsyncStream<RatingChange>.Continuation] = []

    func handOff() throws -> HandOff {
        guard let handOffAnswer else { throw RaceSessionError.noRace }
        return handOffAnswer
    }

    func rejoin() throws -> RejoinOffer {
        rejoinsAsked += 1
        guard let offer else { throw RaceSessionError.noRace }
        return offer
    }

    func results() -> AsyncStream<RaceUpdate> { AsyncStream { $0.finish() } }

    func ratingChanges() -> AsyncStream<RatingChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: RatingChange.self)
        ratings.append(continuation)
        return stream
    }

    func lastRace() -> LastRace? { last }

    func push(_ change: RatingChange) {
        for stream in ratings { stream.yield(change) }
    }
}

/// A queue that only counts: nothing answers, so a join stays "joining".
nonisolated final class CountingQueue: QueueService, @unchecked Sendable {
    private(set) var joins = 0
    func stateUpdates() -> AsyncStream<QueueState> { AsyncStream { _ in } }
    func join() { joins += 1 }
    func leave() {}
}

/// The queue's and the race sequence's controllers on one app model, a scripted link and a clock the test moves.
@MainActor final class SequenceRig {
    static let raceID = RaceID("fake-race")
    static let token = RaceToken(bytes: [0xF0, 0x0D])
    static let fresh = RaceToken(bytes: [0xFE])

    let clock = QueueControllerTests.FakeClock()
    let model = AppModel()
    let session = MutableRaceSession()
    let counting = CountingQueue()
    let race: OnlineRaceController
    let queue: QueueController
    private(set) var links: [ScriptedRaceLink] = []
    private(set) var handOffs: [HandOff] = []

    init() {
        let clock = clock
        session.handOffAnswer = HandOff(raceID: Self.raceID, token: Self.token, briefing: FakeServiceScenario.briefing())
        race = OnlineRaceController(raceSession: session, makeLink: { _ in ScriptedRaceLink() }, now: { clock.date },
                                    sleep: { _ in }, tickInterval: nil)
        queue = QueueController(queue: counting, raceSession: session, sequence: race,
                                now: { clock.date }, tickInterval: nil)
        race.queue = queue
        race.attach(host: model)
        queue.attach(host: model, haptics: SilentHaptics())
        race.makeLink = { [unowned self] handOff in
            let link = ScriptedRaceLink()
            links.append(link)
            handOffs.append(handOff)
            return link
        }
    }

    var link: ScriptedRaceLink { links[links.count - 1] }

    /// Through the queue and fleet lock, into the briefing.
    func lock() async {
        await queue.join()
        await queue.receive(.queued(QueuedStatus(queuedPlayers: 4, secondsToLock: 25)))
        await queue.receive(.fleetLocked)
    }

    /// Into the briefing, the link up, and on to race tick `tick`.
    func sail(to tick: Int) async {
        await lock()
        link.up(at: tick)
        race.tick()
    }

    /// Lets the controller's own tasks (a token fetch, a rating, a leave) run.
    func settle() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
    }

    func offer(at tick: Int) -> RejoinOffer {
        RejoinOffer(handOff: HandOff(raceID: Self.raceID, token: Self.fresh), seat: 0, clock: RaceClockReading(tick: tick))
    }

    static var closedReport: RaceReport {
        FakeServiceScenario.onlineRace(rated: true).lastRace!.report
    }
}

/// The online race sequence from the briefing to Home again (#141): the link under the briefing, its end on the race
/// clock, Leave before and after the gun, drops and reconnects, the cancel, the close while away, and the rating.
@MainActor @Suite struct OnlineRaceControllerTests {
    @Test func beginStartsTheRaceLinkUnderTheBriefing() async {
        let rig = SequenceRig()
        #expect(rig.race.phase == .idle)
        await rig.lock()
        #expect(rig.race.phase == .briefing && rig.links.count == 1 && rig.link.started)
        #expect(rig.handOffs.first?.token == SequenceRig.token, "the hand-off's token joins the race")
        #expect(rig.model.briefing?.isFleetLocked == true && rig.model.isLiveryLocked)
        #expect(rig.queue.bar == nil && rig.queue.entry == .ready, "the queue stays out of it")
    }

    @Test func briefingEndsAtTheRaceClockNotTheReceipt() async throws {
        let rig = SequenceRig()
        await rig.lock()
        let briefing = try #require(rig.model.briefing)
        // The link came up late: the race clock says 6 s of briefing are left, whatever the receipt's 15 s say.
        rig.link.up(at: -66 * Race.tickRate)
        rig.race.tick()
        let left = try #require(briefing.secondsLeft)
        #expect(left > 5 && left <= 6)
        #expect(rig.race.phase == .briefing)
        rig.link.tick = -60 * Race.tickRate
        rig.race.tick()
        #expect(rig.race.phase == .sequence)
        rig.link.tick = 0
        rig.race.tick()
        #expect(rig.race.phase == .racing && !rig.race.isBeforeGun)
    }

    @Test func joiningAfterMinusSixtyGoesStraightToTheSequence() async {
        let rig = SequenceRig()
        await rig.sail(to: -40 * Race.tickRate)
        #expect(rig.race.phase == .sequence)

        // The briefing ran out with no link: the water's colour and "Joining", then the race as it comes up.
        let late = SequenceRig()
        await late.lock()
        late.race.briefingEnded()
        #expect(late.race.phase == .joining && late.model.phase == .raceSequence)
        late.link.up(at: -30 * Race.tickRate)
        late.race.tick()
        #expect(late.race.phase == .sequence)
    }

    @Test func leaveInTheBriefingSendsLeaveRace() async {
        let rig = SequenceRig()
        await rig.lock()
        rig.race.askToLeave()
        #expect(rig.race.isConfirmingLeave)
        rig.race.stay()
        #expect(!rig.race.isConfirmingLeave && rig.race.phase == .briefing)
        rig.race.askToLeave()
        rig.race.leaveRace()
        await rig.race.leaving?.value
        #expect(rig.link.leaves == 1 && rig.link.closes == 0, "the link sends LeaveRace and closes itself")
        #expect(rig.race.phase == .idle && rig.model.phase == .home && rig.model.notice == nil)
        #expect(!rig.model.isLiveryLocked)
        #expect(rig.queue.entry == .settling, "Race online waits for the server's word")
        await rig.queue.receive(.idle)
        #expect(rig.queue.entry == .ready)
    }

    /// Leave before the link is up: the link's own leave joins first, on the hand-off's token, only to say
    /// `LeaveRace`, and the fake host hands the seat to a bot, as the server does before the gun.
    @Test func leaveInTheBriefingWithNoLinkConnectsJustToLeave() async throws {
        let briefing = FakeServiceScenario.briefing()
        // The host's clock stands still, before the gun, however long the suites beside this one take.
        let host = try FakeRaceHost(setup: briefing.setup, names: briefing.fleet.map(\.name), closeTick: 600, now: { 0 })
        var released = 0
        host.onSeatReleased = { released += 1 }
        var tokens: [RaceToken] = []
        let answers = AnsweringSwitch()
        let rig = SequenceRig()
        rig.race.makeLink = { handOff in
            let link = OnlineRaceLink(handOff: handOff, connector: { token in
                tokens.append(token)
                let connection = FakeRaceConnection()
                host.accept(connection)
                return AnsweredConnection(connection, host: host, answers: answers)
            }, results: nil) { connect, token in
                // The link's clock stands still too (`-timescale 0`): the handshake's own 10 s can't run out and send
                // the join round again.
                OnlineLaunch(connect: connect, token: token, timescale: 0)
            }
            // The suites run side by side and hold the main actor for minutes on a slow machine: the leave waits for
            // the join however long that takes, so nothing here is decided by the wall clock.
            link.leaveJoinTimeout = .seconds(86_400)
            return link
        }
        await rig.lock()
        // Nothing has answered yet: no race, no seat taken.
        #expect(rig.race.link?.status == .joining && !host.roster[FakeRaceHost.seat].isBot)
        rig.race.askToLeave()
        rig.race.leaveRace()
        #expect(rig.model.phase == .home, "Home doesn't wait for the leave")
        // The host answers from here on.
        answers.isOn = true
        await rig.race.leaving?.value
        #expect(tokens.first == SequenceRig.token)
        #expect(host.hasLeft && released == 1, "LeaveRace never reached the host")
        #expect(host.roster[FakeRaceHost.seat].isBot, "no bot took the seat")
        #expect(rig.race.phase == .idle && rig.queue.entry == .settling)
    }

    @Test func leaveInTheSequenceTakesTheBotSeatAndGoesHome() async {
        let rig = SequenceRig()
        await rig.sail(to: -45 * Race.tickRate)
        rig.race.openMenu()
        #expect(rig.race.isMenuOpen && rig.race.isBeforeGun)
        rig.race.askToLeave()
        rig.race.leaveRace()
        await rig.race.leaving?.value
        #expect(rig.link.leaves == 1 && rig.model.phase == .home && !rig.race.isMenuOpen)
        #expect(rig.queue.entry == .settling && rig.race.rejoinEntry == nil)
    }

    /// Owner 2026-10-12: Leave race is final after the gun too. `LeaveRace` goes, and nothing offers a way back.
    @Test func leaveAfterTheGunSendsLeaveRaceAndOffersNoRejoin() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        #expect(rig.race.phase == .racing)
        rig.race.askToLeave()
        rig.race.leaveRace()
        await rig.race.leaving?.value
        #expect(rig.link.leaves == 1 && rig.link.drops == 0)
        #expect(rig.model.phase == .home && rig.race.rejoinEntry == nil && !rig.model.isLiveryLocked)
        // The lock said again after the leave is stale: the service has no race for her.
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        #expect(rig.race.rejoinEntry == nil && rig.model.phase == .home)
    }

    @Test func backgroundBeforeTheGunKeepsTheSeatAndReturnsToTheSequence() async {
        let rig = SequenceRig()
        await rig.sail(to: -45 * Race.tickRate)
        rig.race.sceneChanged(isBackground: true)
        #expect(rig.link.drops == 1 && rig.link.leaves == 0, "a drop: nothing is sent")
        #expect(rig.race.phase == .sequence && rig.model.phase == .raceSequence && rig.model.isLiveryLocked)
        rig.link.up(at: -30 * Race.tickRate)
        rig.race.sceneChanged(isBackground: false)
        #expect(rig.race.phase == .sequence && !rig.race.isReconnecting)
        #expect(rig.session.rejoinsAsked == 0, "before the gun the hand-off's token still seats her")
    }

    @Test func backgroundMidRaceReturnsStraightToTheWater() async {
        let rig = SequenceRig()
        await rig.sail(to: 900)
        rig.race.sceneChanged(isBackground: true)
        #expect(rig.link.drops == 1 && rig.race.phase == .racing)
        rig.link.up(at: 1500)
        rig.race.sceneChanged(isBackground: false)
        #expect(rig.race.phase == .racing && rig.model.phase == .raceSequence && rig.model.notice == nil)
    }

    @Test func reconnectingShowsAfterTwoSecondsAndGoesOnRegain() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        rig.link.status = .reconnecting
        rig.race.tick()
        rig.clock.advance(1.5)
        rig.race.tick()
        #expect(!rig.race.isReconnecting)
        rig.clock.advance(0.5)
        rig.race.tick()
        #expect(rig.race.isReconnecting, "the line after 2 s")
        rig.link.status = .up
        rig.race.tick()
        #expect(!rig.race.isReconnecting && rig.race.phase == .racing)
    }

    @Test func reconnectAfterTheGunUsesAFreshTokenFromRejoin() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        rig.session.offer = rig.offer(at: 320)
        rig.link.status = .reconnecting
        rig.link.wantsToken = true
        rig.race.tick()
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 1 && rig.link.provided == [SequenceRig.fresh])
        #expect(rig.race.phase == .racing)
    }

    @Test func returningAfterTheCloseLandsOnHomeWithTheLastRace() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        rig.race.sceneChanged(isBackground: true)
        // Back after the close: the reconnect asks for a token, and the service has no race, only the last one.
        rig.session.last = LastRace(report: SequenceRig.closedReport, rating: nil)
        rig.link.wantsToken = true
        rig.race.sceneChanged(isBackground: false)
        await rig.settle()
        #expect(rig.race.phase == .idle && rig.model.phase == .home)
        #expect(rig.model.notice == nil, "no extra line")
        #expect(rig.model.lastRace?.summary == "3 of 6" && rig.model.lastRace?.ratingBadge == nil)
        #expect(rig.queue.entry == .ready && !rig.model.isLiveryLocked)
    }

    @Test func raceCancelledOnTheLinkGoesHomeWithTheNotice() async {
        let rig = SequenceRig()
        await rig.sail(to: 240)
        let before = rig.model.lastRace
        rig.link.ending = .cancelled(.serverShutdown)
        rig.race.tick()
        #expect(rig.race.phase == .idle && rig.model.phase == .home)
        #expect(rig.model.notice == .raceCancelled && !rig.model.isLiveryLocked)
        #expect(rig.model.lastRace == before && rig.queue.entry == .ready)
        #expect(rig.link.closes == 1 && rig.link.leaves == 0)
    }

    /// The cancel may come on the results stream first (the race link down, or slower): the link reads it there.
    @Test func raceCancelledOnTheResultsStreamGoesHomeWithTheNotice() async {
        let rig = SequenceRig()
        let service = ScriptedRaceSessionService(RaceSessionScenario(results: [.cancelled(.serverShutdown)]))
        let results = OnlineResults(service: service, raceID: SequenceRig.raceID)
        rig.race.makeLink = { handOff in
            OnlineRaceLink(handOff: handOff, connector: { _ in UnansweredRaceConnection() }, results: results) { connect, token in
                OnlineLaunch(connect: connect, token: token)
            }
        }
        await rig.lock()
        let before = rig.model.lastRace
        rig.race.tick()
        #expect(rig.race.phase == .briefing, "nothing is cancelled yet")
        results.start()
        await rig.settle()
        #expect(results.isCancelled)
        rig.race.tick()
        #expect(rig.race.phase == .idle && rig.model.phase == .home)
        #expect(rig.model.notice == .raceCancelled && !rig.model.isLiveryLocked)
        #expect(rig.model.lastRace == before && rig.queue.entry == .ready)
    }

    @Test func serverGoneSixtySecondsAsksTheServiceThenEnds() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        rig.link.status = .reconnecting
        rig.race.tick()
        rig.clock.advance(59)
        rig.race.tick()
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 0 && rig.race.phase == .racing)
        rig.clock.advance(1)
        rig.race.tick()
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 1)
        // No race and no last race for it: cancelled.
        #expect(rig.model.phase == .home && rig.model.notice == .raceCancelled)
    }

    @Test func finishedHomeAndRaceAgainReleaseTheSeatBeforeJoining() async {
        let rig = SequenceRig()
        await rig.sail(to: 9000)
        rig.link.isPlayerDone = true
        rig.race.tick()
        #expect(rig.race.phase == .done)
        rig.race.askToLeave()
        #expect(!rig.race.isConfirmingLeave, "done, there is nothing to confirm")
        await rig.race.raceAgain()
        #expect(rig.link.leaves == 1, "LeaveRace, so the queue is free for the join")
        #expect(rig.model.phase == .home && rig.queue.bar == .joining && rig.counting.joins == 2)

        // After the close there is no seat to give up.
        let closed = SequenceRig()
        await closed.sail(to: 9000)
        closed.link.ending = .closed
        closed.race.tick()
        #expect(closed.race.phase == .done && closed.model.phase == .raceSequence)
        closed.race.home()
        #expect(closed.link.leaves == 0 && closed.link.closes == 1)
        #expect(closed.model.phase == .home && closed.queue.entry == .ready)
    }

    @Test func liveryUnlocksOnlyWhenTheCoverIsLeft() async {
        let rig = SequenceRig()
        await rig.lock()
        #expect(rig.model.isLiveryLocked)
        rig.link.up(at: -50 * Race.tickRate)
        rig.race.tick()
        rig.link.tick = 600
        rig.race.tick()
        rig.link.isPlayerDone = true
        rig.race.tick()
        #expect(rig.model.isLiveryLocked, "through the sequence, the race and the results")
        rig.race.home()
        #expect(!rig.model.isLiveryLocked && rig.model.path.isEmpty)
    }

    @Test func ratingPushedAfterLeavingUpdatesTheLastRaceRow() async {
        let rig = SequenceRig()
        await rig.sail(to: 300)
        rig.link.status = .reconnecting
        rig.link.wantsToken = true
        rig.session.last = LastRace(report: SequenceRig.closedReport, rating: nil)
        rig.race.tick()
        await rig.settle()
        #expect(rig.model.phase == .home && rig.model.lastRace?.ratingBadge == nil)
        // Another race's change is not hers.
        rig.session.push(RatingChange(raceID: RaceID("other"), outcome: .unrated))
        rig.session.push(RatingChange(raceID: SequenceRig.raceID, outcome: .rated(
            before: Rating(value: 1500, isProvisional: true), after: Rating(value: 1512, isProvisional: true))))
        await rig.settle()
        #expect(rig.model.lastRace?.ratingBadge?.text == "+12")
        #expect(rig.model.lastRace?.ratingBadge?.spoken == "Rating plus 12")
    }

    @Test func updateRequiredOnTheRaceLinkGoesHomeWithTheNotice() async {
        let rig = SequenceRig()
        await rig.lock()
        rig.link.status = .updateRequired
        rig.race.tick()
        #expect(rig.model.phase == .home && rig.model.notice == .updateToRaceOnline)
        #expect(rig.link.leaves == 0, "LeaveRace is not possible: the server counts the drop")
    }
}

/// Home's Rejoin race (#141): offered only after a real drop, with the race clock, until the close.
@MainActor @Suite struct RejoinOfferTests {
    @Test func fleetLockedWhileIdleAsksForARejoin() async {
        let rig = SequenceRig()
        rig.session.offer = rig.offer(at: 12 * 60 * Race.tickRate + 36 * Race.tickRate)
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 1)
        #expect(rig.race.rejoinEntry?.clock(at: rig.clock.date) == "12:36")
        #expect(rig.model.phase == .home && rig.links.isEmpty, "an offer, not a takeover")
    }

    @Test func noRaceIgnoresAStaleFleetLocked() async {
        let rig = SequenceRig()
        // A seat she left has no hand-off either.
        rig.session.handOffAnswer = nil
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 1 && rig.race.rejoinEntry == nil)
        #expect(!rig.model.isLiveryLocked && rig.model.notice == nil)
    }

    @Test func anOfferKeepsTheLiveryLockedUntilTheStreamLeavesFleetLocked() async {
        let rig = SequenceRig()
        rig.session.offer = rig.offer(at: 600)
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        #expect(rig.model.isLiveryLocked && rig.race.rejoinEntry != nil)
        // The race closed while she was away: Race online is back, with the Last race row and no notice.
        rig.session.offer = nil
        rig.session.last = LastRace(report: SequenceRig.closedReport, rating: nil)
        await rig.queue.receive(.idle)
        await rig.settle()
        #expect(rig.race.rejoinEntry == nil && !rig.model.isLiveryLocked)
        #expect(rig.model.lastRace?.summary == "3 of 6" && rig.model.notice == nil)
    }

    @Test func theEntryCountsTheRaceClockLocally() {
        let read = Date(timeIntervalSince1970: 1000)
        let entry = OnlineRaceController.RejoinEntry(tick: 12 * 60 * Race.tickRate + 36 * Race.tickRate, readAt: read)
        #expect(entry.clock(at: read) == "12:36")
        #expect(entry.clock(at: read.addingTimeInterval(5)) == "12:41")
        #expect(entry.spoken(at: read.addingTimeInterval(5)) == "Rejoin race, 12 minutes 41 seconds into the race")
        let slow = OnlineRaceController.RejoinEntry(tick: 0, readAt: read, timescale: 0.2)
        #expect(slow.clock(at: read.addingTimeInterval(10)) == "0:02")
    }

    @Test func tappingRejoinGoesStraightToTheWaterWithNoBriefing() async {
        let rig = SequenceRig()
        rig.session.offer = rig.offer(at: 600)
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        await rig.race.rejoin()
        #expect(rig.race.phase == .racing && rig.race.rejoinEntry == nil)
        #expect(rig.handOffs.last?.token == SequenceRig.fresh, "a fresh token")
        #expect(rig.session.rejoinsAsked == 2 && rig.link.started)
        #expect(rig.model.briefing == nil)
        // The queue stays out of it, and is free once she is home.
        rig.link.up(at: 700)
        rig.link.ending = .closed
        rig.race.tick()
        rig.race.home()
        #expect(rig.queue.entry == .ready && rig.model.phase == .home)
    }

    /// The app was killed in the briefing and is back before the gun: the stream says `.fleetLocked`, there is
    /// nothing to rejoin yet, and the hand-off still seats her. The app is taken over again as at fleet lock, with
    /// the briefing time the race clock leaves; back after the briefing's end, straight to the sequence.
    @Test func aRelaunchInTheBriefingTakesTheAppOverAgain() async throws {
        let rig = SequenceRig()
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        #expect(rig.session.rejoinsAsked == 1, "the rejoin is asked first")
        #expect(rig.race.phase == .briefing && rig.race.rejoinEntry == nil)
        let briefing = try #require(rig.model.briefing)
        #expect(briefing.isFleetLocked && rig.model.phase == .raceSequence && rig.model.isLiveryLocked)
        #expect(rig.handOffs.last?.token == SequenceRig.token && rig.link.started)
        #expect(rig.queue.entry == .ready && rig.queue.bar == nil, "the queue stays out of it")
        // 4 s of the briefing are left on the race clock.
        rig.link.up(at: -64 * Race.tickRate)
        rig.race.tick()
        let left = try #require(briefing.secondsLeft)
        #expect(left > 3 && left <= 4)
        // Leaving works as from any briefing.
        rig.race.leaveRace()
        await rig.race.leaving?.value
        #expect(rig.link.leaves == 1 && rig.model.phase == .home && rig.queue.entry == .settling)

        let late = SequenceRig()
        await late.queue.receive(.fleetLocked)
        await late.settle()
        late.link.up(at: -30 * Race.tickRate)
        late.race.tick()
        #expect(late.race.phase == .sequence, "back after the briefing's end, the sequence")

        // Back on the foreground with no race on, only a rejoin is asked for: no fleet has locked.
        let idle = SequenceRig()
        idle.race.sceneChanged(isBackground: false)
        await idle.settle()
        #expect(idle.session.rejoinsAsked == 1 && idle.race.phase == .idle && idle.model.phase == .home)

        // Waiting for another fleet by the time the hand-off answers, that one is left alone.
        let queued = SequenceRig()
        await queued.queue.join()
        await queued.race.askForRejoin(orTakeOver: true)
        #expect(queued.race.phase == .idle && queued.model.phase == .home)
    }

    @Test func rejoinThatFindsNoRaceSaysSo() async {
        let rig = SequenceRig()
        rig.session.offer = rig.offer(at: 600)
        await rig.queue.receive(.fleetLocked)
        await rig.settle()
        rig.session.offer = nil
        await rig.race.rejoin()
        #expect(rig.race.rejoinEntry == nil && rig.race.phase == .idle && !rig.model.isLiveryLocked)
        #expect(rig.model.notice == AppModel.Notice(title: "The race has ended", message: "Back to Race online."))
    }
}
