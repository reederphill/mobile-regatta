import Crypto
import Foundation
import RegattaCore
import RegattaServices

// The one global queue (#16, #146): players join and leave freely; the fleet locks when 16 humans are queued, or 60 s
// after the oldest joined; bots fill it to 10 boats; one fleet fills at a time. At lock the race is drawn (venue ×
// conditions × tide state and a wind seed, `RaceDraw`), started on the race registry, and each human gets a race token
// for their seat (`ServerRaceSessionService.handOff`). The gun goes into the lobby as a system line (#17, #36).
//
// Deterministic: the clock (`now`) and the random numbers (`SeededRandom`) are injected, and time moves only when
// `step()` is called (the server calls it every `countdownInterval`; a test calls it after moving its clock).

/// The queue's rules and the race it locks into. Ticket values (#146); `lockAfter` has a dev override for the
/// contract runner (`QUEUE_LOCK_SECONDS`).
public struct QueueSettings: Sendable, Equatable {
    /// Humans in one fleet: the 16th locks it at once.
    public var fleetCap = 16
    /// Seconds from the oldest entry's join to fleet lock.
    public var lockAfter: TimeInterval = 60
    /// Boats a race has at least: bots fill the seats after the humans' (stub bots until #149).
    public var botFloor = 10
    /// Rating bands split the queue only when more than this many are queued (#146; the bands are a later ticket's).
    public var bandsAbove = 16
    /// How often the queued count and the countdown are pushed (plus on every change).
    public var countdownInterval: Duration = .seconds(1)
    /// Seeds per fixture wind seed pool, and how often each may be sailed (G1: once), until #106's real pools.
    public var windSeedPoolSize = 256
    public var windSeedReuseCap = 1
    /// The venues online races are drawn from (the newest bundled version of each); nil: every bundled venue but the dev venue.
    public var venues: [String]?
    public var laps = RaceSetup.defaultLaps
    public var startSequenceTicks = RaceSetup.defaultStartSequenceTicks

    public init() {}
}

/// A fleet that has locked: the race to start.
public struct LockedFleet: Sendable {
    public let raceID: UUID
    public let setup: RaceSetup
    public let windSeed: WindSeed
    /// In seat order: seat `i` is `humans[i]`; the seats after them are bots.
    public let humans: [AccountPlayer]
    public let drawn: DrawnRace
}

/// Starts a locked fleet's race; calls `closed` once when it closes. Throws if it can't be started.
public typealias RaceLauncher = @Sendable (_ fleet: LockedFleet, _ closed: @escaping @Sendable () -> Void) async throws -> Void

/// A queued player, since when.
public struct QueueEntry: Sendable, Equatable {
    public let player: AccountPlayer
    public let joinedAt: Date
}

/// Splits the queue into rating bands, best first (#146: a stub until ratings exist).
public typealias RatingBands = @Sendable ([QueueEntry]) -> [[QueueEntry]]

/// The queue's bookkeeping, no clock and no I/O: who is queued since when, and when the fleet locks.
struct QueueBook: Sendable {
    typealias Entry = QueueEntry

    private(set) var entries: [Entry] = []

    var count: Int { entries.count }

    func contains(_ id: String) -> Bool { entries.contains { $0.player.teamPlayerID == id } }

    mutating func add(_ player: AccountPlayer, at time: Date) { entries.append(Entry(player: player, joinedAt: time)) }

    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.player.teamPlayerID == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Puts a fleet that couldn't sail back at the head of the queue, in its order.
    mutating func restore(_ fleet: [Entry]) { entries = fleet + entries }

    /// When the fleet locks: at once with `fleetCap` humans, else `lockAfter` after the oldest joined. Nil when empty.
    func lockTime(_ settings: QueueSettings) -> Date? {
        guard let oldest = entries.first else { return nil }
        return entries.count >= settings.fleetCap ? oldest.joinedAt : oldest.joinedAt + settings.lockAfter
    }

    func isLockDue(at now: Date, _ settings: QueueSettings) -> Bool {
        guard let time = lockTime(settings) else { return false }
        return now >= time
    }

