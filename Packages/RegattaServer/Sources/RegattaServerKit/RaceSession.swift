import Foundation
import RaceHost
import RegattaCore
import RegattaDevAPI
import RegattaProtocol

/// How a race session ended (#148).
public enum RaceEnd: Sendable {
    /// Closed: sailed to its end, every human gone (`Race.closeAllGone`), or closed where it stood (then
    /// `RaceOutcome.results` is nil).
    case closed(RaceOutcome)
    /// Cancelled: no results (#30).
    case cancelled(RaceCancelled.Reason)
}

/// One race on the server (#31: a race is a self-contained unit): its `RaceHost`, the driver that steps it
/// on the wall clock, which connection holds each seat, and its close. It owns all of its state; races
/// share nothing but the process, so a race can later move to its own process or host (#4).
public actor RaceSession {
    public nonisolated let id: UUID
    public nonisolated let host: RaceHost
    public nonisolated let setup: RaceSetup
    /// Seats a player may join; the rest are bots.
    public nonisolated let humanSeats: Set<Int>
    /// Dev override (#67): the tick at which the race is closed where it stands, if it hasn't ended.
    public nonisolated let closeAtTick: Int?
    private let clock: any HostClock
    /// Told when the results so far change (`RaceHost.resultsVersion`), from the driver (#148).
    private let onProgress: (@Sendable () -> Void)?
    /// The connection holding each seat, so a stale connection's goodbye can't drop a newer one.
    private var holders: [Int: ObjectIdentifier] = [:]
    /// Seats a join is claiming right now. `join` suspends on the host, and the actor is reentrant, so a
    /// second join for the seat (one token, two sockets) is refused here rather than racing the first.
    private var claiming: Set<Int> = []

    /// `roster` names the seats (RaceHost's "Seat n" by default); `onProgress` hears each change to the results so far.
    public init(id: UUID = UUID(), setup: RaceSetup, windSeed: WindSeed, closeAtTick: Int? = nil,
                clock: any HostClock = SystemClock(), options: RaceHostOptions = RaceHostOptions(), roster: [RosterEntry]? = nil,
                onProgress: (@Sendable () -> Void)? = nil) {
        self.id = id
        self.setup = setup
        self.closeAtTick = closeAtTick
        self.clock = clock
        self.onProgress = onProgress
        humanSeats = Set(setup.seats.indices.filter { setup.seats[$0] == .human })
        host = RaceHost(setup: setup, windSeed: windSeed, clock: clock, options: options, roster: roster)
    }

    /// A race for the instant-race endpoint: the clients in seats 0…n−1, bots after them up to
    /// `botFillTo` seats (none if there are more clients), one lap.
    public static func instant(_ request: InstantRaceRequest, id: UUID = UUID(), clock: any HostClock = SystemClock()) throws -> RaceSession {
        let seed = request.seed ?? UInt64.random(in: .min ... .max)
        let seats: [SeatKind] = (0..<request.fleetSize).map { $0 < request.clients ? .human : .bot }
        let startTicks = (request.startSeconds ?? RaceSetup.defaultStartSequenceTicks / Race.tickRate) * Race.tickRate
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: seats, laps: 1, startSequenceTicks: startTicks)
        let closeAt = request.raceSeconds.map { $0 * Race.tickRate }
        return RaceSession(id: id, setup: setup, windSeed: WindSeed(InstantRaceRequest.windSeed(forRaceSeed: seed)), closeAtTick: closeAt, clock: clock)
    }

    // MARK: - Seats

    public enum JoinRefusal: Error, Equatable, Sendable {
        case notAHumanSeat
        case seatTaken
        case raceClosed
    }

    /// Seats `transport` in `seat`: the host sends it the race. Refused for a bot seat, a seat another
    /// connection holds or another join is claiming, or a closed race. (Taking over a seat from a live connection is #66's.)
    public func join(seat: Int, transport: any SeatTransport) async throws(JoinRefusal) {
        guard humanSeats.contains(seat) else { throw .notAHumanSeat }
        guard claiming.insert(seat).inserted else { throw .seatTaken }
        defer { claiming.remove(seat) }
        guard await !host.isEnded else { throw .raceClosed }
        guard await !host.isAttached(seat: seat) else { throw .seatTaken }
        guard await host.attach(seat: seat, transport: transport) else { throw .raceClosed }
        holders[seat] = ObjectIdentifier(transport)
    }

    /// The connection behind `transport` has gone: disconnects its seat, unless another connection holds it now.
    public func leave(seat: Int, transport: any SeatTransport) async {
        guard holders[seat] == ObjectIdentifier(transport) else { return }
        holders[seat] = nil
        await host.disconnect(seat: seat)
    }

    // MARK: - Driving

    /// Steps the race on the wall clock until it ends, or until `closeAtTick`, closes it, and closes every
    /// seat's connection. Returns how it ended: closed, or cancelled (`RaceHost.cancel`, a mass drop).
    public func run() async -> RaceEnd {
        var version = 0
        while true {
            let step = await host.driveStep(closeAtTick: closeAtTick)
            if step.resultsVersion != version {
                version = step.resultsVersion
                onProgress?()
            }
            guard let next = step.next else { break }
            let now = clock.now()
            if next > now { try? await Task.sleep(for: .microseconds(next - now), tolerance: .milliseconds(1)) }
            if Task.isCancelled {
                await host.close()
                break
            }
        }
        if let reason = await host.cancelled {
            holders = [:]
            return .cancelled(reason)
        }
        let outcome = await host.close()
        for seat in humanSeats.sorted() {
            holders[seat] = nil
            await host.disconnect(seat: seat)
        }
        return .closed(outcome)
    }
}

extension RaceHost {
    /// One pass of the driver: simulates every tick due, closes the race if it's over or at `closeAtTick`,
    /// and says when the next tick is due (host clock), or nil once the race is closed or cancelled; and the results
    /// version (`resultsVersion`).
    func driveStep(closeAtTick: Int?) -> (next: UInt64?, resultsVersion: Int) {
        advance()
        if !isEnded, let closeAtTick, tick >= closeAtTick { close() }
        guard !isEnded else { return (nil, resultsVersion) }
        return (time(ofTick: tick + 1), resultsVersion)
    }
}
