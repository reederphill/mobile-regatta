import Crypto
import Foundation
import Persistence
import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol
import RegattaServices

// The one global queue (#16, #146): players join and leave freely; the fleet locks when 16 humans are queued, or 60 s
// after the oldest joined, or later to catch a running race's finishers (G2, #147); bots fill it to 10 boats, each rated
// at the fleet's median human rating give or take 150 (#19, #149, `FleetFill`); one fleet
// fills at a time. Suspended, failed-attestation and cooling-down players are refused (#147, `RestrictionStore`); a human
// who leaves between lock and gun counts towards the cooldown (`BriefingLeaveTracker`). A full server draws nothing, and a
// race that can't start is tried again with a growing delay, then its fleet dropped (`LaunchRetry`, #469). At lock the race is drawn (venue ×
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
    /// Boats a race has at least: bots fill the seats after the humans' (#149: at the fleet's level, `FleetFill`).
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
    /// The briefing after fleet lock (15 s online, CONTEXT), the first part of the race's pre-gun ticks.
    public var briefingTicks = 15 * Race.tickRate
    /// The race's pre-gun ticks (`RaceSetup.startSequenceTicks`): the briefing, then the rules' 60 s sequence, so the gun
    /// is 75 s after lock (G2).
    public var startSequenceTicks = 15 * Race.tickRate + RaceSetup.defaultStartSequenceTicks
    /// Holding the lock for a running race's finishers (G2); nil: the 1-minute rule only.
    public var catchFinishers: CatchFinishers? = CatchFinishers()
    /// Leaving the briefing: 3 in an hour cost 5 minutes (#26, owner Q1).
    public var briefingLeaves = BriefingLeaveRule()
    /// The longest a read of the restriction store may hold the queue up (#469): past it the read counts as failed.
    public var restrictionReadTimeout: Duration = .seconds(2)
    /// A locked fleet whose race can't start: when it is tried again, and when it is given up (#469).
    public var launchRetry = LaunchRetry()

    public init() {}
}

/// What the queue does with a fleet whose race couldn't start (#469). The fleet waits at the head of the queue, showing
/// nothing left on the clock, and is tried again after `firstDelay`, then twice as long after each further failure in a
/// row, up to `maxDelay`. After `maxFailures` in a row the fleet is dropped from the queue (its players are idle and may
/// join again), so a fleet that can never start (a player the store refuses, say) doesn't hold up everyone behind it.
/// Each try costs a race id, a wind seed and, in the store, a race row registered and cancelled: the delays bound that.
/// A full server is not a failure: nothing is drawn, nothing counted, and the fleet locks at the first step with room.
public struct LaunchRetry: Sendable, Equatable {
    public var firstDelay: TimeInterval = 2
    public var maxDelay: TimeInterval = 30
    public var maxFailures = 5

    public init() {}

    /// The wait after the `failures`th failure in a row (1…).
    public func delay(afterFailure failures: Int) -> TimeInterval {
        min(maxDelay, firstDelay * pow(2, Double(max(failures, 1) - 1)))
    }
}

/// A fleet that has locked: the race to start.
public struct LockedFleet: Sendable {
    public let raceID: UUID
    public let setup: RaceSetup
    public let windSeed: WindSeed
    /// In seat order: seat `i` is `humans[i]`; the seats after them are bots.
    public let humans: [AccountPlayer]
    public let drawn: DrawnRace
    /// Each human's rating at lock, in seat order (`RatingSource`; 1500 for everyone until #151).
    public let ratings: [Int]
    /// The fleet's bots (#149): rated at the median of `ratings`, give or take 150.
    public let fill: FleetFill
    /// Hears each human who leaves the race before the gun (the queue's briefing-leave count, #147).
    public var onBriefingLeave: (@Sendable (BriefingLeave) -> Void)?
    /// Hears each human who leaves the race for good after the gun (#149): the queue frees her.
    public var onLeftAfterGun: (@Sendable (_ seat: Int) -> Void)?
    /// Hears the gun, with the humans at it (#152): the lobby's gun line.
    public var onGun: (@Sendable (_ humansAtGun: Int) -> Void)?

