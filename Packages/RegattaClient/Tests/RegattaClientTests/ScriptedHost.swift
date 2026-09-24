import RegattaClient
import RegattaCore
import RegattaProtocol

/// A stand-in for the race host (#65) for these tests only: one authoritative, seeded `Race` stepped at
/// 30 Hz on the virtual clock, talking to one client over a `FaultInjectingLink`.
///
/// It does what #18, #65 and #95 say the host does, as simply as possible:
/// - applies each input at its stamp if that tick hasn't been simulated, else at the next tick
///   (`Race.apply`); rejects inputs stamped more than 30 ticks past its next tick; drops a held input
///   older (by input sequence number) than one it already has;
/// - answers pings with its tick and the microseconds since that tick began;
/// - sends a snapshot every 3rd tick with the client's input feedback;
/// - sends each race event whose audience includes the client's seat, and reveals wind key k at server
///   tick `windowStart(k) − 30`, on the reliable stream;
/// - answers `RequestResync` with a `Resync` holding every key revealed so far.
///
/// It also records what the tests measure: when each input arrived, how early or late, and where the
/// client's boat was at every tick.
final class ScriptedHost {
    static let snapshotEvery = 3
    static let revealLead = 30
    static let maxAhead = 30

    let race: Race
    let clientSeat: Int
    let clock: VirtualClock
    var transport: RaceTransport
    /// Server clock time of tick `race.tick`'s start, on the virtual clock.
    let startedAt: UInt64

    private(set) var revealed: [WindKey] = []
    private var keys: WindKeyGenerator
    private var reliableSeq: UInt32 = 1
    private var otherSeq: UInt32 = 1
    private var lastHeldSeq: UInt32 = 0
    /// Inputs queued in the race, not yet simulated: (seq, tick).
    private var queued: [(seq: UInt32, tick: Int)] = []
    private var ack: InputAck?
    private var latestMargin = 0

    // Measurements.
    struct Arrival {
        let time: UInt64
        let isTap: Bool
        let margin: Int
    }
    private(set) var arrivals: [Arrival] = []
    private(set) var rejected = 0
    private(set) var resyncsSent = 0
    /// The client's boat position after each tick, by tick.
    private(set) var ownPositions: [Int: Vec2] = [:]

    init(setup: RaceSetup, windSeed: WindSeed, clientSeat: Int, transport: RaceTransport, clock: VirtualClock) throws {
        let bots = setup.seats.indices.filter { $0 != clientSeat }
        race = Race(setup: setup, windSeed: windSeed, botBrainSeats: bots)
        self.clientSeat = clientSeat
        self.clock = clock
        self.transport = transport
        startedAt = clock.now
        keys = try WindKeyGenerator(windSeed: windSeed, setup: race.windSetup, windows: race.wind.windows)
        revealKeys(send: false) // in the RaceStart
        ownPositions[race.tick] = race.boats[clientSeat].position
    }

    /// The `RaceStart` the client joins with: the keys revealed so far, never the seed.
    func raceStart() -> RaceStart {
        let roster = race.boats.map { RosterEntry(name: $0.name, colorIndex: $0.colorIndex) }
        return RaceStart(yourSeat: clientSeat, setup: race.setup, roster: roster, windKeys: revealed)
    }

    /// The server's continuous tick at `time`.
    func serverTick(at time: UInt64) -> Double {
        Double(-race.setup.startSequenceTicks) + Double(time - startedAt) / ClockSync.tickMicros
    }

    /// The virtual time at which `tick` is simulated.
    func time(ofTick tick: Int) -> UInt64 {
        startedAt + UInt64((Double(tick + race.setup.startSequenceTicks) * ClockSync.tickMicros).rounded(.up))
    }

    /// Handles what has arrived, then simulates every tick that is due.
    func poll() {
        for bytes in transport.receive() {
            guard let frame = try? Frame(decoding: bytes) else { continue }
            receive(frame)
        }
        while !race.isOver && clock.now >= time(ofTick: race.tick + 1) { step() }
    }

    private func receive(_ frame: Frame) {
        switch frame.message {
        case .inputHeld(let input):
            guard let at = accept(frame, isTap: false) else { return }
            guard frame.seq > lastHeldSeq else { return }
            lastHeldSeq = frame.seq
            if let tick = race.apply(input, seat: clientSeat, atTick: at) { queued.append((frame.seq, tick)) }
        case .inputTap(let tap):
            guard let at = accept(frame, isTap: true) else { return }
            if let tick = race.tap(tap, seat: clientSeat, atTick: at) { queued.append((frame.seq, tick)) }
        case .ping(let ping):
            let since = clock.now - time(ofTick: race.tick)
            send(.pong(Pong(clientTime: ping.clientTime, sinceTickMicros: UInt16(clamping: since))), tick: race.tick)
        case .requestResync:
            sendResync()
        default:
            break
        }
    }

    /// The tick an input is stamped for, or nil if it's too far ahead. Records its arrival.
    private func accept(_ frame: Frame, isTap: Bool) -> Int? {
        let margin = frame.tick - (race.tick + 1)
        arrivals.append(Arrival(time: clock.now, isTap: isTap, margin: margin))
        guard margin <= Self.maxAhead else {
            rejected += 1
            return nil
        }
        latestMargin = margin
        return frame.tick
    }

    private func step() {
        race.step()
        ownPositions[race.tick] = race.boats[clientSeat].position
        let applied = queued.filter { $0.tick <= race.tick }
        if let last = applied.max(by: { $0.seq < $1.seq }) {
            ack = InputAck(seq: max(last.seq, ack?.seq ?? 0), appliedTick: last.tick, margin: latestMargin)
        } else if let current = ack {
            ack = InputAck(seq: current.seq, appliedTick: current.appliedTick, margin: latestMargin)
        }
        queued.removeAll { $0.tick <= race.tick }
        for event in race.drainEvents() where EventAudience(event.kind).includes(seat: clientSeat) {
            sendReliable(Frame(seq: reliableSeq, event: event))
        }
        revealKeys(send: true)
        if race.tick % Self.snapshotEvery == 0, let snapshot = try? Snapshot(world: race.exportSnapshot(), ack: ack) {
            send(.snapshot(snapshot), tick: race.tick)
        }
    }

    /// Reveals every key k with `windowStart(k) − 30` at or before the current tick (#95).
    private func revealKeys(send: Bool) {
        while race.wind.windows.start(of: keys.nextWindow) - Self.revealLead <= race.tick {
            let key = keys.next()
            revealed.append(key)
            if send { sendReliable(Frame(seq: reliableSeq, tick: race.tick, message: .windKey(key))) }
        }
    }

    func sendResync() {
        guard let resync = try? Resync(raceSeed: race.setup.raceSeed, world: race.exportSnapshot(), windKeys: revealed,
                                       nextEventSeq: reliableSeq) else { return }
        send(.resync(resync), tick: race.tick)
        resyncsSent += 1
    }

    private func sendReliable(_ frame: Frame) {
        reliableSeq += 1
        transport.send(try! frame.encoded())
    }

    private func send(_ message: Message, tick: Int) {
        transport.send(try! Frame(seq: otherSeq, tick: tick, message: message).encoded())
        otherSeq += 1
    }
}
