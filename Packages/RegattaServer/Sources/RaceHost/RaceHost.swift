import RegattaBots
import RegattaCore
import RegattaProtocol

/// How a host runs, besides its race.
public struct RaceHostOptions: Hashable, Sendable {
    public var caps = InputCaps()
    /// A snapshot goes to every seat on each tick that is a multiple of this (#18: every 3rd tick).
    public var snapshotEvery = 3
    /// The behind alert fires when the scheduler finds more than this many ticks due at once (#18: 1 s).
    public var behindAlertTicks = Race.tickRate
    /// How long the host holds a seat's last input after its inputs stop, before it drops the boat (#18: 0.5 s).
    public var inputHoldTicks = Race.tickRate / 2
    /// How long the host waits for a seat's first held input after it attaches, before it drops the boat
    /// as it would a silent one. Longer than the hold: the input comes a handshake after the attach
    /// (`RaceStart`, then a ping and its pong), about 1.5 round trips.
    public var firstInputHoldTicks = Race.tickRate
    /// When every human is gone (G3).
    public var allGone = AllGoneConfig()

    public init() {}
}

/// What one seat has sent that the host didn't apply, and how much it did. For tests and the admin log.
public struct SeatInputStats: Hashable, Sendable {
    /// Held inputs and taps handed to the race.
    public var applied = 0
    /// Held inputs over the cap (#26), dropped.
    public var heldDropped = 0
    /// Taps over the cap (#26), dropped.
    public var tapsDropped = 0
    /// Inputs stamped more than `InputCaps.maxTicksAhead` past the next tick (#18), rejected.
    public var rejectedAhead = 0
    /// Inputs out of range (a rudder outside `BoatInput.rudderRange`, a protest of no one), rejected.
    public var rejectedRange = 0
    /// Held inputs older, by input sequence number, than one already applied: dropped.
    public var stale = 0

    public init() {}
}

/// The race as the host closed it.
public struct RaceOutcome: Hashable, Sendable {
    /// Seats from first to last (`Race.standings()`).
    public var standings: [Int]
    /// `Race.digest()` at the close: what replaying `log` reproduces (ADR 0002).
    public var digest: UInt64
    /// Every input the host applied, bots' included, and every seat event, at the ticks they took effect.
    public var log: RaceLog
}