    public init(raceID: UUID, setup: RaceSetup, windSeed: WindSeed, humans: [AccountPlayer], drawn: DrawnRace, ratings: [Int]? = nil) {
        self.raceID = raceID
        self.setup = setup
        self.windSeed = windSeed
        self.humans = humans
        self.drawn = drawn
        let ratings = ratings ?? Array(repeating: OnlineBriefing.provisionalRating, count: humans.count)
        self.ratings = ratings
        fill = FleetFill(humanRatings: ratings, fallback: OnlineBriefing.provisionalRating)
    }

    /// A race's roster at fleet lock (#149): the humans by name in seat order (`humans[i]` in seat `i`), each bot seat
    /// under its sailing name (`BotDressing`, what a client derives from the setup alone) and marked a bot.
    public static func roster(setup: RaceSetup, humans: [String]) -> [RosterEntry] {
        let dressing = BotDressing(setup: setup)
        return setup.seats.indices.map { seat in
            if let name = dressing.names[seat] { return RosterEntry(name: name, colorIndex: seat, isBot: true) }
            return RosterEntry(name: humans.indices.contains(seat) ? humans[seat] : "Seat \(seat + 1)", colorIndex: seat)
        }
    }
}

/// A player's rating, for the fleet's median (#149) and the briefing. #151 supplies the real one; until then nobody
/// passes one and everyone is `OnlineBriefing.provisionalRating`. One that throws counts as that rating too.
public typealias RatingSource = @Sendable (AccountPlayer) async throws -> Int

/// Starts a locked fleet's race; calls `closed` once when it closes. Throws if it can't be started.
public typealias RaceLauncher = @Sendable (_ fleet: LockedFleet, _ closed: @escaping @Sendable () -> Void) async throws -> Void

/// Tells the race lifecycle that a player gave her seat in a race up for good (`RaceLifecycle.seatReleased`).
public typealias SeatReleased = @Sendable (_ playerID: String, _ race: UUID) async -> Void

/// A queued player, since when.
/// What the queue tells the measures (#157, #28): who joined, how long each waited, the fleets it locked, and the
/// briefing leaves.
public enum QueueEvent: Sendable, Equatable {
    case joined(String)
    /// Out of the queue before her fleet locked: she left, or her connection went.
    case left(String, waited: TimeInterval)
    /// Her fleet locked, with this many humans in it.
    case matched(String, waited: TimeInterval, humans: Int)
    case fleetLocked(humans: Int, boats: Int)
    /// She left a race between lock and gun; `cooldown`: the cooldown it started, 0 if none.
    case briefingLeave(String, cooldown: TimeInterval)
}

public struct QueueEntry: Sendable, Equatable {
    public let player: AccountPlayer
    public let joinedAt: Date
}

/// The ratings of a locking fleet's humans, by player, in one read (#151): the server's rating store. A player it
/// doesn't name is new (the provisional rating). If it throws, or takes longer than a restrictions read may, everyone
/// counts as that: a fleet never waits on it.
public typealias FleetRatingSource = @Sendable ([AccountPlayer]) async throws -> [String: Int]

/// Splits the queue into rating bands, best first (#146: a stub until ratings exist).
public typealias RatingBands = @Sendable ([QueueEntry]) -> [[QueueEntry]]

/// The queue's bookkeeping, no clock and no I/O: who is queued since when, and when the fleet locks.
struct QueueBook: Sendable {
    typealias Entry = QueueEntry

    private(set) var entries: [Entry] = []
    /// A hold on the lock for a running race's finishers (G2), and whose wait it is: it applies only while she is the
    /// oldest queued.
    var hold: (oldest: Entry, hold: CatchFinishers.Hold)?

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

    /// The hold, if it is for the oldest queued now.
    var currentHold: CatchFinishers.Hold? {
        guard let hold, let oldest = entries.first, hold.oldest == oldest else { return nil }
        return hold.hold
    }

