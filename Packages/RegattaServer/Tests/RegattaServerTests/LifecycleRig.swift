import Crypto
import Foundation
import Persistence
import RegattaLoadClient
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// The suites that sail races by hand (#148), one at a time: each simulates a few hundred ticks per test, and run side by
/// side they starve the cooperative pool the wall-clock tests (idle and sign-in deadlines) time themselves on.
@Suite(.serialized) enum RaceSims {}

/// A host clock a test moves by hand (microseconds).
final class ManualHostClock: HostClock {
    private let time = Mutex<UInt64>(1_000_000)
    func now() -> UInt64 { time.withLock { $0 } }
    func set(_ now: UInt64) { time.withLock { $0 = max($0, now) } }
}

/// A seat transport that keeps what the host sent.
final class KeptTransport: SeatTransport {
    private let state = Mutex<(frames: [[UInt8]], closed: Bool)>(([], false))
    func send(_ frame: [UInt8]) { state.withLock { $0.frames.append(frame) } }
    func close() { state.withLock { $0.closed = true } }
    var isClosed: Bool { state.withLock { $0.closed } }
    var messages: [Message] { state.withLock { $0.frames }.compactMap { try? Frame(decoding: $0).message } }
}

/// Sessions a lifecycle started, without driving them: a test steps each host on its clock and hands its end to the
/// lifecycle as the registry would.
actor StartedRaces {
    private(set) var sessions: [RaceSession] = []
    private var enders: [UUID: @Sendable (RaceEnd) -> Void] = [:]

    func started(_ session: RaceSession, _ ended: @escaping @Sendable (RaceEnd) -> Void) {
        sessions.append(session)
        enders[session.id] = ended
    }

    /// Calls the registry's `onClose` for the session, with how its host ended.
    func end(_ session: RaceSession) async {
        guard let ended = enders.removeValue(forKey: session.id) else { return }
        ended(await LifecycleRig.end(of: session))
    }
}

/// What the queue and the lifecycle told the lobby (#152), in order.
final class RecordingLobby: LobbyRaceEvents {
    enum Event: Equatable, Sendable {
        case locked([String])
        case finished(String)
        case left(String)
        case ended([String])
        case gun(venue: String, boats: Int, humans: Int)
        case winner(venue: String, nickname: String, playerID: String)
    }

    let events = Kept<Event>()

    func fleetLocked(race: UUID, humans: [String]) { events.append(.locked(humans)) }
    func finished(race: UUID, player: String) { events.append(.finished(player)) }
    func left(race: UUID, player: String) { events.append(.left(player)) }
    func raceEnded(race: UUID, players: [String]) { events.append(.ended(players)) }
    func gun(race: UUID, venue: String, boats: Int, humans: Int) { events.append(.gun(venue: venue, boats: boats, humans: humans)) }
    func winner(race: UUID, venue: String, nickname: String, playerID: String) {
        events.append(.winner(venue: venue, nickname: nickname, playerID: playerID))
    }

    /// The system lines the lobby would post, in order (a gun with no humans is none).
    var lines: [SystemLine] {
        events.all.compactMap { event in
            switch event {
            case .gun(let venue, let boats, let humans): humans > 0 ? .gun(venue: venue, boats: boats, humans: humans) : nil
            case .winner(let venue, let nickname, _): .winner(venue: venue, nickname: nickname)
            default: nil
            }
        }
    }
}

/// The in-memory archive with a close that can fail, or wait until it is let go (#469).
final class FaultyArchive: RaceArchive {
    struct Refused: Error {}

    let inner: InMemoryRaceArchive
    private let state = Mutex<(closeFailures: Int, closes: Int, held: Bool, waiting: [CheckedContinuation<Void, Never>])>((0, 0, false, []))

    init(_ inner: InMemoryRaceArchive) { self.inner = inner }

    /// The next `times` closes fail.
    func failCloses(_ times: Int) { state.withLock { $0.closeFailures = times } }
    /// Closes asked for, failed or not.
    var closes: Int { state.withLock { $0.closes } }
    /// Closes wait, from now until `letGo()`.
    func hold() { state.withLock { $0.held = true } }
    func letGo() {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            state.held = false
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    @discardableResult
    func close(_ race: ClosedRaceRecord) async throws -> Persistence.RatingOutcome {
        let fails = state.withLock { state -> Bool in
            state.closes += 1
            guard state.closeFailures > 0 else { return false }
            state.closeFailures -= 1
            return true
        }
        if fails { throw Refused() }
        await withCheckedContinuation { continuation in
            let held = state.withLock { state -> Bool in
                if state.held { state.waiting.append(continuation) }
                return state.held
            }
            if !held { continuation.resume() }
        }
        return try await inner.close(race)
    }

    func register(_ race: UUID, players: [RaceSeatHolder]) async throws { try await inner.register(race, players: players) }
    func cancel(_ race: UUID) async throws { try await inner.cancel(race) }
    func cancelOrphans() async throws -> [UUID] { try await inner.cancelOrphans() }
    func state(of race: UUID) async throws -> RaceState? { try await inner.state(of: race) }
    func lastRace(of playerID: String) async throws -> StoredRaceResult? { try await inner.lastRace(of: playerID) }
    func closedRace(_ race: UUID) async throws -> ClosedRaceRecord? { try await inner.closedRace(race) }
}

/// #148's lifecycle over an in-memory archive, its races driven by hand on a manual clock.
struct LifecycleRig {
    static let key = SymmetricKey(size: .bits256)
    let clock = ManualHostClock()
    let archive = InMemoryRaceArchive()
    /// What the lifecycle writes through: `archive`, with faults a test asks for.
    let faults: FaultyArchive
    let started = StartedRaces()
    let lifecycle: RaceLifecycle

