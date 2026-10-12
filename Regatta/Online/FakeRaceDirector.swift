#if DEBUG
import Foundation
import RegattaCore
import RegattaProtocol
import RegattaServices

/// The race a `-fakeServices` launch sails after fleet lock (#141): one `FakeRaceHost`, and everything the services
/// say around it, telling one story. The hand-off starts the race (75 s to the gun, as the server's); the race
/// session offers the rejoin while the host says there is one, streams the close's report or the cancel, pushes the
/// rating a moment after the close and remembers the last race; the queue's stream says `.fleetLocked` while the race
/// holds her and `.idle` after, as the server's does. Debug builds only.
///
/// Scenarios: the `joinable` ones sail on into this race (closed `-raceSeconds`, or 20 s, after the gun);
/// `cancelled-race` is cancelled 8 s after the gun; `race-gone`'s server never answers; `rejoinable` launches into a
/// race already under way, dropped out of, with the offer on Home.
final class FakeRaceDirector {
    /// The launch's director, for `-tap`.
    static private(set) var current: FakeRaceDirector?

    static let raceID = RaceID("fake-race")
    /// How far into its race `rejoinable` launches: the host sails this much at launch, so it is kept short.
    static let rejoinableSeconds = 38
    static let ratingDelay = Duration.milliseconds(1500)

    private let scenario: FakeServiceScenario
    private let base: any RaceSessionService
    private let clock: MonotonicClock
    private let timescale: Double
    private let raceSeconds: Int?
    private(set) var host: FakeRaceHost?
    /// `-tap connection-lost`: the race server stops answering new connections.
    var isReachable = true
    private var leftAfterGun = false
    private var report: RaceReport?
    private var rating: RatingChange?
    private var isCancelled = false
    /// `-tap race-ended`: the race closes without the queue's stream saying so yet, as a stream lagging the close
    /// would, so Home's Rejoin race is still up for a tap that finds no race.
    private var endsQuietly = false
    private var resultStreams: [AsyncStream<RaceUpdate>.Continuation] = []
    private var ratingStreams: [AsyncStream<RatingChange>.Continuation] = []
    private var queueStreams: [AsyncStream<QueueState>.Continuation] = []
    private var pump: Task<Void, Never>?

    /// The director for the launch's scenario, if it sails a race.
    static func make(launchOptions: LaunchOptions, services: ServiceSet) -> FakeRaceDirector? {
        guard let scenario = launchOptions.fakeServices else { return nil }
        switch scenario {
        case .joinable, .joinableAlone, .joinableHold, .rejoinable, .raceGone, .cancelledRace, .signedOut: break
        default: return nil
        }
        let director = FakeRaceDirector(scenario: scenario, base: services.raceSession, timescale: launchOptions.timescale,
                                        raceSeconds: launchOptions.raceSeconds)
        current = director
        return director
    }

    init(scenario: FakeServiceScenario, base: any RaceSessionService, timescale: Double, raceSeconds: Int?) {
        self.scenario = scenario
        self.base = base
        self.timescale = timescale
        self.raceSeconds = raceSeconds
        clock = MonotonicClock(timescale: timescale)
        if scenario == .rejoinable {
            let briefing = FakeServiceScenario.briefing()
            let under = Self.rejoinableSeconds * Race.tickRate
            startRace(briefing, startSequenceTicks: 10 * Race.tickRate, closeTick: under + (raceSeconds ?? 60) * Race.tickRate)
            host?.fastForward(to: under)
        }
    }

    // MARK: The race session

    func handOff() async throws -> HandOff {
        let handOff = try await base.handOff()
        // A fleet lock starts its race; asked again while the race holds her, it is the same one.
        if host?.holdsSeat != true, let briefing = handOff.briefing {
            startRace(briefing, startSequenceTicks: briefing.gunInSeconds * Race.tickRate,
                      closeTick: (raceSeconds ?? 20) * Race.tickRate)
        }
        return handOff
    }

    func rejoin() throws -> RejoinOffer {
        guard let host, host.isRejoinable else { throw RaceSessionError.noRace }
        return RejoinOffer(handOff: HandOff(raceID: Self.raceID, token: RaceToken(bytes: [0xF0, 0x0D])), seat: FakeRaceHost.seat,
                           clock: RaceClockReading(tick: host.tick, expectedCloseTick: host.closeTick))
    }

    func lastRace() -> LastRace? {
        report.map { LastRace(report: $0, rating: rating) }
    }

    func addResults(_ stream: AsyncStream<RaceUpdate>.Continuation) {
        resultStreams.append(stream)
        if isCancelled { stream.yield(.cancelled(.serverShutdown)) } else if let report { stream.yield(.report(report)) }
    }

    func addRatings(_ stream: AsyncStream<RatingChange>.Continuation) {
        ratingStreams.append(stream)
        if let rating { stream.yield(rating) }
    }

    // MARK: The queue

    /// The race holds her: the queue says `.fleetLocked`, and a join is `alreadyQueued`.
    var holdsSeat: Bool { host?.holdsSeat == true || (endsQuietly && host?.hasLeft == false) }

    func addQueue(_ stream: AsyncStream<QueueState>.Continuation) {
        queueStreams.append(stream)
        if holdsSeat { stream.yield(.fleetLocked) }
    }

    // MARK: The race link

    func connect(_ token: RaceToken) -> any RaceConnection {
        let connection = FakeRaceConnection()
        guard scenario != .raceGone, isReachable else { return connection }
        guard let host else {
            connection.close()
            return connection
        }
        host.accept(connection)
        return connection
    }