    /// When the fleet locks: at once with `fleetCap` humans, else at the hold for a running race's finishers, else
    /// `lockAfter` after the oldest joined. Nil when empty.
    func lockTime(_ settings: QueueSettings) -> Date? {
        guard let oldest = entries.first else { return nil }
        if entries.count >= settings.fleetCap { return oldest.joinedAt }
        return currentHold?.lockAt ?? oldest.joinedAt + settings.lockAfter
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
    /// The state streams players hold, registered and removed synchronously (#469).
    nonisolated let watchers = StreamWatchers<QueueState>()
    /// Suspensions, failed attestations and cooldowns, stored (#147).
    public nonisolated let restrictions: any RestrictionStore
    /// Counts briefing leaves into cooldowns.
    public nonisolated let briefingLeaves: BriefingLeaveTracker
    /// The races the queue catches finishers from (G2); nil: none.
    private let runningRaces: (any RunningRaces)?
    /// Each human's stored livery (#21), for the briefing; nil, or none stored: a starter livery.
    private let liveries: LiverySource?
    /// Each human's rating (#149, #151); nil: everyone's is the provisional rating.
    private let ratings: RatingSource?
    /// The same, for the whole fleet in one read (#151): the server's. Used instead of `ratings` when given.
    private let fleetRatings: FleetRatingSource?
    /// Hears each seat the queue frees before its race closes (the lifecycle's, #469); nil: nobody.
    private let seatReleased: SeatReleased?
    /// Each watched, queued or locked player's restrictions as last read from the store: what the queue shows and
    /// decides by. Read when she starts watching (again each time, #469), when she joins, each step while she is
    /// queued, on a briefing leave and on `restrictionsChanged`. Nobody else's is kept: `evictUnusedRestrictions`.
    private var restricted: [String: PlayerRestrictions] = [:]
    /// How many players' restrictions are cached, for tests.
    var cachedRestrictions: Int { restricted.count }
    /// Hears each fleet lock, release and close, and each gun (#152: the lobby's silence window and gun line); nil: nobody.
    private let lobby: (any LobbyRaceEvents)?
    /// Launches that failed in a row, and when the fleet at the head may be tried again (`LaunchRetry`).
    private var launchFailures = 0
    private var retryAt: Date?
    /// Fleets dropped after `launchRetry.maxFailures` failed launches: for tests and logs.
    public private(set) var fleetsDropped = 0
    /// Fleets locked, and the last one: for tests and logs.
    public private(set) var fleetsLocked = 0
    public private(set) var lastFleet: LockedFleet?
    private var driver: Task<Void, Never>?
    private var stopped = false
    /// Hears what the measures count (#157); nil: nobody.
    private let events: (@Sendable (QueueEvent) -> Void)?

    public init(settings: QueueSettings, registry: RaceRegistry, draw: RaceDraw, tokenKey: SymmetricKey, tokenLifetime: TimeInterval,
                random: SeededRandom = .system(), now: @escaping @Sendable () -> Date = { Date() },
                bands: @escaping RatingBands = { [$0] },
                restrictions: any RestrictionStore = InMemoryRestrictionStore(), runningRaces: (any RunningRaces)? = nil,
                liveries: LiverySource? = nil, ratings: RatingSource? = nil, fleetRatings: FleetRatingSource? = nil,
                seatReleased: SeatReleased? = nil, lobby: (any LobbyRaceEvents)? = nil, launch: RaceLauncher? = nil,
                events: (@Sendable (QueueEvent) -> Void)? = nil) {
        self.settings = settings
        self.registry = registry
        self.draw = draw
        self.tokenKey = tokenKey
        self.tokenLifetime = tokenLifetime
        self.random = random
        self.now = now
        self.bands = bands
        self.restrictions = restrictions
        self.runningRaces = runningRaces
        self.liveries = liveries
        self.ratings = ratings
        self.fleetRatings = fleetRatings
        self.seatReleased = seatReleased
        self.lobby = lobby
        self.events = events
        briefingLeaves = BriefingLeaveTracker(store: restrictions, rule: settings.briefingLeaves, now: now)
        self.launch = launch ?? Self.registryLauncher(registry)
    }

    /// Starts each race on `registry`, on the wall clock.
    public static func registryLauncher(_ registry: RaceRegistry) -> RaceLauncher {
        { fleet, closed in
            let session = RaceSession(id: fleet.raceID, setup: fleet.setup, windSeed: fleet.windSeed,
                                      roster: LockedFleet.roster(setup: fleet.setup, humans: fleet.humans.map(\.alias)),
                                      onBriefingLeave: fleet.onBriefingLeave, fleet: fleet.fill, onLeftAfterGun: fleet.onLeftAfterGun,
                                      onGun: fleet.onGun)
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
        watchers.finishAll()
    }

    /// Time has moved: re-reads the queued players' restrictions (one suspended or flagged meanwhile leaves the queue),
    /// moves the hold for a running race's finishers, locks a fleet that is due, and pushes
    /// the countdown (and cooldowns running out) to everyone watching.
    ///
    /// The whole queue's restrictions are one store read, bounded by `restrictionReadTimeout` (#469), so the lock is
    /// never later than that. A read that fails changes nothing: each queued player keeps what was read last (she had
    /// a good read when she joined). One with nothing ever read leaves the queue: unknown is no leave to race.
    public func step() async {
        await loadRestrictions(book.entries.map(\.player.teamPlayerID))
        let readAt = now()
        for entry in book.entries {
            let id = entry.player.teamPlayerID
            if restricted[id].map({ $0.refusal(at: readAt) != nil }) ?? true { book.remove(id) }
        }
        await refreshHold()
        await lockIfDue()
        pushAll()
    }

    /// Re-decides the hold for a running race's finishers (G2) from each running race's expected close now.
    private func refreshHold() async {
        guard let rule = settings.catchFinishers, let runningRaces, let oldest = book.entries.first,
              book.count < settings.fleetCap else { return }
        let running = await runningRaces.runningRaces()
        // The queue may have moved while the races were read.
        guard book.entries.first == oldest else { return }
        let time = now()
        let closes = running.map { (id: $0.id, close: time + Double($0.ticksToClose) / Double(Race.tickRate)) }
        book.hold = rule.hold(oldestJoinedAt: oldest.joinedAt, lockAfter: settings.lockAfter, races: closes, current: book.currentHold)
            .map { (oldest, $0) }
    }

    /// Reads the players' restrictions from the store, all in one read of at most `restrictionReadTimeout`. False if
    /// it failed or took too long: then what was read last stays as it is.
    @discardableResult
    private func loadRestrictions(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return true }
        do {
            let store = restrictions
            let read = try await withDeadline(settings.restrictionReadTimeout) { try await store.restrictions(of: ids) }
            for id in ids { restricted[id] = read[id] ?? PlayerRestrictions.none }
            return true
        } catch {
            FileHandle.standardError.write(Data("RegattaServer: can't read the restrictions of \(ids.count) player(s): \(error)\n".utf8))
            return false
        }
    }

    @discardableResult
    private func loadRestrictions(_ id: String) async -> Bool { await loadRestrictions([id]) }

    /// The player's restrictions changed in the store (#153's suspension, #158's attestation): re-read them; one now
    /// refused leaves the queue.
    public func restrictionsChanged(_ id: String) async {
        await loadRestrictions(id)
        if restricted[id]?.refusal(at: now()) != nil { book.remove(id) }
        pushAll()
    }

    // MARK: The queue

    /// What the queue looks like to `id` now. For a player whose restrictions aren't cached (she isn't watching, queued
    /// or locked) they are read for this answer and not kept.
    public func state(of id: String) async -> QueueState {
        if restricted[id] == nil { await loadRestrictions(id) }
        defer { evictUnusedRestrictions() }
        return cachedState(of: id)
    }

    /// The state from the cached restrictions and the book as they are.
    private func cachedState(of id: String) -> QueueState {
        let time = now()
        if let refusal = restricted[id]?.refusal(at: time) { return .unavailable(refusal) }
        if handOffs[id] != nil { return .fleetLocked }
        if let fleet = starting[id] { return .queued(QueuedStatus(queuedPlayers: fleet, secondsToLock: 0)) }
        if book.contains(id), let seconds = book.secondsToLock(at: time, settings) {
            return .queued(QueuedStatus(queuedPlayers: book.count, secondsToLock: seconds))
        }
        return .idle
    }

    /// Joins the queue. Throws `QueueError` for a refusal, and `RestrictionsUnreadable` when her restrictions can't be
    /// read now (#469, failing closed: what was read earlier isn't enough to let her in).
    public func join(_ player: AccountPlayer) async throws {
        let id = player.teamPlayerID
        let read = await loadRestrictions(id)
        defer { evictUnusedRestrictions() }
        guard read else { throw RestrictionsUnreadable() }
        switch cachedState(of: id) {
        case .unavailable(let refusal): throw QueueError.refused(refusal)
        case .queued, .fleetLocked: throw QueueError.alreadyQueued
        case .idle: break
        }
        book.add(player, at: now())
        events?(.joined(id))
        await refreshHold()
        await lockIfDue()
        pushAll()
    }

    public func leave(_ id: String) throws(QueueError) {
        let joined = book.entries.first { $0.player.teamPlayerID == id }?.joinedAt
        guard book.remove(id) else { throw .notQueued }
        if let joined { events?(.left(id, waited: now().timeIntervalSince(joined))) }
        pushAll()
    }

    /// The player's connection ended: a place in the queue goes with it (leaving is free). A locked seat stays.
    public func dropped(_ id: String) {
        let joined = book.entries.first { $0.player.teamPlayerID == id }?.joinedAt
        guard book.remove(id) else { return }
        if let joined { events?(.left(id, waited: now().timeIntervalSince(joined))) }
        pushAll()
    }

    /// Her online data is being deleted (#160): she leaves the queue, and gives up any seat she holds, as a player
    /// who leaves does (a bot takes it before the gun), so no race registers her once her row is gone.
    public func forget(_ id: String) async {
        book.remove(id)
        for (race, players) in races {
            if let seat = players.firstIndex(of: id) { await releaseSeat(race, seat: seat) }
        }
        pushAll()
    }

    /// Players queued now.
    public var queuedCount: Int { book.count }

    // MARK: Fleet lock

    /// Locks the fleet if its time has come, unless its last launch failed and its next try isn't due yet.
    private func lockIfDue() async {
        let time = now()
        guard book.isLockDue(at: time, settings) else { return }
        if let retryAt, time < retryAt { return }
        await lockFleet(at: time)
    }

    /// Locks the fleet at the head of the queue and starts its race. `forced` (dev): whether or not its time has come.
    private func lockFleet(at time: Date, forced: Bool = false) async {
        // A full server (#469): nothing is drawn (no race id, no wind seed, no race row) and the fleet waits where it
        // is, to lock at the first step with room. The queue may have moved while the registry was asked.
        guard await registry.count < registry.maxRaces else { return }
        guard forced || book.isLockDue(at: now(), settings) else { return }
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
            launchFailed(fleet, error)
            return
        }
        // While the race starts (the actor is free meanwhile) the fleet shows as queued with nothing left on the clock:
        // `.fleetLocked` and the hand-off come only once its race is in the registry, so a token always finds its race.
        for player in humans { starting[player.teamPlayerID] = humans.count }
        races[raceID] = humans.map(\.teamPlayerID)
        var locked = LockedFleet(raceID: raceID, setup: setup, windSeed: drawn.windSeed, humans: humans, drawn: drawn,
                                 ratings: await ratings(of: humans))
        locked.onBriefingLeave = { leave in Task { await self.briefingLeave(raceID, leave) } }
        locked.onLeftAfterGun = { seat in Task { await self.releaseSeat(raceID, seat: seat) } }
        // The lobby (#152): the fleet is silent from here; the gun's line comes from the race itself.
        let lobby = lobby, venue = drawn.pairing.venue.content.displayName, boats = setup.fleetSize
        locked.onGun = { humans in lobby?.gun(race: raceID, venue: venue, boats: boats, humans: humans) }
        lobby?.fleetLocked(race: raceID, humans: humans.map(\.teamPlayerID))
        do {
            try await launch(locked) { Task { await self.raceClosed(raceID) } }
        } catch {
            // The race couldn't start. Its wind seed stays retired.
            for player in humans { starting[player.teamPlayerID] = nil }
            races[raceID] = nil
            lobby?.raceEnded(race: raceID, players: humans.map(\.teamPlayerID))
            launchFailed(fleet, error)
            pushAll()
            return
        }
        launchFailures = 0
        retryAt = nil
        var stored: [Livery?] = []
        for player in humans { stored.append(await liveries?(player)) }
        let briefings = OnlineBriefing.payloads(locked, stored: stored, settings: settings)
        let expiry = Int64((time + tokenLifetime).timeIntervalSince1970)
        for (seat, player) in humans.enumerated() {
            starting[player.teamPlayerID] = nil
            guard let bytes = RaceToken(raceID: raceID, seat: seat, expiresAt: expiry).signed(with: tokenKey) else { continue }
            handOffs[player.teamPlayerID] = HandOff(raceID: RaceID(raceID.uuidString.lowercased()), token: RegattaServices.RaceToken(bytes: bytes),
                                                    briefing: briefings[seat])
        }
        fleetsLocked += 1
        lastFleet = locked
        for entry in fleet { events?(.matched(entry.player.teamPlayerID, waited: time.timeIntervalSince(entry.joinedAt), humans: humans.count)) }
        events?(.fleetLocked(humans: humans.count, boats: setup.fleetSize))
        pushAll()
    }