    /// The players each rated close reported (the leaderboard mirror's hook, #151).
    let ratedPlayers = Kept<[String]>()
    /// What the lifecycle told the lobby (#152).
    let lobby = RecordingLobby()

    /// `completed`: hears the players who completed each close (#159).
    init(settings: RaceLifecycleSettings = RaceLifecycleSettings(), now: @escaping @Sendable () -> Date = { Date() },
         completed: (@Sendable ([String]) async -> Void)? = nil) {
        let started = started, ratedPlayers = ratedPlayers
        faults = FaultyArchive(archive)
        lifecycle = RaceLifecycle(settings: settings, archive: faults, tokenKey: Self.key, tokenLifetime: 600, toolchain: "test", now: now,
                                  rated: { ratedPlayers.append($0) }, completed: completed, lobby: lobby,
                                  start: { session, ended in await started.started(session, ended) })
    }

    /// Settings with a short all-gone grace, for races that only need to end.
    static func quickGrace(_ policy: SimultaneousLossPolicy = .cancel) -> RaceLifecycleSettings {
        var settings = RaceLifecycleSettings()
        settings.allGone.graceTicks = 30
        settings.allGone.simultaneousLossPolicy = policy
        return settings
    }

    /// A race for `players` in seats 0…, bots after them to `seats`, started (not driven) through the lifecycle, as a
    /// queue race (`announces`: the lobby hears of it) unless told otherwise.
    func race(_ players: [String], seats: Int = 4, startSequenceTicks: Int = 60, seed: UInt64 = 148,
              announces: Bool = true) async throws -> RaceSession {
        let kinds: [SeatKind] = (0..<seats).map { $0 < players.count ? .human : .bot }
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: kinds, laps: 1, startSequenceTicks: startSequenceTicks)
        let session = lifecycle.session(id: UUID(), setup: setup, windSeed: WindSeed(seed), names: players.map { "N" + $0 }, clock: clock)
        try await lifecycle.launch(session, players: players, venue: "Test Bay", announces: announces)
        return session
    }

    /// Simulates to `tick`.
    func run(_ session: RaceSession, to tick: Int) async {
        clock.set(await session.host.time(ofTick: tick))
        await session.host.advance()
    }

    /// Simulates to `tick`, `seats` holding a straight helm (an input every 10 ticks, inside the 0.5 s hold).
    func sail(_ session: RaceSession, _ seats: [Int], to tick: Int, seq: inout UInt32) async {
        var now = await session.host.tick
        while now < tick {
            for seat in seats {
                seq += 1
                let frame = try! Frame(seq: seq, tick: now + 1, message: .inputHeld(BoatInput(rudder: 0 as Int8))).encoded()
                await session.host.receive(frame, from: seat)
            }
            now = min(now + 10, tick)
            await run(session, to: now)
        }
    }

    /// Steps until the host ends, at most to `limit`.
    func runUntilEnded(_ session: RaceSession, limit: Int) async {
        var tick = await session.host.tick
        while await !session.host.isEnded, tick < limit {
            tick += 30
            await run(session, to: tick)
        }
    }

    /// How the session's host ended, as `RaceSession.run` reports it.
    static func end(of session: RaceSession) async -> RaceEnd {
        if let reason = await session.host.cancelled { return .cancelled(reason) }
        return .closed(await session.host.close())
    }

    /// Hands the race's end to the lifecycle, and waits for the close pipeline.
    func end(_ session: RaceSession) async {
        await lifecycle.ended(session.id, Self.end(of: session))
    }
}

/// A race connection that says Hello, sends `JoinRace` with `token`, and returns what the server said after `HelloAck`
/// until it closed the connection.
enum RaceConnectionProbe {
    static func join(_ token: [UInt8], port: Int) async throws -> [Message] {
        let transport = try await WebSocketRaceTransport.connect(host: "127.0.0.1", port: port, clock: { 0 })
        transport.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded())
        transport.send(try Frame(seq: 2, tick: 0, message: .joinRace(JoinRace(token: token))).encoded())
        var messages: [Message] = []
        for _ in 0..<300 where transport.isConnected {
            messages += try transport.receive().map { try Frame(decoding: $0).message }
            try await Task.sleep(for: .milliseconds(10))
        }
        messages += try transport.receive().map { try Frame(decoding: $0).message }
        await transport.close()
        return messages.filter { $0.type != .helloAck }
    }
}

/// Reads a stream's items until `isLast` or `seconds` pass.
func collect<Element: Sendable>(_ stream: AsyncStream<Element>, seconds: Double = 30,
                                until isLast: @escaping @Sendable (Element) -> Bool) async -> [Element] {
    let items = Kept<Element>()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await item in stream {
                items.append(item)
                if isLast(item) { break }
            }
        }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
        await group.next()
        group.cancelAll()
    }
    return items.all
}

/// Items a reader keeps, readable from another task.
final class Kept<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    func append(_ item: Element) { items.withLock { $0.append(item) } }
    var all: [Element] { items.withLock { $0 } }
}
