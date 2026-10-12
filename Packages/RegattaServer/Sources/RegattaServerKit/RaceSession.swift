import Foundation
import RaceHost
import RegattaBots
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
    /// Whether the close at `closeAtTick` scores the race as it stands (`RaceHost.closeScoredNow`, a queue race's dev
    /// length, #162) or leaves it without results, as the instant race's does.
    public nonisolated let scoresDevClose: Bool
    private let clock: any HostClock
    /// Told when the results so far change (`RaceHost.resultsVersion`), from the driver (#148).
    private let onProgress: (@Sendable () -> Void)?
    /// Told once the gun has gone, with how many humans were at it (#152: the lobby's gun line).
    private let onGun: (@Sendable (_ humansAtGun: Int) -> Void)?
    /// The connection holding each seat, so a stale connection's goodbye can't drop a newer one.
    private var holders: [Int: ObjectIdentifier] = [:]
    /// Seats a join is claiming right now. `join` suspends on the host, and the actor is reentrant, so a
    /// second join for the seat (one token, two sockets) is refused here rather than racing the first.
    private var claiming: Set<Int> = []

    /// `roster` names the seats (RaceHost's "Seat n" by default); `onProgress` hears each change to the results so far;
    /// `onBriefingLeave` each human who left between fleet lock and the gun (#147, `RaceHost`'s); `fleet` and
    /// `onLeftAfterGun` are the host's (#149). `onGun` hears the gun once, from the driver, with the humans at it by the
    /// rating rule (`RaceLog.humanSeatsAtGun`): after tick 1's step, when tick 0 is settled (a leave stamped with the
    /// gun's tick is a leave before the gun).
    public init(id: UUID = UUID(), setup: RaceSetup, windSeed: WindSeed, closeAtTick: Int? = nil, scoresDevClose: Bool = false,
                clock: any HostClock = SystemClock(), options: RaceHostOptions = RaceHostOptions(), roster: [RosterEntry]? = nil,
                onProgress: (@Sendable () -> Void)? = nil, onBriefingLeave: (@Sendable (BriefingLeave) -> Void)? = nil,
                fleet: FleetFill? = nil, onLeftAfterGun: (@Sendable (_ seat: Int) -> Void)? = nil,
                onGun: (@Sendable (_ humansAtGun: Int) -> Void)? = nil) {
        self.id = id
        self.setup = setup
        self.closeAtTick = closeAtTick
        self.scoresDevClose = scoresDevClose
        self.clock = clock
        self.onProgress = onProgress
        self.onGun = onGun
        humanSeats = Set(setup.seats.indices.filter { setup.seats[$0] == .human })
        host = RaceHost(setup: setup, windSeed: windSeed, clock: clock, options: options, roster: roster,
                        onBriefingLeave: onBriefingLeave, fleet: fleet, onLeftAfterGun: onLeftAfterGun)
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

    /// The player in `seat` leaves for good (`RaceHost.leave`): before the gun a fleet bot takes it and the leave counts
    /// at once (#147). A seated connection's `LeaveRace` asks for it (#149, `quit(seat:transport:)`); a dropped
    /// connection is `leave(seat:transport:)`.
    @discardableResult
    public func quit(seat: Int) async -> Bool {
        holders[seat] = nil
        return await host.leave(seat: seat)
    }

    /// `LeaveRace` from the connection behind `transport` (#149): the seat's player leaves for good, if that connection
    /// still holds the seat. A stale connection's (another holds the seat now) and a second one's are ignored.
    @discardableResult
    public func quit(seat: Int, transport: any SeatTransport) async -> Bool {
        guard holders[seat] == ObjectIdentifier(transport) else { return false }
        return await quit(seat: seat)
    }

    // MARK: - Driving

    /// Steps the race on the wall clock until it ends, or until `closeAtTick`, closes it, and closes every
    /// seat's connection. Returns how it ended: closed, or cancelled (`RaceHost.cancel`, a mass drop).
    public func run() async -> RaceEnd {
        var version = 0
        var gunPending = onGun != nil
        while true {
            let step = await host.driveStep(closeAtTick: closeAtTick, scored: scoresDevClose)
            if gunPending, await host.tick >= 1 {
                gunPending = false
                if await host.cancelled == nil { onGun?(await host.log.humanSeatsAtGun.count) }
            }
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
    func driveStep(closeAtTick: Int?, scored: Bool = false) -> (next: UInt64?, resultsVersion: Int) {
        advance()
        if !isEnded, let closeAtTick, tick >= closeAtTick {
            if scored { closeScoredNow() } else { close() }
        }
        guard !isEnded else { return (nil, resultsVersion) }
        return (time(ofTick: tick + 1), resultsVersion)
    }
}