    /// The fleet's race couldn't start (`LaunchRetry`): back to the head of the queue until its next try, or, after too
    /// many failures in a row, out of the queue. Losing the server's last place to another race isn't the fleet's
    /// failure: it waits `firstDelay` and nothing is counted.
    private func launchFailed(_ fleet: [QueueEntry], _ error: any Error) {
        let retry = settings.launchRetry, time = now()
        if error as? RaceRegistry.StartError == .full {
            book.restore(fleet)
            retryAt = time + retry.firstDelay
            return
        }
        launchFailures += 1
        let players = fleet.map(\.player.teamPlayerID).joined(separator: ", ")
        guard launchFailures < retry.maxFailures else {
            launchFailures = 0
            retryAt = nil
            fleetsDropped += 1
            FileHandle.standardError.write(Data("RegattaServer: a race couldn't start \(retry.maxFailures) times; its fleet is dropped from the queue (\(players)): \(error)\n".utf8))
            return
        }
        book.restore(fleet)
        let delay = retry.delay(afterFailure: launchFailures)
        retryAt = time + delay
        FileHandle.standardError.write(Data("RegattaServer: a race couldn't start (failure \(launchFailures)); next try in \(Int(delay)) s (\(players)): \(error)\n".utf8))
    }

    /// Each human's rating, in seat order, for the fleet's median and the briefing (#149). One the source can't give
    /// (it throws, or takes longer than a restrictions read may) is the provisional rating: a fleet never waits on it.
    private func ratings(of humans: [AccountPlayer]) async -> [Int] {
        if let fleetRatings {
            do {
                let read = try await withDeadline(settings.restrictionReadTimeout) { try await fleetRatings(humans) }
                return humans.map { read[$0.teamPlayerID] ?? OnlineBriefing.provisionalRating }
            } catch {
                FileHandle.standardError.write(Data("RegattaServer: can't read the fleet's ratings: \(error)\n".utf8))
                return Array(repeating: OnlineBriefing.provisionalRating, count: humans.count)
            }
        }
        guard let source = ratings else { return Array(repeating: OnlineBriefing.provisionalRating, count: humans.count) }
        var read: [Int] = []
        for player in humans {
            do {
                read.append(try await withDeadline(settings.restrictionReadTimeout) { try await source(player) })
            } catch {
                FileHandle.standardError.write(Data("RegattaServer: can't read the rating of \(player.teamPlayerID): \(error)\n".utf8))
                read.append(OnlineBriefing.provisionalRating)
            }
        }
        return read
    }

