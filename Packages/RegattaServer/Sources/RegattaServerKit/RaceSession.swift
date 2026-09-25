import Foundation
import RaceHost
import RegattaCore
import RegattaDevAPI
import Synchronization

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
    /// The connection holding each seat, so a stale connection's goodbye can't drop a newer one.
    private var holders: [Int: ObjectIdentifier] = [:]
    /// Seats a join is claiming right now. `join` suspends on the host, and the actor is reentrant, so a
    /// second join for the seat (one token, two sockets) is refused here rather than racing the first.
    private var claiming: Set<Int> = []

    public init(id: UUID = UUID(), setup: RaceSetup, windSeed: WindSeed, closeAtTick: Int? = nil,
                clock: any HostClock = SystemClock(), options: RaceHostOptions = RaceHostOptions()) {
        self.id = id
        self.setup = setup
        self.closeAtTick = closeAtTick
        self.clock = clock
        humanSeats = Set(setup.seats.indices.filter { setup.seats[$0] == .human })
        host = RaceHost(setup: setup, windSeed: windSeed, clock: clock, options: options,
                        windKeyReveal: Self.windKeyReveal(setup: setup, windSeed: windSeed))
    }

    /// A race for the instant-race endpoint: the clients in seats 0…n−1, bots after them up to
    /// `botFillTo` seats (none if there are more clients), one lap.
    public static func instant(_ request: InstantRaceRequest, id: UUID = UUID(), clock: any HostClock = SystemClock()) throws -> RaceSession {
        let seed = request.seed ?? UInt64.random(in: .min ... .max)
        let seats: [SeatKind] = (0..<request.fleetSize).map { $0 < request.clients ? .human : .bot }
        let startTicks = (request.startSeconds ?? RaceSetup.defaultStartSequenceTicks / Race.tickRate) * Race.tickRate
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: seats, laps: 1, startSequenceTicks: startTicks)
        let closeAt = request.raceSeconds.map { $0 * Race.tickRate }
        return RaceSession(id: id, setup: setup, windSeed: WindSeed(seed ^ 0x5EED_5EED_5EED_5EED), closeAtTick: closeAt, clock: clock)
    }

    /// Reveals wind key k once the race has simulated tick `windowStart(k) − 30`: a second ahead (ADR 0001).
    /// Interim schedule until #95 owns it; the same one the client's tests script.
    static func windKeyReveal(setup: RaceSetup, windSeed: WindSeed) -> RaceHost.WindKeyReveal {
        let race = Race(setup: setup, windSeed: windSeed)
        guard let generator = try? WindKeyGenerator(windSeed: windSeed, setup: race.windSetup, windows: race.wind.windows) else {
            return { _ in [] }
        }
        let state = Mutex(generator)
        return { tick in
            state.withLock { generator in
                var keys: [WindKey] = []
                while generator.windows.start(of: generator.nextWindow) - revealLeadTicks <= tick {
                    keys.append(generator.next())
                }
                return keys
            }
        }
    }

    static let revealLeadTicks = Race.tickRate

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
        guard await host.outcome == nil else { throw .raceClosed }
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
    /// seat's connection. Returns how it closed.
    public func run() async -> RaceOutcome {
        while true {
            guard let next = await host.driveStep(closeAtTick: closeAtTick) else { break }
            let now = clock.now()
            if next > now { try? await Task.sleep(for: .microseconds(next - now), tolerance: .milliseconds(1)) }
            if Task.isCancelled {
                await host.close()
                break
            }
        }
        let outcome = await host.close()
        for seat in humanSeats.sorted() {
            holders[seat] = nil
            await host.disconnect(seat: seat)
        }
        return outcome
    }
}

extension RaceHost {
    /// One pass of the driver: simulates every tick due, closes the race if it's over or at `closeAtTick`,
    /// and says when the next tick is due (host clock), or nil once the race is closed.
    func driveStep(closeAtTick: Int?) -> UInt64? {
        advance()
        if outcome == nil, let closeAtTick, tick >= closeAtTick { close() }
        guard outcome == nil else { return nil }
        return time(ofTick: tick + 1)
    }
}