/// The race server's core (#65): one authoritative `Race`, stepped at 30 Hz on the injected clock, with
/// no rewind (ADR 0005). Each input applies at its stamped tick if that hasn't been simulated, else at the
/// next tick, and the race log is exactly what the host applied (#18). Bots sail their seats through the
/// same input API (#60), so their inputs are in the log too.
///
/// Nothing runs on its own: a driver calls `advance()` on its timer, and `receive(_:from:)` with each
/// frame a seat sends. Both first simulate every tick due by the clock, as many as it takes to catch up.
///
/// Seats (#66): a player attaches with `attach(seat:transport:)`. When a seat's held inputs stop, whether
/// its socket closed or not, the host holds its last input `inputHoldTicks` (#18), then releases the helm
/// with a neutral input and a cautious bot sails the dropped boat until the player rejoins. A seat that
/// attaches and sends no held input is dropped the same way, `firstInputHoldTicks` after the attach. A
/// seat left before the gun goes to a fleet bot for good (#35); left after it, the boat takes the
/// dropped-boat path.
/// When every human is gone, `onAllGone` fires once, after the grace (G3).
public actor RaceHost {
    /// Wind keys to reveal once the race has simulated `tick` (#95). Stub until #95: reveals nothing.
    public typealias WindKeyReveal = @Sendable (_ tick: Int) -> [WindKey]

    private struct Seat {
        var transport: (any SeatTransport)?
        var hasJoined = false
        var gate: InputGate
        var stats = SeatInputStats()
        var lastHeldSeq: UInt32 = 0
        /// Inputs handed to the race and not yet simulated: (input seq, tick they apply at).
        var queued: [(seq: UInt32, tick: Int)] = []
        var ack: InputAck?
        var latestMargin = 0
        /// The reliable stream (`Event`, `WindKey`): the next sequence number, and frames not yet sent.
        var reliableSeq: UInt32 = 1
        var reliableQueue: [Frame] = []
        var otherSeq: UInt32 = 1
        /// The tick of the last held input the host applied for the seat.
        var lastHeldTick: Int?
        /// The tick the input hold runs out at (#18), while a player sails the seat and its inputs have
        /// stopped or may yet. An attach sets it to the wait for the first input: a rejoin before it runs
        /// out cancels the drop, and a seat that never sends is still dropped.
        var holdDeadline: Int?

        init(caps: InputCaps) { gate = InputGate(caps: caps) }
    }

    /// How and when a human seat went (G3). `order` breaks ties between seats gone in the same tick.
    private struct Gone {
        var kind: GoneKind
        var tick: Int
        var order: Int
    }

    public let options: RaceHostOptions
    private let race: Race
    private var bots: SeatControllers
    private let roster: [RosterEntry]
    private let clock: any HostClock
    private let onBehind: (@Sendable (_ ticksBehind: Int) -> Void)?
    private let onAllGone: (@Sendable (_ allGone: AllGone) -> Void)?
    private let windKeyReveal: WindKeyReveal
    /// Clock time of the race's first tick, `-startSequenceTicks`.
    private let startedAt: UInt64
    private let startTick: Int
    private var seats: [Seat]
    private var revealed: [WindKey] = []
    /// The seats the setup gives to players: only these count as humans.
    private let humanSeats: [Int]
    /// Each human seat that is gone, and how (G3). A left seat stays gone: it can't rejoin.
    private var gone: [Gone?]
    private var goneCount = 0
    private var allGoneFired = false
    public private(set) var outcome: RaceOutcome?

    /// A host for a new race, at the start of its sequence now. Seats the setup marks `.bot` are sailed
    /// by RegattaBots; the rest wait for a player to attach. `roster` defaults to "Seat n" names.
    /// `onAllGone` fires once when every human is gone and the grace is over (G3; #148 closes the race).
    public init(setup: RaceSetup, windSeed: WindSeed, clock: any HostClock, options: RaceHostOptions = RaceHostOptions(),
                roster: [RosterEntry]? = nil, windKeyReveal: @escaping WindKeyReveal = { _ in [] },
                onBehind: (@Sendable (_ ticksBehind: Int) -> Void)? = nil,
                onAllGone: (@Sendable (_ allGone: AllGone) -> Void)? = nil) {
        let race = Race(setup: setup, windSeed: windSeed)
        self.race = race
        bots = SeatControllers(setup: setup)
        self.roster = roster ?? race.boats.map { RosterEntry(name: "Seat \($0.id + 1)", colorIndex: $0.colorIndex) }
        self.clock = clock
        self.options = options
        self.onBehind = onBehind
        self.onAllGone = onAllGone
        self.windKeyReveal = windKeyReveal
        startedAt = clock.now()
        startTick = race.tick
        seats = Array(repeating: Seat(caps: options.caps), count: race.boats.count)
        humanSeats = setup.seats.indices.filter { setup.seats[$0] == .human }
        gone = Array(repeating: nil, count: race.boats.count)
    }

    // MARK: - Reading

    /// The last tick simulated.
    public var tick: Int { race.tick }
    public var isOver: Bool { race.isOver }
    /// The race so far as a log (ADR 0002): every input and seat event as applied.
    public var log: RaceLog {
        guard let log = race.log else { preconditionFailure("a host's race is always seeded") }
        return log
    }

    public func stats(seat: Int) -> SeatInputStats { seats[seat].stats }
    public func isAttached(seat: Int) -> Bool { seats[seat].transport != nil }
    /// Who sails `seat` now: its player, a fleet bot, or the bot sailing a dropped boat.
    public func controller(seat: Int) -> SeatController { bots[seat] }
    /// `seat`'s boat as of the last tick simulated.
    public func boat(seat: Int) -> Boat { race.boats[seat] }
    public var revealedWindKeys: [WindKey] { revealed }

    /// The clock time at which `tick` is simulated.
    public func time(ofTick tick: Int) -> UInt64 {
        startedAt + (UInt64(tick - startTick) * 1_000_000 + UInt64(Race.tickRate) - 1) / UInt64(Race.tickRate)
    }

    /// The last tick due by the clock at `now`.
    private func dueTick(at now: UInt64) -> Int {
        startTick + Int((now - startedAt) * UInt64(Race.tickRate) / 1_000_000)
    }

    // MARK: - Scheduler

    /// Simulates every tick due by the clock, several if the host fell behind, and alerts if it fell more
    /// than `behindAlertTicks` behind (#18). Does nothing once the race is closed.
    public func advance() {
        guard outcome == nil else { return }
        let due = dueTick(at: clock.now())
        let behind = due - race.tick
        if behind > options.behindAlertTicks { onBehind?(behind) }
        while race.tick < due && outcome == nil { step() }
    }

    private func step() {
        // A seat whose hold runs out at the next tick gets its helm released at that tick (#18): the
        // neutral input is the first the dropped-boat bot sends, so the bot takes the seat after it.
        let next = race.tick + 1
        let expired = seats.indices.filter { seat in seats[seat].holdDeadline.map { $0 <= next } ?? false }
        for seat in expired { race.apply(.neutral, seat: seat, atTick: next) }
        bots.drive(race)
        race.step()
        for seat in expired { dropBoat(seat) }
        checkAllGone()
        for seat in seats.indices { acknowledge(seat) }
        for event in race.drainEvents() { enqueue(event, to: EventAudience(event.kind)) }
        let keys = windKeyReveal(race.tick)
        if !keys.isEmpty {
            revealed += keys
            for key in keys { enqueueReliable(.windKey(key), to: .everyone) }
        }
        flushReliable()
        if race.tick % options.snapshotEvery == 0 { sendSnapshots() }
        if race.isOver { close() }
    }

    /// Brings `seat`'s ack up to the latest of its inputs the race has now applied (#64's contract).
    private func acknowledge(_ seat: Int) {
        let applied = seats[seat].queued.filter { $0.tick <= race.tick }
        let margin = seats[seat].latestMargin
        if let last = applied.max(by: { $0.seq < $1.seq }) {
            seats[seat].ack = InputAck(seq: max(last.seq, seats[seat].ack?.seq ?? 0), appliedTick: last.tick, margin: margin)
        } else if let current = seats[seat].ack {
            seats[seat].ack = InputAck(seq: current.seq, appliedTick: current.appliedTick, margin: margin)
        }
        seats[seat].queued.removeAll { $0.tick <= race.tick }
    }

    private func sendSnapshots() {
        let world = race.exportSnapshot()
        guard let fleet = try? Snapshot(world: world) else { return }
        for seat in seats.indices where seats[seat].transport != nil {
            var snapshot = fleet
            snapshot.ack = seats[seat].ack
            send(.snapshot(snapshot), to: seat)
        }
    }

    // MARK: - Events

    /// Sends a race event the host decides, rather than the race, to `audience` only: a targeted notice
    /// such as the recall notice to the boat that is over (#9, #85). Stamped with the current tick.
    public func sendEvent(_ kind: RaceEvent.Kind, to audience: EventAudience) {
        guard outcome == nil else { return }
        enqueue(RaceEvent(tick: race.tick, kind: kind), to: audience)
        flushReliable()
    }

    private func enqueue(_ event: RaceEvent, to audience: EventAudience) {
        for seat in seats.indices where seats[seat].transport != nil && audience.includes(seat: seat) {
            seats[seat].reliableQueue.append(Frame(seq: seats[seat].reliableSeq, event: event))
            seats[seat].reliableSeq += 1
        }
    }

    private func enqueueReliable(_ message: Message, to audience: EventAudience) {
        for seat in seats.indices where seats[seat].transport != nil && audience.includes(seat: seat) {
            seats[seat].reliableQueue.append(Frame(seq: seats[seat].reliableSeq, tick: race.tick, message: message))
            seats[seat].reliableSeq += 1
        }
    }

    /// Sends each seat's reliable frames in order.
    private func flushReliable() {
        for seat in seats.indices where !seats[seat].reliableQueue.isEmpty {
            guard let transport = seats[seat].transport else { continue }
            for frame in seats[seat].reliableQueue {
                if let bytes = try? frame.encoded() { transport.send(bytes) }
            }
            seats[seat].reliableQueue.removeAll()
        }
    }

    private func send(_ message: Message, to seat: Int) {
        guard let transport = seats[seat].transport,
              let bytes = try? Frame(seq: seats[seat].otherSeq, tick: race.tick, message: message).encoded() else { return }
        seats[seat].otherSeq += 1
        transport.send(bytes)
    }

    // MARK: - Seats

    /// Connects a player's `transport` to `seat` and sends it the race (`RaceStart`, and a `Resync` if
    /// the race has begun stepping). Records the join, or a rejoin: a rejoin takes the seat back from the
    /// bot sailing the dropped boat, or cancels the input hold if the boat isn't dropped yet. Either way the
    /// seat then has `firstInputHoldTicks` to send a held input before it is dropped. False for a
    /// bot seat, a seat that left (#35: it was given away), a seat out of range or a closed race.
    @discardableResult
    public func attach(seat: Int, transport: any SeatTransport) -> Bool {
        guard outcome == nil, humanSeats.contains(seat), gone[seat]?.kind != .left else { return false }
        let rejoin = seats[seat].hasJoined
        seats[seat] = Seat(caps: options.caps)
        seats[seat].transport = transport
        seats[seat].hasJoined = true
        seats[seat].holdDeadline = race.tick + options.firstInputHoldTicks
        bots[seat] = .human
        gone[seat] = nil
        race.record(rejoin ? .rejoined : .joined(.human), seat: seat)
        send(.raceStart(RaceStart(yourSeat: seat, setup: race.setup, roster: roster, windKeys: revealed)), to: seat)
        if race.tick > startTick { sendResync(to: seat) }
        return true
    }

    /// Drops `seat`'s connection, closing its transport, and records the disconnect. A player's boat keeps
    /// its last input for the input hold, then is dropped (#18): the close starts the hold, it doesn't skip it.
    public func disconnect(seat: Int) {
        guard seats.indices.contains(seat), let transport = seats[seat].transport else { return }
        seats[seat].transport = nil
        seats[seat].reliableQueue.removeAll()
        if outcome == nil {
            race.record(.disconnected, seat: seat)
            startHold(seat)
        }
        transport.close()
    }

    /// The player at `seat` leaves, closing its transport. Before the gun a fleet bot takes the seat for
    /// good, sailing on from where the boat is (#16, #35); after it the boat takes the dropped-boat path.
    /// Either way the seat is gone and can't rejoin. False for a bot seat, a seat that already left, a
    /// seat out of range or a closed race.
    @discardableResult
    public func leave(seat: Int) -> Bool {
        guard outcome == nil, humanSeats.contains(seat), gone[seat]?.kind != .left else { return false }
        let transport = seats[seat].transport
        seats[seat].transport = nil
        seats[seat].reliableQueue.removeAll()
        if race.tick < 0 {
            race.record(.leftBeforeGun, seat: seat)
            race.record(.botTookOver(.fleet), seat: seat)
            bots[seat] = .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed))
            seats[seat].holdDeadline = nil
        } else {
            race.record(.left, seat: seat)
            startHold(seat)
        }
        markGone(seat, .left)
        transport?.close()
        checkAllGone()
        return true
    }

    /// Starts `seat`'s input hold, if a player sails it: from its last held input or now, whichever is later.
    private func startHold(_ seat: Int) {
        guard bots[seat].isHuman else { return }
        let from = max(seats[seat].lastHeldTick ?? race.tick, race.tick)
        seats[seat].holdDeadline = from + options.inputHoldTicks
    }

    /// The hold on `seat` ran out at the tick just simulated, where its neutral input applied: the seat
    /// is dropped (unless it left) and a cautious bot sails it. Stub: a fleet-style driver until #150.
    private func dropBoat(_ seat: Int) {
        seats[seat].holdDeadline = nil
        if gone[seat]?.kind != .left {
            race.record(.dropped, seat: seat)
            markGone(seat, .dropped)
        }
        race.record(.botTookOver(.cautious), seat: seat)
        bots[seat] = .dropped(BotDriver(seat: seat, raceSeed: race.setup.raceSeed))
    }

    /// A dropped seat that is still attached sends inputs again: the player takes the boat back, as on a
    /// rejoin, and gets a `Resync` since the bot has been sailing it.
    private func resume(_ seat: Int) {
        bots[seat] = .human
        gone[seat] = nil
        race.record(.rejoined, seat: seat)
        sendResync(to: seat)
    }

    /// Notes that `seat` went now. A dropped seat that then leaves keeps its place in the order.
    private func markGone(_ seat: Int, _ kind: GoneKind) {
        if let current = gone[seat] {
            gone[seat] = Gone(kind: kind, tick: current.tick, order: current.order)
        } else {
            gone[seat] = Gone(kind: kind, tick: race.tick, order: goneCount)
            goneCount += 1
        }
    }

    /// Fires `onAllGone`, once, when every human seat is gone in a way `goneKinds` counts and the last
    /// went `graceTicks` ago or more. A rejoin in the grace makes a seat not gone, so nothing fires.
    private func checkAllGone() {
        guard !allGoneFired, outcome == nil, !race.isOver, !humanSeats.isEmpty else { return }
        let config = options.allGone
        var went: [(seat: Int, gone: Gone)] = []
        for seat in humanSeats {
            guard let seatGone = gone[seat], config.goneKinds.contains(seatGone.kind) else { return }
            went.append((seat: seat, gone: seatGone))
        }
        let ticks = went.map { $0.gone.tick }
        guard let first = ticks.min(), let last = ticks.max(), race.tick >= last + config.graceTicks else { return }
        went.sort { $0.gone.order < $1.gone.order }
        let allDropped = went.allSatisfy { $0.gone.kind == .dropped }
        let isMassDrop = went.count >= 2 && allDropped && last - first <= config.massDropWindowTicks
        allGoneFired = true
        onAllGone?(AllGone(tick: race.tick, leaveOrder: went.map { $0.seat }, isMassDrop: isMassDrop))
    }

    private func sendResync(to seat: Int) {
        flushReliable()
        guard let resync = try? Resync(raceSeed: race.setup.raceSeed, world: race.exportSnapshot(), windKeys: revealed,
                                       nextEventSeq: seats[seat].reliableSeq) else { return }
        send(.resync(resync), to: seat)
    }

    // MARK: - Input

    /// Handles one frame `seat` sent, after simulating every tick due by the clock: held inputs and taps
    /// under the caps (#26) and the 1 s stamp limit (#18), pings and resync requests. Anything else, and
    /// anything from a seat that isn't attached, is ignored.
    public func receive(_ bytes: [UInt8], from seat: Int) {
        guard outcome == nil, seats.indices.contains(seat), seats[seat].transport != nil else { return }
        advance()
        guard outcome == nil, let frame = try? Frame(decoding: bytes) else { return }
        switch frame.message {
        case .inputHeld(let input): receiveHeld(input, frame: frame, seat: seat)
        case .inputTap(let tap): receiveTap(tap, frame: frame, seat: seat)
        case .ping(let ping):
            let since = clock.now() - time(ofTick: race.tick)
            send(.pong(Pong(clientTime: ping.clientTime, sinceTickMicros: UInt16(clamping: since))), to: seat)
        case .requestResync:
            sendResync(to: seat)
        default:
            break
        }
    }

    private func receiveHeld(_ input: BoatInput, frame: Frame, seat: Int) {
        guard admit(.held, frame: frame, seat: seat) else { return }
        guard BoatInput.rudderRange.contains(input.rudder) else {
            seats[seat].stats.rejectedRange += 1
            return
        }
        guard frame.seq > seats[seat].lastHeldSeq else {
            seats[seat].stats.stale += 1
            return
        }
        seats[seat].lastHeldSeq = frame.seq
        guard let tick = race.apply(input, seat: seat, atTick: frame.tick) else {
            seats[seat].stats.rejectedRange += 1
            return
        }
        if case .dropped = bots[seat] { resume(seat) }
        // The hold runs from the last held input the race will apply: a stamp ahead extends it.
        let last = max(seats[seat].lastHeldTick ?? tick, tick)
        seats[seat].lastHeldTick = last
        seats[seat].holdDeadline = last + options.inputHoldTicks
        applied(frame.seq, at: tick, seat: seat)
    }

    private func receiveTap(_ tap: BoatTap, frame: Frame, seat: Int) {
        guard admit(.tap, frame: frame, seat: seat) else { return }
        guard let tick = race.tap(tap, seat: seat, atTick: frame.tick) else {
            seats[seat].stats.rejectedRange += 1
            return
        }
        applied(frame.seq, at: tick, seat: seat)
    }

    /// Whether an input is under its cap and stamped no more than `maxTicksAhead` past the next tick.
    /// Disconnects a seat that keeps hitting the caps.
    private func admit(_ kind: InputGate.Kind, frame: Frame, seat: Int) -> Bool {
        guard seats[seat].gate.admit(kind, now: clock.now()) else {
            switch kind {
            case .held: seats[seat].stats.heldDropped += 1
            case .tap: seats[seat].stats.tapsDropped += 1
            }
            if seats[seat].gate.shouldDisconnect { disconnect(seat: seat) }
            return false
        }
        let margin = frame.tick - (race.tick + 1)
        guard margin <= options.caps.maxTicksAhead else {
            seats[seat].stats.rejectedAhead += 1
            return false
        }
        seats[seat].latestMargin = margin
        return true
    }

    private func applied(_ seq: UInt32, at tick: Int, seat: Int) {
        seats[seat].stats.applied += 1
        seats[seat].queued.append((seq, tick))
    }

    // MARK: - Close

    /// Closes the race where it stands, or returns how it closed: the standings, the digest and the log.
    /// Sends `RaceClosed` to every attached seat. Called by the scheduler when the race is over.
    @discardableResult
    public func close() -> RaceOutcome {
        if let outcome { return outcome }
        let outcome = RaceOutcome(standings: race.standings(), digest: race.digest(), log: log)
        self.outcome = outcome
        flushReliable()
        // Results schema is #86's: `.none` until then.
        for seat in seats.indices { send(.raceClosed(RaceClosed(results: .none)), to: seat) }
        return outcome
    }
}
