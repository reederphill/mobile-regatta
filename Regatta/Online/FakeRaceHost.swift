#if DEBUG
import Foundation
import RegattaBots
import RegattaClient
import RegattaCore
import RegattaProtocol

/// The client's end of a connection to the fake race host (#141): two queues in memory, read by whoever polls.
nonisolated final class FakeRaceConnection: RaceConnection {
    private(set) var isConnected = true
    /// Client to host, and host to client.
    fileprivate var uplink: [[UInt8]] = []
    fileprivate var downlink: [[UInt8]] = []

    func send(_ frame: [UInt8]) {
        guard isConnected else { return }
        uplink.append(frame)
    }

    func receive() -> [[UInt8]] {
        defer { downlink.removeAll() }
        return downlink
    }

    func close() { isConnected = false }
}

/// The race server a `-fakeServices` launch sails against (#141): `RegattaTests/FakeRaceServer`'s model on the wall
/// clock (at `-timescale`), for one client. The handshake, `RaceStart`, one authoritative seeded `Race` stepped at
/// 30 Hz with every other seat on a bot, snapshots, events, wind keys and resyncs; `LeaveRace` (before the gun the
/// roster entry becomes a bot's; either way the seat is released and the connection closed); a dropped connection
/// (the cautious bot isn't modelled: the seat keeps its last input); a scripted seat handed to a bot; the close
/// `closeTick` after the gun, or a cancel. Debug builds only; the real host lives in RegattaServer.
nonisolated final class FakeRaceHost {
    enum Ending: Equatable {
        case closed
        case cancelled
    }

    static let snapshotEvery = 3
    static let revealLead = 30
    static let seat = 0

    let race: Race
    private(set) var roster: [RosterEntry]
    private(set) var ending: Ending?
    /// She sent `LeaveRace`: the seat is released for good.
    private(set) var hasLeft = false
    /// The race closes at this tick.
    var closeTick: Int
    /// The race is cancelled at this tick instead.
    var cancelTick: Int?
    /// At `tick` the player in `seat` gives it up and a bot takes it under `name`.
    var handOver: (tick: Int, seat: Int, name: String)?
    var onEnd: ((Ending) -> Void)?
    var onSeatReleased: (() -> Void)?

    private let now: () -> UInt64
    /// The clock's microseconds at the race's first tick; negative when the race began before the clock did.
    private var origin: Double
    private var bots: SeatControllers
    private var connection: FakeRaceConnection?
    private var seated = false
    private var revealed: [WindKey] = []
    private var keys: WindKeyGenerator
    private var reliableSeq: UInt32 = 1
    private var otherSeq: UInt32 = 1
    private var lastHeldSeq: UInt32 = 0
    private var queued: [(seq: UInt32, tick: Int)] = []
    private var ack: InputAck?
    private var margin = 0

    /// A race on `setup` whose seats have `names`, the client in seat 0 and a bot sailing every other seat, begun
    /// now on `now`'s clock.
    init(setup: RaceSetup, names: [String], closeTick: Int, now: @escaping () -> UInt64) throws {
        race = Race(setup: setup, windSeed: WindSeed(setup.raceSeed.value &* 7))
        roster = setup.seats.indices.map { seat in
            RosterEntry(name: names.indices.contains(seat) ? names[seat] : "Seat \(seat + 1)", colorIndex: seat,
                        isBot: setup.seats[seat] == .bot)
        }
        bots = SeatControllers(setup.seats.indices.map { seat in
            seat == Self.seat ? .human : .bot(BotDriver(seat: seat, raceSeed: setup.raceSeed))
        })
        self.closeTick = closeTick
        self.now = now
        origin = Double(now())
        keys = try WindKeyGenerator(windSeed: race.windSeed!, setup: race.windSetup, windows: race.wind.windows)
        revealKeys(send: false)
    }

    var tick: Int { race.tick }

    /// Whether `RaceSessionService.rejoin()` has a race to offer: after the gun, not ended, her seat not given up.
    var isRejoinable: Bool { race.tick >= 0 && ending == nil && !hasLeft }

    /// The queue holds her while the race does: until she leaves it or it ends.
    var holdsSeat: Bool { ending == nil && !hasLeft }

    /// Sails the race to `tick` at once, with nobody connected: a race already under way at launch.
    func fastForward(to tick: Int) {
        while race.tick < tick, !race.isOver { step() }
        origin = Double(now()) - Double(race.tick + race.setup.startSequenceTicks) * ClockSync.tickMicros
    }

    /// A new connection from the client, which will say `Hello` on it.
    func accept(_ connection: FakeRaceConnection) {
        self.connection?.close()
        self.connection = connection
        seated = false
    }

    private func time(ofTick tick: Int) -> Double {
        origin + Double(tick + race.setup.startSequenceTicks) * ClockSync.tickMicros
    }

    /// Handles what has arrived, then simulates every tick that is due (a few at most, so a stall doesn't freeze the
    /// app catching up).
    func poll() {
        if let connection {
            if connection.isConnected {
                let frames = connection.uplink
                connection.uplink.removeAll()
                for bytes in frames {
                    guard let frame = try? Frame(decoding: bytes) else { continue }
                    receive(frame)
                }
            } else {
                // Dropped: the seat stays hers.
                seated = false
                self.connection = nil
            }
        }
        var steps = 0
        let now = Double(now())
        while ending == nil, !race.isOver, now >= time(ofTick: race.tick + 1), steps < 8 {
            step()
            steps += 1
            if let cancelTick, race.tick >= cancelTick {
                end(.cancelled)
            } else if race.tick >= closeTick {
                end(.closed)
            }
        }
        // Too far behind to catch up: the race clock slips rather than the app.
        if ending == nil, now - time(ofTick: race.tick + 1) > 500_000 { origin += 250_000 }
    }

    private func end(_ ending: Ending) {
        self.ending = ending
        switch ending {
        case .closed: send(.raceClosed(RaceClosed(results: .none)), tick: race.tick)
        case .cancelled: send(.raceCancelled(RaceCancelled(reason: .serverShutdown)), tick: race.tick)
        }
        seated = false
        onEnd?(ending)
    }

    private func receive(_ frame: Frame) {
        switch frame.message {
        case .hello:
            send(.helloAck(HelloAck(serverBuild: "fake")), tick: 0)
        case .joinRace:
            // No join-refused message: the server closes the connection.
            guard ending == nil, !hasLeft else {
                connection?.close()
                connection = nil
                return
            }
            seated = true
            send(.raceStart(RaceStart(yourSeat: Self.seat, setup: race.setup, roster: roster, windKeys: revealed)), tick: race.tick)
            if race.tick > -race.setup.startSequenceTicks { sendResync() }
        case .leaveRace where seated:
            hasLeft = true
            if race.tick < 0 {
                // Before the gun a fleet bot takes the seat for good, under a sailing name.
                bots.takeOver(seat: Self.seat, raceSeed: race.setup.raceSeed, cautious: false)
                roster[Self.seat] = RosterEntry(name: "Gannet", colorIndex: Self.seat, isBot: true)
            }
            seated = false
            connection?.close()
            connection = nil
            onSeatReleased?()
        case .inputHeld(let input) where seated:
            margin = frame.tick - (race.tick + 1)
            guard frame.seq > lastHeldSeq else { return }
            lastHeldSeq = frame.seq
            if let tick = race.apply(input, seat: Self.seat, atTick: frame.tick) { queued.append((frame.seq, tick)) }
        case .inputTap(let tap) where seated:
            margin = frame.tick - (race.tick + 1)
            if let tick = race.tap(tap, seat: Self.seat, atTick: frame.tick) { queued.append((frame.seq, tick)) }
        case .ping(let ping) where seated:
            let since = max(0, Double(now()) - time(ofTick: race.tick))
            send(.pong(Pong(clientTime: ping.clientTime, sinceTickMicros: UInt16(clamping: Int(since)))), tick: race.tick)
        case .requestResync where seated:
            sendResync()
        default:
            break
        }
    }

    private func step() {
        if let handOver, race.tick == handOver.tick, roster.indices.contains(handOver.seat) {
            let entry = RosterEntry(name: handOver.name, colorIndex: roster[handOver.seat].colorIndex, isBot: true)
            roster[handOver.seat] = entry
            sendReliable(Frame(seq: reliableSeq, tick: race.tick, message: .rosterChange(RosterChange(seat: handOver.seat, entry: entry))))
        }
        bots.drive(race)
        race.step()
        let applied = queued.filter { $0.tick <= race.tick }
        if let last = applied.max(by: { $0.seq < $1.seq }) {
            ack = InputAck(seq: max(last.seq, ack?.seq ?? 0), appliedTick: last.tick, margin: margin)
        }
        queued.removeAll { $0.tick <= race.tick }
        for event in race.drainEvents() where EventAudience(event.kind).includes(seat: Self.seat) {
            sendReliable(Frame(seq: reliableSeq, event: event))
        }
        revealKeys(send: true)
        if seated, race.tick % Self.snapshotEvery == 0, var snapshot = try? Snapshot(world: race.exportSnapshot(), ack: ack) {
            snapshot.relations = WireRelation.relations(of: Self.seat, in: race)
            send(.snapshot(snapshot), tick: race.tick)
        }
    }

    private func revealKeys(send: Bool) {
        while race.wind.windows.start(of: keys.nextWindow) - Self.revealLead <= race.tick {
            let key = keys.next()
            revealed.append(key)
            if send { sendReliable(Frame(seq: reliableSeq, tick: race.tick, message: .windKey(key))) }
        }
    }

    private func sendResync() {
        guard let resync = try? Resync(raceSeed: race.setup.raceSeed, world: race.exportSnapshot(), windKeys: revealed,
                                       nextEventSeq: reliableSeq) else { return }
        send(.resync(resync), tick: race.tick)
    }

    /// Reliable frames are numbered whether or not the client is there to get them: one it missed while away is in
    /// the `Resync`'s event state.
    private func sendReliable(_ frame: Frame) {
        reliableSeq += 1
        guard seated, let bytes = try? frame.encoded() else { return }
        connection?.downlink.append(bytes)
    }

    private func send(_ message: Message, tick: Int) {
        guard let connection, connection.isConnected,
              let bytes = try? Frame(seq: otherSeq, tick: tick, message: message).encoded() else { return }
        connection.downlink.append(bytes)
        otherSeq += 1
    }
}
#endif