    /// `-tap connection-lost`: the connection drops, and nothing answers until it is regained.
    func setReachable(_ reachable: Bool, dropping connection: (any RaceLinking)?) {
        isReachable = reachable
        if !reachable { connection?.drop() }
    }

    /// `-tap race-ended`: closes the race now, the queue's stream none the wiser.
    func endQuietly() {
        guard let host, host.ending == nil else { return }
        endsQuietly = true
        host.closeTick = host.tick
    }

    // MARK: Inside

    private func startRace(_ briefing: BriefingPayload, startSequenceTicks: Int, closeTick: Int) {
        let from = briefing.setup
        guard let setup = try? RaceSetup(raceSeed: from.raceSeed, seats: from.seats, laps: from.laps,
                                         startSequenceTicks: startSequenceTicks),
              let host = try? FakeRaceHost(setup: setup, names: briefing.fleet.map(\.name), closeTick: closeTick,
                                           now: clock.now) else { return }
        if scenario == .cancelledRace { host.cancelTick = 8 * Race.tickRate }
        // One of the other players gives her seat up before the gun: a bot's name and glyph from then on.
        if setup.seats.indices.contains(2), setup.seats[2] == .human {
            host.handOver = (tick: -50 * Race.tickRate, seat: 2, name: "Fulmar")
        }
        host.onEnd = { [weak self] ending in MainActor.assumeIsolated { self?.raceEnded(ending) } }
        host.onSeatReleased = { [weak self] in MainActor.assumeIsolated { self?.seatReleased() } }
        (leftAfterGun, report, rating, isCancelled) = (false, nil, nil, false)
        self.host = host
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled, let host = self?.host, host.ending == nil {
                host.poll()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func seatReleased() {
        leftAfterGun = (host?.tick ?? 0) >= 0
        for stream in queueStreams { stream.yield(.idle) }
    }

    private func raceEnded(_ ending: FakeRaceHost.Ending) {
        guard let host else { return }
        switch ending {
        case .cancelled:
            isCancelled = true
            for stream in resultStreams { stream.yield(.cancelled(.serverShutdown)) }
        case .closed:
            // Nobody has finished this soon: everyone is placed by distance, and a player who left is retired.
            var rows: [SeatResult] = []
            for seat in host.race.standings() where !(leftAfterGun && seat == FakeRaceHost.seat) {
                rows.append(SeatResult(seat: seat, place: rows.count + 1, code: .byDistance))
            }
            if leftAfterGun { rows.append(SeatResult(seat: FakeRaceHost.seat, place: rows.count + 1, code: .ret)) }
            // Alone in the queue, every other boat is a bot: unrated.
            let rated = scenario != .joinableAlone
            let closed = RaceReport(raceID: Self.raceID, seat: FakeRaceHost.seat, roster: host.roster,
                                    results: RaceResults(rows: rows, rated: rated), sailing: [], incidents: [], isClosed: true)
            report = closed
            for stream in resultStreams { stream.yield(.report(closed)) }
            // The scenarios tell the two signs apart: `joinable-hold`'s race costs her rating, the others' gain it.
            let change = leftAfterGun || scenario == .joinableHold ? -8 : 12
            let outcome: RatingOutcome = rated ? .rated(before: Rating(value: 1500, isProvisional: true),
                                                         after: Rating(value: 1500 + change, isProvisional: true)) : .unrated
            let delay = Self.ratingDelay / timescale
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.push(RatingChange(raceID: Self.raceID, outcome: outcome))
            }
        }
        if !host.hasLeft, !endsQuietly { for stream in queueStreams { stream.yield(.idle) } }
    }

    private func push(_ change: RatingChange) {
        rating = change
        for stream in ratingStreams { stream.yield(change) }
    }
}

/// The director's race session, as the services hold it.
nonisolated final class FakeRaceSession: RaceSessionService {
    private let director: FakeRaceDirector

    init(_ director: FakeRaceDirector) { self.director = director }

    func handOff() async throws -> HandOff { try await director.handOff() }
    func rejoin() async throws -> RejoinOffer { try await director.rejoin() }
    func lastRace() async throws -> LastRace? { await director.lastRace() }

    func results() -> AsyncStream<RaceUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: RaceUpdate.self)
        Task { @MainActor [director] in director.addResults(continuation) }
        return stream
    }

    func ratingChanges() -> AsyncStream<RatingChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: RatingChange.self)
        Task { @MainActor [director] in director.addRatings(continuation) }
        return stream
    }
}

/// The fakes' queue once the director sails a race: the script's idle after fleet lock waits until the race lets her
/// go, and a join meanwhile is `alreadyQueued`, as the server's.
nonisolated final class DirectedQueue: QueueService {
    private let base: any QueueService
    private let director: FakeRaceDirector

    init(_ base: any QueueService, director: FakeRaceDirector) {
        self.base = base
        self.director = director
    }

    func stateUpdates() -> AsyncStream<QueueState> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueueState.self)
        let task = Task { @MainActor [base, director] in
            director.addQueue(continuation)
            for await state in base.stateUpdates() {
                if director.holdsSeat, state != .fleetLocked { continue }
                continuation.yield(state)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func join() async throws {
        if await director.holdsSeat { throw QueueError.alreadyQueued }
        try await base.join()
    }

    func leave() async throws { try await base.leave() }
}
#endif