    /// A human left the race between lock and gun (#147): it counts towards her cooldown. One who left for good is free
    /// to queue again at once (after any cooldown); one whose seat was empty at the gun can still rejoin it (#66).
    func briefingLeave(_ raceID: UUID, _ leave: BriefingLeave) async {
        guard let players = races[raceID], players.indices.contains(leave.seat), !players[leave.seat].isEmpty else { return }
        let id = players[leave.seat]
        let cooldown = await briefingLeaves.recordLeave(id, race: raceID)
        events?(.briefingLeave(id, cooldown: cooldown == nil ? 0 : briefingLeaves.rule.cooldown))
        if leave.kind == .left { await releaseSeat(raceID, seat: leave.seat) }
        await loadRestrictions(id)
        pushAll()
    }

    /// The player in `seat` of the race gave it up for good: she is free to queue again at once, and the lifecycle
    /// hears that the race is no longer hers (#469), so its close can't touch the race she queues into next. Called
    /// for a leave before the gun (after it is counted), and for a `LeaveRace` after the gun (#149,
    /// `LockedFleet.onLeftAfterGun`), which counts nothing. Nothing for a seat already released.
    func releaseSeat(_ raceID: UUID, seat: Int) async {
        defer { pushAll() }
        guard let players = races[raceID], players.indices.contains(seat), !players[seat].isEmpty else { return }
        let id = players[seat]
        races[raceID]?[seat] = ""
        if handOffs[id]?.raceID.rawValue == raceID.uuidString.lowercased() { handOffs[id] = nil }
        lobby?.left(race: raceID, player: id)
        await seatReleased?(id, raceID)
    }