    /// Whole seconds to fleet lock, rounded up; nil when empty.
    func secondsToLock(at now: Date, _ settings: QueueSettings) -> Int? {
        lockTime(settings).map { max(0, Int(($0.timeIntervalSince(now)).rounded(.up))) }
    }

    /// Takes the fleet that locks: the first band's oldest `fleetCap`. Bands only past `bandsAbove` queued (#146: the
    /// hook is a stub until ratings exist; with one band it is the queue in join order).
    mutating func takeFleet(_ settings: QueueSettings, bands: ([Entry]) -> [[Entry]]) -> [Entry] {
        let band = entries.count > settings.bandsAbove ? (bands(entries).first ?? entries) : entries
        let fleet = Array(band.prefix(settings.fleetCap))
        let ids = Set(fleet.map(\.player.teamPlayerID))
        entries.removeAll { ids.contains($0.player.teamPlayerID) }
        return fleet
    }

    /// Seats for `humans` humans: theirs first, then bots to `botFloor` boats.
    static func seats(humans: Int, _ settings: QueueSettings) -> [SeatKind] {
        let boats = min(max(humans, settings.botFloor), RaceSetup.fleetSizes.upperBound)
        return (0..<boats).map { $0 < humans ? .human : .bot }
    }
}

/// The global queue and its fleets.
public actor QueueMatchmaker {
    public nonisolated let settings: QueueSettings
    /// Where locked races are started (the server's), for the race connections to find them by token.
    public nonisolated let registry: RaceRegistry
    private let now: @Sendable () -> Date
    private var random: SeededRandom
    private var draw: RaceDraw
    private let launch: RaceLauncher
    private let tokenKey: SymmetricKey
    private let tokenLifetime: TimeInterval
    /// Rating bands, past `bandsAbove` queued: a stub (one band, the queue as it is) until ratings exist.
    private let bands: RatingBands

    private var book = QueueBook()
    /// Each locked player's seat, until their race closes.
    private var handOffs: [String: HandOff] = [:]
    /// Players whose fleet has locked and whose race is starting, with the fleet's size.
    private var starting: [String: Int] = [:]
    private var races: [UUID: [String]] = [:]
    private var watchers: [String: [UUID: AsyncStream<QueueState>.Continuation]] = [:]
    private var lastPushed: [String: [UUID: QueueState]] = [:]
    /// Dev-arranged for the contract runner only (#146 Q1): the real cooldown rules are #147's, suspensions #26's.
    private var cooldowns: [String: Date] = [:]
    private var suspensions: [String: Int64?] = [:]
    private var guns: [(due: Date, line: SystemLine)] = []
    private var gunWatchers: [UUID: AsyncStream<SystemLine>.Continuation] = [:]
    /// Fleets locked, and the last one: for tests and logs.
    public private(set) var fleetsLocked = 0
    public private(set) var lastFleet: LockedFleet?
    private var driver: Task<Void, Never>?
    private var stopped = false

    public init(settings: QueueSettings, registry: RaceRegistry, draw: RaceDraw, tokenKey: SymmetricKey, tokenLifetime: TimeInterval,
                random: SeededRandom = .system(), now: @escaping @Sendable () -> Date = { Date() },
                bands: @escaping RatingBands = { [$0] },
                launch: RaceLauncher? = nil) {
        self.settings = settings
        self.registry = registry
        self.draw = draw
        self.tokenKey = tokenKey
        self.tokenLifetime = tokenLifetime
        self.random = random
        self.now = now
        self.bands = bands
        self.launch = launch ?? Self.registryLauncher(registry)
    }

    /// Starts each race on `registry`, on the wall clock.
    public static func registryLauncher(_ registry: RaceRegistry) -> RaceLauncher {
        { fleet, closed in
            let session = RaceSession(id: fleet.raceID, setup: fleet.setup, windSeed: fleet.windSeed)
            try await registry.start(session) { _ in closed() }
        }
    }

    // MARK: Driving

    /// Calls `step()` every `countdownInterval` until `stop()`.
    public func start() {
        guard driver == nil else { return }
        let interval = settings.countdownInterval
        driver = Task {
            repeat {
                await self.step()
                try? await Task.sleep(for: interval)
            } while !Task.isCancelled
        }
    }

    public func stop() {
        stopped = true
        driver?.cancel()
        driver = nil
        for watcher in gunWatchers.values { watcher.finish() }
        gunWatchers = [:]
    }

    /// Time has moved: locks a fleet that is due, fires the guns that are due, ends cooldowns, and pushes the
    /// countdown to everyone watching.
    public func step() async {
        let time = now()
        if book.isLockDue(at: time, settings) { await lockFleet(at: time) }
        let due = guns.filter { $0.due <= time }
        guns.removeAll { $0.due <= time }
        for gun in due { for watcher in gunWatchers.values { watcher.yield(gun.line) } }
        cooldowns = cooldowns.filter { $0.value > time }
        pushAll()
    }

    // MARK: The queue

    /// What the queue looks like to `id` now.
    public func state(of id: String) -> QueueState {
        let time = now()
        if let refusal = restriction(of: id, at: time) { return .unavailable(refusal) }
        if handOffs[id] != nil { return .fleetLocked }
        if let fleet = starting[id] { return .queued(QueuedStatus(queuedPlayers: fleet, secondsToLock: 0)) }
        if book.contains(id), let seconds = book.secondsToLock(at: time, settings) {
            return .queued(QueuedStatus(queuedPlayers: book.count, secondsToLock: seconds))
        }
        return .idle
    }

    private func restriction(of id: String, at time: Date) -> QueueRefusal? {
        if let until = suspensions[id] {
            if let until, Double(until) <= time.timeIntervalSince1970 {
                suspensions[id] = nil
            } else {
                return .suspended(until: until)
            }
        }
        if let until = cooldowns[id], until > time {
            return .cooldown(secondsRemaining: Int(until.timeIntervalSince(time).rounded(.up)))
        }
        return nil
    }

    public func join(_ player: AccountPlayer) async throws(QueueError) {
        let id = player.teamPlayerID
        switch state(of: id) {
        case .unavailable(let refusal): throw .refused(refusal)
        case .queued, .fleetLocked: throw .alreadyQueued
        case .idle: break
        }
        let time = now()
        book.add(player, at: time)
        if book.isLockDue(at: time, settings) { await lockFleet(at: time) }
        pushAll()
    }

    public func leave(_ id: String) throws(QueueError) {
        guard book.remove(id) else { throw .notQueued }
        pushAll()
    }

    /// The player's connection ended: a place in the queue goes with it (leaving is free). A locked seat stays.
    public func dropped(_ id: String) {
        guard book.remove(id) else { return }
        pushAll()
    }

    /// Players queued now.
    public var queuedCount: Int { book.count }

    // MARK: Fleet lock

    private func lockFleet(at time: Date) async {
        let fleet = book.takeFleet(settings, bands: bands)
        guard !fleet.isEmpty else { return }
        guard let drawn = draw.draw(using: &random) else {
            // Every pool is empty: the fleet waits at the head of the queue for the next step.
            book.restore(fleet)
            return
        }
        let humans = fleet.map(\.player)
        let raceID = UUID(uuid: Self.uuidBytes(&random))
        let setup: RaceSetup
        do {
            setup = try RaceSetup(raceSeed: drawn.raceSeed, seats: QueueBook.seats(humans: humans.count, settings), laps: settings.laps,
                                  startSequenceTicks: settings.startSequenceTicks, venue: drawn.pairing.venue.ref,
                                  conditions: drawn.pairing.conditions.ref)
        } catch {
            book.restore(fleet)
            return
        }
        let locked = LockedFleet(raceID: raceID, setup: setup, windSeed: drawn.windSeed, humans: humans, drawn: drawn)
        // While the race starts (the actor is free meanwhile) the fleet shows as queued with nothing left on the clock:
        // `.fleetLocked` and the hand-off come only once its race is in the registry, so a token always finds its race.
        for player in humans { starting[player.teamPlayerID] = humans.count }
        do {
            try await launch(locked) { Task { await self.raceClosed(raceID) } }
        } catch {
            // The race couldn't start (the server is full): the fleet goes back to the head of the queue. Its wind seed
            // stays retired.
            for player in humans { starting[player.teamPlayerID] = nil }
            book.restore(fleet)
            pushAll()
            return
        }
        let expiry = Int64((time + tokenLifetime).timeIntervalSince1970)
        for (seat, player) in humans.enumerated() {
            starting[player.teamPlayerID] = nil
            guard let bytes = RaceToken(raceID: raceID, seat: seat, expiresAt: expiry).signed(with: tokenKey) else { continue }
            handOffs[player.teamPlayerID] = HandOff(raceID: RaceID(raceID.uuidString.lowercased()), token: RegattaServices.RaceToken(bytes: bytes))
        }
        races[raceID] = humans.map(\.teamPlayerID)
        let gunAt = time + Double(settings.startSequenceTicks) / Double(Race.tickRate)
        guns.append((gunAt, .gun(venue: drawn.pairing.venue.content.displayName, boats: setup.fleetSize, humans: humans.count)))
        fleetsLocked += 1
        lastFleet = locked
        pushAll()
    }

    /// The race closed: its players are free to queue again.
    func raceClosed(_ raceID: UUID) {
        for id in races.removeValue(forKey: raceID) ?? [] { handOffs[id] = nil }
        pushAll()
    }

    private static func uuidBytes(_ random: inout SeededRandom) -> uuid_t {
        var bytes = [UInt8](repeating: 0, count: 16)
        for half in 0..<2 {
            let value = random.next()
            for byte in 0..<8 { bytes[half * 8 + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }

    // MARK: Hand-off

    /// The token for the player's seat in the fleet that locked, until the race closes.
    public func handOff(for id: String) throws(RaceSessionError) -> HandOff {
        guard let handOff = handOffs[id] else { throw .noRace }
        return handOff
    }

    // MARK: Watching

    /// The player's queue state now, then each change; coalesced to the latest, so a slow reader never piles them up.
    public nonisolated func stateUpdates(for id: String) -> AsyncStream<QueueState> {
        let (stream, continuation) = AsyncStream<QueueState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        continuation.onTermination = { _ in Task { await self.unwatch(id, token) } }
        Task { await self.watch(id, token, continuation) }
        return stream
    }

    private func watch(_ id: String, _ token: UUID, _ continuation: AsyncStream<QueueState>.Continuation) {
        let current = state(of: id)
        continuation.yield(current)
        watchers[id, default: [:]][token] = continuation
        lastPushed[id, default: [:]][token] = current
    }

    private func unwatch(_ id: String, _ token: UUID) {
        watchers[id]?[token] = nil
        lastPushed[id]?[token] = nil
        if watchers[id]?.isEmpty == true {
            watchers[id] = nil
            lastPushed[id] = nil
        }
    }

    /// Sends each watcher its state, if it changed since the last it was sent.
    private func pushAll() {
        for (id, streams) in watchers {
            let current = state(of: id)
            for (token, continuation) in streams where lastPushed[id]?[token] != current {
                continuation.yield(current)
                lastPushed[id, default: [:]][token] = current
            }
        }
    }

    /// The lobby's system lines for each race's gun: venue, boats, humans (#17, #36). The lobby service (#152) takes
    /// this stream; it keeps the newest 64 if nobody reads.
    /// Every gun from now on; the stream ends at `stop()`.
    public func gunLines() -> AsyncStream<SystemLine> {
        let (stream, continuation) = AsyncStream<SystemLine>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard !stopped else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        continuation.onTermination = { _ in Task { await self.unwatchGuns(token) } }
        gunWatchers[token] = continuation
        return stream
    }

    private func unwatchGuns(_ token: UUID) { gunWatchers[token] = nil }

    // MARK: Dev arrangements (#146 Q1)

    /// Dev only (`POST /dev/situation`): a queue cooldown of `seconds` for the player. #147 owns the real rule.
    public func arrangeCooldown(_ id: String, seconds: TimeInterval) {
        cooldowns[id] = now() + seconds
        pushAll()
    }

    /// Dev only: an online racing suspension until `until` (Unix seconds), nil for permanent. #26 owns the real store.
    public func arrangeSuspension(_ id: String, until: Int64?) {
        suspensions[id] = .some(until)
        pushAll()
    }
}
