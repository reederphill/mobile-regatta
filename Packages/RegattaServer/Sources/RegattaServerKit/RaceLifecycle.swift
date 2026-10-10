import Crypto
import Foundation
import Persistence
import RaceHost
import RegattaCore
import RegattaProtocol
import RegattaServices

// An online race from fleet lock to its close or cancel (#148): fleet lock → briefing → sequence → racing → closed |
// cancelled. The persisted states are `running | closed | cancelled` (#144's registry); the phases between are read from
// the host's tick (`RacePhase`). The lifecycle knows each player's seat, so the service can offer a rejoin after the gun
// (#16, #66) and refuse the queue meanwhile; streams each player her results until the close (#24); and runs the close:
// the log, digest and results stored at once, the final report, the rating change, the winner's line in the lobby.
// A race every human left is ended by its host at the all-gone trigger (G3): `Race.closeAllGone` at the trigger's tick, so
// the log replays it (ADR 0002), or, for a mass drop under `simultaneousLossPolicy = cancel`, a cancel like a crash (#30).
//
// Deterministic where it touches the race: reports are built from the host's results at its tick, never from the clock.
// The clock is only the rejoin token's expiry.

/// The lifecycle's rules (#148). Server config: `SIMULTANEOUS_LOSS_POLICY`.
public struct RaceLifecycleSettings: Sendable, Equatable {
    /// When every human is gone (G3), and what a mass drop does. The host ends the race itself (`endsRace`).
    public var allGone: AllGoneConfig
    /// How long the briefing shows after fleet lock, within the start sequence (CONTEXT: 15 s online).
    public var briefingTicks = 15 * Race.tickRate
    /// A rating change the player hasn't read yet is kept for her, at most this many (#24).
    public var pendingRatingChanges = 16

    public init() {
        allGone = AllGoneConfig()
        allGone.endsRace = true
    }

    /// The host options a lifecycle race sails with.
    public var hostOptions: RaceHostOptions {
        var options = RaceHostOptions()
        options.allGone = allGone
        return options
    }
}

/// Where a race is, for the race clock and rejoin gating (#16, #66). Read from the host's tick; not persisted.
public enum RacePhase: Hashable, Sendable {
    /// The fleet is fixed and the race not started yet.
    case fleetLock
    /// The first `briefingTicks` of the start sequence.
    case briefing
    /// The rest of the start sequence, to the gun.
    case sequence
    /// From the gun to the close.
    case racing
    case closed
    case cancelled

    /// The phase at `tick` of a race that starts at `firstTick` (`-startSequenceTicks`).
    public static func at(tick: Int, firstTick: Int, briefingTicks: Int) -> RacePhase {
        if tick >= 0 { return .racing }
        return tick < firstTick + briefingTicks ? .briefing : .sequence
    }
}

/// Starts a session and calls back once when it ends: the registry in production.
public typealias RaceStarter = @Sendable (_ session: RaceSession, _ ended: @escaping @Sendable (RaceEnd) -> Void) async throws -> Void

/// What the race session service and the queue read of the lifecycle (#148). A narrow seam for #146's services.
public protocol RaceLifecycleProviding: Sendable {
    func rejoinable(_ playerID: String) async -> Bool
    func rejoin(_ playerID: String) async throws(RaceSessionError) -> RejoinOffer
    func results(for playerID: String) -> AsyncStream<RaceUpdate>
    func ratingChanges(for playerID: String) -> AsyncStream<RatingChange>
    func lastRace(of playerID: String) async throws -> LastRace?
}