    /// The race closed: its players are free to queue again.
    func raceClosed(_ raceID: UUID) {
        let players = (races.removeValue(forKey: raceID) ?? []).filter { !$0.isEmpty }
        for id in players { handOffs[id] = nil }
        lobby?.raceEnded(race: raceID, players: players)
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
    /// The stream is registered before this returns and removed the moment it ends (#469); its first state comes once
    /// her restrictions are read.
    public nonisolated func stateUpdates(for id: String) -> AsyncStream<QueueState> {
        let (stream, token) = watchers.open(id, bufferingPolicy: .bufferingNewest(1)) { Task { await self.evictUnusedRestrictions() } }
        Task { await self.watch(id, token) }
        return stream
    }

    /// Reads her restrictions afresh (a cached entry may be as old as her last stream, #469) and gives the stream its
    /// first state. A stream that has gone meanwhile gets nothing, and what was read for it isn't kept.
    private func watch(_ id: String, _ token: UUID) async {
        await loadRestrictions(id)
        watchers.prime(id, token, [cachedState(of: id)])
        evictUnusedRestrictions()
    }

    /// Sends each watcher its state, if it changed since the last it was sent.
    private func pushAll() {
        for id in watchers.keys { watchers.sendIfChanged(cachedState(of: id), to: id) }
        evictUnusedRestrictions()
    }

    /// Forgets the cached restrictions of every player who is neither queued, locked nor watching (#469): the cache
    /// holds no more than the connections and the fleets do.
    private func evictUnusedRestrictions() {
        guard !restricted.isEmpty else { return }
        let queued = Set(book.entries.map(\.player.teamPlayerID))
        restricted = restricted.filter { id, _ in
            queued.contains(id) || handOffs[id] != nil || starting[id] != nil || watchers.isWatched(id)
        }
    }

    // MARK: Dev arrangements (#146 Q1)

    /// Dev only (`POST /dev/situation`): a queue cooldown of `seconds` for the player, written to the store.
    public func arrangeCooldown(_ id: String, seconds: TimeInterval) async {
        try? await restrictions.setCooldown(id, until: now() + seconds)
        await restrictionsChanged(id)
    }

    /// Whether the player's livery is locked (#21, #159): from her fleet's lock until its race closes, unless she gave
    /// her seat up.
    public func holdsLivery(_ id: String) -> Bool {
        starting[id] != nil || races.values.contains { $0.contains(id) }
    }

    /// Dev only (`POST /dev/situation`, #148): the queue locks now with the player in it, so the RaceSession contract's
    /// `fleetLocked` has a hand-off without waiting out `lockAfter`.
    /// Returns the race, if one locked with her in it.
    @discardableResult
    public func arrangeLock(_ player: AccountPlayer) async -> UUID? {
        if !book.contains(player.teamPlayerID) { book.add(player, at: now()) }
        await lockFleet(at: now(), forced: true)
        return races.first { $0.value.contains(player.teamPlayerID) }?.key
    }

    /// Dev only (#152): she gives her seat in `race` up, as a `LeaveRace` after the gun does.
    public func arrangeRelease(_ player: String, race: UUID) async {
        guard let seat = races[race]?.firstIndex(of: player) else { return }
        await releaseSeat(race, seat: seat)
    }

    /// Dev only: an online racing suspension until `until` (Unix seconds), nil for permanent, written to the store.
    public func arrangeSuspension(_ id: String, until: Int64?) async {
        try? await restrictions.setSuspension(id, StoredSuspension(until: until.map { Date(timeIntervalSince1970: Double($0)) }))
        await restrictionsChanged(id)
    }
}
