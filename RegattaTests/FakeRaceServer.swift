import RegattaBots
import RegattaClient
import RegattaCore
import RegattaProtocol

/// A scripted race server for the online driver's tests (#68): the handshake as `SeatConnection` answers it,
/// then one authoritative, seeded `Race` stepped at 30 Hz on the virtual clock, as `RaceHost` sails it, to
/// one client over a `FaultInjectingLink`. The real host (#65) lives in RegattaServer, whose package brings
/// SwiftNIO, which the app doesn't link; RegattaClientTests' `ScriptedHost` is the model for this one.
///
/// - `Hello` → `HelloAck`, or `UpdateRequired` when `refusesUpdate` is set; `JoinRace` → `RaceStart`, and a
///   `Resync` if the race has begun (a rejoin).
/// - Applies each input at its stamp, or the next tick if that has been simulated; the client's seat keeps
///   its last input while it's away.
/// - Answers pings; sends a snapshot every 3rd tick with the input feedback; every event on the reliable
///   stream (all of them reach every seat but the notices), and wind key k at tick `windowStart(k) − 30`.
/// - Answers `RequestResync` with a `Resync`.
///
/// It records when it sent each event, and every client input it applied.
nonisolated final class FakeRaceServer {
    static let snapshotEvery = 3
    static let revealLead = 30

    let race: Race
    let clientSeat = 0
    let clock: VirtualClock
    let startedAt: UInt64
    var refusesUpdate: UpdateRequired.Reason?

    private var bots: SeatControllers
    private var transport: RaceTransport
    private var seated = false
    private var revealed: [WindKey] = []
    private var keys: WindKeyGenerator
    private var reliableSeq: UInt32 = 1
    private var otherSeq: UInt32 = 1
    private var lastHeldSeq: UInt32 = 0
    private var queued: [(seq: UInt32, tick: Int)] = []
    private var ack: InputAck?
    private var margin = 0

    /// Each event sent, and when.
    private(set) var sentEvents: [(time: UInt64, event: RaceEvent)] = []
    /// Each held input of the client's applied: its rudder and the tick.
    private(set) var appliedHeld: [(tick: Int, rudder: Int8)] = []
    private(set) var resyncsSent = 0
    private(set) var joins = 0

    init(seats: Int = 10, seed: UInt64, startSequenceTicks: Int = 300, transport: RaceTransport, clock: VirtualClock) throws {
        let kinds: [SeatKind] = (0..<seats).map { $0 == 0 ? .human : .bot }
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: kinds, laps: 1, startSequenceTicks: startSequenceTicks)
        race = Race(setup: setup, windSeed: WindSeed(seed &* 7))
        bots = SeatControllers(race.boats.indices.map { $0 == 0 ? .human : .bot(BotDriver(seat: $0, raceSeed: setup.raceSeed)) })
        self.transport = transport
        self.clock = clock
        startedAt = clock.now
        keys = try WindKeyGenerator(windSeed: race.windSeed!, setup: race.windSetup, windows: race.wind.windows)
        revealKeys(send: false)
    }

    /// A new connection from the client, which will say `Hello` on it.
    func accept(_ transport: RaceTransport) {
        self.transport = transport
        seated = false
    }

    /// The server's tick at `time`, with its fraction.
    func serverTick(at time: UInt64) -> Double {
        Double(-race.setup.startSequenceTicks) + Double(time - startedAt) / ClockSync.tickMicros
    }

    func time(ofTick tick: Int) -> UInt64 {
        startedAt + UInt64((Double(tick + race.setup.startSequenceTicks) * ClockSync.tickMicros).rounded(.up))
    }

    /// Handles what has arrived, then simulates every tick that is due.
    func poll() {
        for bytes in transport.receive() {
            guard let frame = try? Frame(decoding: bytes) else { continue }
            receive(frame)
        }
        while !closed && !race.isOver && clock.now >= time(ofTick: race.tick + 1) { step() }
    }

    /// Closes the race where it stands, as the dev race-length override does: `RaceClosed`, then the
    /// connection goes.
    func close() {
        send(.raceClosed(RaceClosed(results: .none)), tick: race.tick)
        seated = false
        closed = true
    }

    private(set) var closed = false

    private func receive(_ frame: Frame) {
        switch frame.message {
        case .hello:
            if let refusesUpdate {
                send(.updateRequired(UpdateRequired(reason: refusesUpdate)), tick: 0)
            } else {
                send(.helloAck(HelloAck(serverBuild: "fake")), tick: 0)
            }
        case .joinRace where !closed:
            seated = true
            joins += 1
            let start = RaceStart(yourSeat: clientSeat, setup: race.setup,
                                  roster: race.boats.map { RosterEntry(name: "Seat \($0.id + 1)", colorIndex: $0.colorIndex) },
                                  windKeys: revealed)
            send(.raceStart(start), tick: race.tick)
            if race.tick > -race.setup.startSequenceTicks { sendResync() }
        case .inputHeld(let input) where seated:
            let at = frame.tick
            margin = at - (race.tick + 1)
            guard frame.seq > lastHeldSeq else { return }
            lastHeldSeq = frame.seq
            if let tick = race.apply(input, seat: clientSeat, atTick: at) {
                queued.append((frame.seq, tick))
                appliedHeld.append((tick, input.rudder))
            }
        case .inputTap(let tap) where seated:
            margin = frame.tick - (race.tick + 1)
            if let tick = race.tap(tap, seat: clientSeat, atTick: frame.tick) { queued.append((frame.seq, tick)) }
        case .ping(let ping) where seated:
            let since = clock.now - time(ofTick: race.tick)
            send(.pong(Pong(clientTime: ping.clientTime, sinceTickMicros: UInt16(clamping: since))), tick: race.tick)
        case .requestResync where seated:
            sendResync()
        default:
            break
        }
    }

    private func step() {
        bots.drive(race)
        race.step()
        let applied = queued.filter { $0.tick <= race.tick }
        if let last = applied.max(by: { $0.seq < $1.seq }) {
            ack = InputAck(seq: max(last.seq, ack?.seq ?? 0), appliedTick: last.tick, margin: margin)
        }
        queued.removeAll { $0.tick <= race.tick }
        for event in race.drainEvents() where EventAudience(event.kind).includes(seat: clientSeat) {
            sendReliable(Frame(seq: reliableSeq, event: event))
            if seated { sentEvents.append((clock.now, event)) }
        }
        revealKeys(send: true)
        if seated, race.tick % Self.snapshotEvery == 0, let snapshot = try? Snapshot(world: race.exportSnapshot(), ack: ack) {
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
        resyncsSent += 1
    }

    /// Reliable frames are numbered whether or not the client is there to get them: one it missed while
    /// away is in the `Resync`'s event state.
    private func sendReliable(_ frame: Frame) {
        reliableSeq += 1
        if seated { transport.send(try! frame.encoded()) }
    }

    private func send(_ message: Message, tick: Int) {
        transport.send(try! Frame(seq: otherSeq, tick: tick, message: message).encoded())
        otherSeq += 1
    }
}