public actor RaceLifecycle: RaceLifecycleProviding, RunningRaces {
    public nonisolated let settings: RaceLifecycleSettings
    public nonisolated let archive: any RaceArchive
    private let tokenKey: SymmetricKey
    private let tokenLifetime: TimeInterval
    private let now: @Sendable () -> Date
    /// Recorded with each closed race (Q6: `ServerConfig.serverBuild`).
    private let toolchain: String
    private let start: RaceStarter

    private struct Live {
        let session: RaceSession
        let venue: String
        /// Each human seat's player, by player.
        let seats: [String: Int]
    }

    private enum Ended {
        case closed(RaceReport)
        case cancelled(RaceCancelled.Reason)
    }

    private var races: [UUID: Live] = [:]
    /// Races in the close pipeline.
    private var closing: Set<UUID> = []
    /// The race each player sits in, until it ends.
    private var seated: [String: UUID] = [:]
    /// The player's race that ended, until her next one starts: what her results stream says now.
    private var ended: [String: Ended] = [:]
    private var resultWatchers: [String: [UUID: AsyncStream<RaceUpdate>.Continuation]] = [:]
    private var pendingRatings: [String: [RatingChange]] = [:]
    private var ratingWatchers: [String: [UUID: AsyncStream<RatingChange>.Continuation]] = [:]
    private var lineWatchers: [UUID: AsyncStream<SystemLine>.Continuation] = [:]
    /// Store failures, for the log and tests.
    public private(set) var archiveFailures: [String] = []

    public init(settings: RaceLifecycleSettings = RaceLifecycleSettings(), archive: any RaceArchive, tokenKey: SymmetricKey,
                tokenLifetime: TimeInterval, toolchain: String, now: @escaping @Sendable () -> Date = { Date() },
                start: @escaping RaceStarter) {
        self.settings = settings
        self.archive = archive
        self.tokenKey = tokenKey
        self.tokenLifetime = tokenLifetime
        self.toolchain = toolchain
        self.now = now
        self.start = start
    }

    /// Races start on `registry`, on the wall clock.
    public init(settings: RaceLifecycleSettings = RaceLifecycleSettings(), archive: any RaceArchive, tokenKey: SymmetricKey,
                tokenLifetime: TimeInterval, toolchain: String, registry: RaceRegistry, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(settings: settings, archive: archive, tokenKey: tokenKey, tokenLifetime: tokenLifetime, toolchain: toolchain, now: now,
                  start: { session, ended in try await registry.start(session, onClose: ended) })
    }

    // MARK: Starting

    /// The matchmaker's launcher (#146): each locked fleet's race, named for its humans, registered and started here.
    public nonisolated func launcher(clock: any HostClock = SystemClock()) -> RaceLauncher {
        { fleet, closed in
            let session = self.session(id: fleet.raceID, setup: fleet.setup, windSeed: fleet.windSeed,
                                       names: fleet.humans.map(\.alias), clock: clock, onBriefingLeave: fleet.onBriefingLeave)
            try await self.launch(session, players: fleet.humans.map(\.teamPlayerID), venue: fleet.drawn.pairing.venue.content.displayName,
                                  then: closed)
        }
    }

    /// A session for a lifecycle race: the humans named in seat order, bots "Seat n" (#149 names them), the lifecycle's
    /// all-gone rules, and its results changes reported here. `onBriefingLeave` (the queue's, #147) hears its humans who
    /// leave before the gun; a dev-arranged race has none.
    public nonisolated func session(id: UUID, setup: RaceSetup, windSeed: WindSeed, names: [String], clock: any HostClock = SystemClock(),
                                    options: RaceHostOptions? = nil,
                                    onBriefingLeave: (@Sendable (BriefingLeave) -> Void)? = nil) -> RaceSession {
        let roster = setup.seats.indices.map { seat in
            RosterEntry(name: LockedFleet.seatName(seat, humans: names), colorIndex: seat)
        }
        return RaceSession(id: id, setup: setup, windSeed: windSeed, clock: clock, options: options ?? settings.hostOptions, roster: roster,
                           onProgress: { [weak self] in
                               guard let self else { return }
                               Task { await self.progress(id) }
                           }, onBriefingLeave: onBriefingLeave)
    }

    /// Registers `session` (its `races` row, running, with its players in seats 0…), starts it, and runs the close
    /// pipeline when it ends, then `closed`. Throws, registering nothing, if it can't be stored or started.
    public func launch(_ session: RaceSession, players: [String], venue: String, then closed: @escaping @Sendable () -> Void = {}) async throws {
        try await archive.register(session.id, players: players.enumerated().map { RaceSeatHolder(playerID: $1, seat: $0) })
        register(session, players: players, venue: venue)
        do {
            try await start(session) { end in
                Task {
                    await self.ended(session.id, end)
                    closed()
                }
            }
        } catch {
            unregister(session.id)
            do { try await archive.cancel(session.id) } catch { archiveFailures.append("cancel \(session.id): \(error)") }
            throw error
        }
    }

    /// Records the players' seats without storing or starting anything: `launch`'s first half, for tests that drive a
    /// session by hand and end it with `ended(_:_:)`.
    func register(_ session: RaceSession, players: [String], venue: String) {
        let seats = Dictionary(uniqueKeysWithValues: players.enumerated().map { ($1, $0) })
        races[session.id] = Live(session: session, venue: venue, seats: seats)
        for player in players {
            seated[player] = session.id
            ended[player] = nil
        }
    }

    private func unregister(_ id: UUID) {
        guard let live = races.removeValue(forKey: id) else { return }
        for player in live.seats.keys where seated[player] == id { seated[player] = nil }
    }

    // MARK: Reading

    /// The race's phase, nil for a race that isn't running here.
    public func phase(of race: UUID) async -> RacePhase? {
        guard let live = races[race] else { return nil }
        let host = live.session.host
        if let outcome = await host.outcome { return outcome.results == nil ? .cancelled : .closed }
        if await host.cancelled != nil { return .cancelled }
        return RacePhase.at(tick: await host.tick, firstTick: await host.firstTick, briefingTicks: settings.briefingTicks)
    }

    /// Where the race the player is sitting in stands: its id, her seat and its clock (#147 reads `expectedCloseTick`).
    public func seat(of playerID: String) async -> (race: UUID, seat: Int, clock: RaceClockReading)? {
        guard let id = seated[playerID], let live = races[id], let seat = live.seats[playerID] else { return nil }
        let host = live.session.host
        return (id, seat, RaceClockReading(tick: await host.tick, expectedCloseTick: await host.expectedCloseTick))
    }

    /// Every race running here that hasn't ended, with the ticks to its expected close (`Race.expectedCloseTick`): what
    /// the queue catches finishers from (#147, G2).
    public func runningRaces() async -> [RunningRace] {
        var running: [RunningRace] = []
        for (id, live) in races where !closing.contains(id) {
            let host = live.session.host
            guard await !host.isEnded else { continue }
            running.append(RunningRace(id: id, ticksToClose: max(0, await host.expectedCloseTick - (await host.tick))))
        }
        return running
    }

    /// Whether the player can take her boat back: her race is past the gun, not closed, and she didn't leave it (#16,
    /// #66: no rejoin before the gun). While it is, the queue refuses her.
    public func rejoinable(_ playerID: String) async -> Bool { await rejoinSeat(playerID) != nil }

    private func rejoinSeat(_ playerID: String) async -> (race: UUID, seat: Int, host: RaceHost)? {
        guard let id = seated[playerID], let live = races[id], let seat = live.seats[playerID] else { return nil }
        let host = live.session.host
        guard await !host.isEnded, await host.tick >= 0, await !host.hasLeft(seat: seat) else { return nil }
        return (id, seat, host)
    }

    /// A fresh token for her seat and the race clock (#16): straight back to the water.
    public func rejoin(_ playerID: String) async throws(RaceSessionError) -> RejoinOffer {
        guard let (id, seat, host) = await rejoinSeat(playerID) else { throw .noRace }
        let expiry = Int64((now() + tokenLifetime).timeIntervalSince1970)
        guard let bytes = RaceToken(raceID: id, seat: seat, expiresAt: expiry).signed(with: tokenKey) else { throw .noRace }
        return RejoinOffer(handOff: HandOff(raceID: RaceResultsFeed.raceID(id), token: RegattaServices.RaceToken(bytes: bytes)), seat: seat,
                           clock: RaceClockReading(tick: await host.tick, expectedCloseTick: await host.expectedCloseTick))
    }

    /// What a race connection is told about a race that isn't running (#30): closed, or cancelled (a race this
    /// process never ran is one a crash left: cancelled).
    public func endedState(of race: UUID) async -> RaceState {
        do {
            return try await archive.state(of: race) == .closed ? .closed : .cancelled
        } catch {
            return .cancelled
        }
    }

    // MARK: Results

    /// The player's results: her race's report now and at each change, ending with the closed report, or `.cancelled`.
    /// Coalesced to the newest. With no race it ends at once; after her race ended it says how, until her next.
    public nonisolated func results(for playerID: String) -> AsyncStream<RaceUpdate> {
        let (stream, continuation) = AsyncStream<RaceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        continuation.onTermination = { _ in Task { await self.unwatchResults(playerID, token) } }
        Task { await self.watchResults(playerID, token, continuation) }
        return stream
    }

    private func watchResults(_ playerID: String, _ token: UUID, _ continuation: AsyncStream<RaceUpdate>.Continuation) async {
        if let id = seated[playerID], let live = races[id], let seat = live.seats[playerID] {
            resultWatchers[playerID, default: [:]][token] = continuation
            let report = RaceResultsFeed.live(id, seat: seat, roster: await live.session.host.rosterEntries,
                                              results: await live.session.host.liveResults())
            // The race may have ended meanwhile: then the stream already has its last word.
            if races[id] != nil { continuation.yield(.report(report)) }
            return
        }
        switch ended[playerID] {
        case .closed(let report): continuation.yield(.report(report))
        case .cancelled(let reason): continuation.yield(.cancelled(reason))
        case nil: break
        }
        continuation.finish()
    }

    private func unwatchResults(_ playerID: String, _ token: UUID) {
        resultWatchers[playerID]?[token] = nil
        if resultWatchers[playerID]?.isEmpty == true { resultWatchers[playerID] = nil }
    }

    /// The race's results changed: every watching player gets her report.
    func progress(_ id: UUID) async {
        guard let live = races[id] else { return }
        let watching = live.seats.filter { resultWatchers[$0.key] != nil }
        guard !watching.isEmpty else { return }
        let host = live.session.host
        let results = await host.liveResults(), roster = await host.rosterEntries
        guard races[id] != nil, !closing.contains(id) else { return }
        for (player, seat) in watching {
            let report = RaceResultsFeed.live(id, seat: seat, roster: roster, results: results)
            for continuation in resultWatchers[player]?.values ?? [:].values { continuation.yield(.report(report)) }
        }
    }

    /// Rating changes for the player as they come, starting with any she hasn't read (#24). Until ratings exist (Q5) an
    /// unrated race pushes `.unrated` and a rated one nothing.
    public nonisolated func ratingChanges(for playerID: String) -> AsyncStream<RatingChange> {
        let (stream, continuation) = AsyncStream<RatingChange>.makeStream(bufferingPolicy: .bufferingNewest(settings.pendingRatingChanges))
        let token = UUID()
        continuation.onTermination = { _ in Task { await self.unwatchRatings(playerID, token) } }
        Task { await self.watchRatings(playerID, token, continuation) }
        return stream
    }

    private func watchRatings(_ playerID: String, _ token: UUID, _ continuation: AsyncStream<RatingChange>.Continuation) {
        for change in pendingRatings.removeValue(forKey: playerID) ?? [] { continuation.yield(change) }
        ratingWatchers[playerID, default: [:]][token] = continuation
    }

    private func unwatchRatings(_ playerID: String, _ token: UUID) {
        ratingWatchers[playerID]?[token] = nil
        if ratingWatchers[playerID]?.isEmpty == true { ratingWatchers[playerID] = nil }
    }

    private func push(_ change: RatingChange, to playerID: String) {
        if let watchers = ratingWatchers[playerID], !watchers.isEmpty {
            for continuation in watchers.values { continuation.yield(change) }
        } else {
            pendingRatings[playerID, default: []].append(change)
            pendingRatings[playerID] = Array(pendingRatings[playerID]!.suffix(settings.pendingRatingChanges))
        }
    }

    /// The last race the player sat in that closed, until her next one closes (#24). Rating nil until ratings exist.
    public func lastRace(of playerID: String) async throws -> LastRace? {
        guard let stored = try await archive.lastRace(of: playerID), let seat = stored.seat else { return nil }
        let report = RaceResultsFeed.closed(stored.raceID, seat: seat, summary: try RaceSummary(decoding: stored.results),
                                            incidents: try RaceResultsFeed.decodeIncidents(stored.incidents))
        return LastRace(report: report, rating: nil)
    }

    /// The lobby's lines from the close: one "X won" per race (#36). #152's lobby takes this stream; newest 64 kept.
    /// Every line from now on.
    public func systemLines() -> AsyncStream<SystemLine> {
        let (stream, continuation) = AsyncStream<SystemLine>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let token = UUID()
        continuation.onTermination = { _ in Task { await self.unwatchLines(token) } }
        lineWatchers[token] = continuation
        return stream
    }

    private func unwatchLines(_ token: UUID) { lineWatchers[token] = nil }

    // MARK: The close

    /// Cancels a running race (#30): its host stops and tells its seats, and the close pipeline cancels it.
    public func cancel(_ race: UUID, reason: RaceCancelled.Reason = .unspecified) async {
        await races[race]?.session.host.cancel(reason)
    }

    /// The race ended (the registry's `onClose`): the close pipeline. A race with results is stored (log, digest,
    /// versions, results, all at once), each player's stream ends with her closed report, unrated players get
    /// `.unrated`, and the lobby gets the winner's line. A race without results (cancelled, or closed where it stood
    /// by a shutdown) is cancelled: no results, no rating, and each stream ends with `.cancelled`.
    public func ended(_ id: UUID, _ end: RaceEnd) async {
        guard let live = races[id], closing.insert(id).inserted else { return }
        // The race stays registered until its players' last words are set: a stream opened meanwhile is told them.
        defer {
            unregister(id)
            closing.remove(id)
        }
        switch end {
        case .closed(let outcome):
            guard let results = outcome.results else { return await cancelled(id, live, reason: .serverShutdown) }
            await closed(id, live, outcome: outcome, results: results)
        case .cancelled(let reason):
            await cancelled(id, live, reason: reason)
        }
    }

    private func closed(_ id: UUID, _ live: Live, outcome: RaceOutcome, results: RaceResults) async {
        let host = live.session.host
        let summary = RaceSummary(venue: live.venue, roster: await host.rosterEntries, results: results,
                                  turnsServed: await host.liveResults().turnsServed)
        let incidents = outcome.log.incidentIndex ?? IncidentIndex()
        var stored = (summary: summary, incidents: incidents)
        do {
            let record = ClosedRaceRecord(id: id, log: try outcome.log.jsonData(pretty: false), digest: outcome.digest,
                                          simulationVersion: outcome.log.header.simulationVersion, toolchain: toolchain,
                                          results: try summary.encoded(), incidents: try RaceResultsFeed.encode(incidents), rated: results.rated)
            // The reports are read back from the bytes stored, so the stream's last report is the last race's.
            stored = (try RaceSummary(decoding: record.results), try RaceResultsFeed.decodeIncidents(record.incidents))
            try await archive.close(record)
        } catch {
            archiveFailures.append("close \(id): \(error)")
        }
        for (player, seat) in live.seats {
            let report = RaceResultsFeed.closed(id, seat: seat, summary: stored.summary, incidents: stored.incidents)
            ended[player] = .closed(report)
            for continuation in resultWatchers.removeValue(forKey: player)?.values ?? [:].values {
                continuation.yield(.report(report))
                continuation.finish()
            }
            if !results.rated { push(RatingChange(raceID: RaceResultsFeed.raceID(id), outcome: .unrated), to: player) }
        }
        if let line = stored.summary.winnerLine { for continuation in lineWatchers.values { continuation.yield(line) } }
    }

    private func cancelled(_ id: UUID, _ live: Live, reason: RaceCancelled.Reason) async {
        do { try await archive.cancel(id) } catch { archiveFailures.append("cancel \(id): \(error)") }
        for player in live.seats.keys {
            ended[player] = .cancelled(reason)
            for continuation in resultWatchers.removeValue(forKey: player)?.values ?? [:].values {
                continuation.yield(.cancelled(reason))
                continuation.finish()
            }
        }
    }

    // MARK: Dev arrangements (#148)

    /// Dev only (`POST /dev/situation`): a race for `player` alone in seat 0, bots to 4 boats, a `startSequenceTicks`
    /// sequence, started like a queue race; returns once it is past the gun if `pastGun`. Her seat is never joined, so it
    /// drops a second after the start and the all-gone grace (`graceTicks`) closes the race.
    public func arrangeRace(for player: AccountPlayer, startSequenceTicks: Int = 15, graceTicks: Int? = nil,
                            pastGun: Bool = false) async throws -> UUID {
        let setup = try RaceSetup(raceSeed: RaceSeed(0x148), seats: [.human, .bot, .bot, .bot], laps: 1, startSequenceTicks: startSequenceTicks)
        var options = settings.hostOptions
        if let graceTicks { options.allGone.graceTicks = graceTicks }
        let session = session(id: UUID(), setup: setup, windSeed: WindSeed(0x148), names: [player.alias], options: options)
        try await launch(session, players: [player.teamPlayerID], venue: "Dev")
        if pastGun {
            let deadline = ContinuousClock.now + .seconds(10)
            while await session.host.tick < 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        return session.id
    }

    /// Server shutdown: the streams end.
    public func stop() {
        for watchers in resultWatchers.values { for continuation in watchers.values { continuation.finish() } }
        for watchers in ratingWatchers.values { for continuation in watchers.values { continuation.finish() } }
        for continuation in lineWatchers.values { continuation.finish() }
        resultWatchers = [:]
        ratingWatchers = [:]
        lineWatchers = [:]
    }
}
