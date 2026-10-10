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
    /// `Race.results`: every seat's result, if the race ended on its own or every human went (#86); nil if it was
    /// closed where it stood before it was over (a dev close, a shutdown).
    public var results: RaceResults? = nil
}

/// The race's results so far, as the host has them (#148): what the results stream is built from. No clock and no
/// randomness: the same race gives the same reading at the same tick.
public struct LiveResults: Hashable, Sendable {
    /// The last tick simulated.
    public var tick: Int
    /// `Race.expectedCloseTick`.
    public var expectedCloseTick: Int
    /// The finishers so far, in finish order, each with her finish tick.
    public var finishers: [SeatResult]
    /// The seats still sailing: neither finished nor disqualified. Empty once closed.
    public var sailing: [Int]
    /// The race's incident index (`Race.incidents`).
    public var incidents: IncidentIndex
    /// Penalty turns each seat has completed (`penaltyServed` events), by seat.
    public var turnsServed: [Int]
    /// The final results, once closed.
    public var results: RaceResults?

    public init(tick: Int, expectedCloseTick: Int, finishers: [SeatResult], sailing: [Int], incidents: IncidentIndex, turnsServed: [Int],
                results: RaceResults?) {
        self.tick = tick
        self.expectedCloseTick = expectedCloseTick
        self.finishers = finishers
        self.sailing = sailing
        self.incidents = incidents
        self.turnsServed = turnsServed
        self.results = results
    }
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
/// attaches and sends no held input is dropped the same way, `firstInputHoldTicks` after the attach, and
/// a seat no player attaches to `firstInputHoldTicks` after the host starts. A seat left before the gun
/// goes to a fleet bot for good (#35); left after it, the boat takes the dropped-boat path.
/// When every human is gone, `onAllGone` fires once, after the grace (G3).
///
/// Wind (#95): the host makes the wind keys from the secret wind seed and reveals each on
/// `WindKeyWire`'s schedule, a second before its window starts: on the reliable stream to every attached
/// seat, and in every `RaceStart` and `Resync` as the keys revealed so far. The seed never leaves the host.
public actor RaceHost {
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
        /// The reliable stream (`Event`, `WindKey`): the next sequence number, and frames not yet sent. The number
        /// runs on across a rejoin (`attach`), so it is the seat's stable id for an event for the whole race (#96).
        var reliableSeq: UInt32 = 1
        var reliableQueue: [Frame] = []
        var otherSeq: UInt32 = 1
        /// The tick of the last held input the host applied for the seat.
        var lastHeldTick: Int?
        /// The tick the input hold runs out at (#18), while a player sails the seat and its inputs have
        /// stopped or may yet. The host's start and each attach set it to the wait for the first input: a
        /// rejoin before it runs out cancels the drop, and a seat that never sends is still dropped.
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
    private let onBriefingLeave: (@Sendable (_ leave: BriefingLeave) -> Void)?
    /// Human seats already reported as briefing leaves: each at most once.
    private var briefingLeavesReported: Set<Int> = []
    /// Makes the wind keys from the secret wind seed (#75), ahead of the race's own chain, which holds keys
    /// only through its current window. Same seed and chain, so the keys are the race's.
    private var keyGenerator: WindKeyGenerator
    /// Clock time of the race's first tick, `-startSequenceTicks`.
    private let startedAt: UInt64
    private let startTick: Int
    private var seats: [Seat]
    /// Every key revealed so far, from window 0, in order (`WindKeyWire.revealTick`).
    private var revealed: [WindKey] = []
    /// The seats the setup gives to players: only these count as humans.
    private let humanSeats: [Int]
    /// Each human seat that is gone, and how (G3). A left seat stays gone: it can't rejoin.
    private var gone: [Gone?]
    private var goneCount = 0
    private var allGoneFired = false
    public private(set) var outcome: RaceOutcome?
    /// Set when the race was cancelled (#148): it never steps again and has no results.
    public private(set) var cancelled: RaceCancelled.Reason?
    /// Closed or cancelled.
    public var isEnded: Bool { outcome != nil || cancelled != nil }
    /// Each finisher's result row as she finished, in finish order (#148).
    private var finishers: [SeatResult] = []
    private var turnsServed: [Int]
    /// Moves on each event that changes the results so far (a finish, a call, a served turn...): the results stream
    /// reads `liveResults()` when it moves (#148).
    public private(set) var resultsVersion = 0

    /// A host for a new race, at the start of its sequence now. Seats the setup marks `.bot` are sailed
    /// by RegattaBots; the rest wait `firstInputHoldTicks` for a player to attach, then are dropped until
    /// one does. `roster` defaults to "Seat n" names.
    /// `onAllGone` fires once when every human is gone and the grace is over (G3; #148 closes the race).
    /// `onBriefingLeave` hears each human who left before the gun (#147, `BriefingLeave`).
    public init(setup: RaceSetup, windSeed: WindSeed, clock: any HostClock, options: RaceHostOptions = RaceHostOptions(),
                roster: [RosterEntry]? = nil,
                onBehind: (@Sendable (_ ticksBehind: Int) -> Void)? = nil,
                onAllGone: (@Sendable (_ allGone: AllGone) -> Void)? = nil,
                onBriefingLeave: (@Sendable (_ leave: BriefingLeave) -> Void)? = nil) {
        let race = Race(setup: setup, windSeed: windSeed)
        self.race = race
        bots = SeatControllers(setup: setup)
        self.roster = roster ?? race.boats.map { RosterEntry(name: "Seat \($0.id + 1)", colorIndex: $0.colorIndex) }
        self.clock = clock
        self.options = options
        self.onBehind = onBehind
        self.onAllGone = onAllGone
        self.onBriefingLeave = onBriefingLeave
        do {
            keyGenerator = try WindKeyGenerator(windSeed: windSeed, setup: race.windSetup, windows: race.wind.windows)
        } catch {
            preconditionFailure("a race built from a wind seed has keyed wind: \(error)")
        }
        startedAt = clock.now()
        startTick = race.tick
        seats = Array(repeating: Seat(caps: options.caps), count: race.boats.count)
        humanSeats = setup.seats.indices.filter { setup.seats[$0] == .human }
        gone = Array(repeating: nil, count: race.boats.count)
        turnsServed = Array(repeating: 0, count: race.boats.count)
        for seat in humanSeats { seats[seat].holdDeadline = startTick + options.firstInputHoldTicks }
        // Keys due before the first tick (from the window origin, #75): no seat is attached yet, so they
        // reach each seat in its `RaceStart`.
        revealed = Self.dueKeys(&keyGenerator, atTick: race.tick)
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
    /// Who sails each seat, by seat.
    public var rosterEntries: [RosterEntry] { roster }
    /// The tick the race starts at: `-startSequenceTicks`.
    public var firstTick: Int { startTick }
    /// `Race.expectedCloseTick` (#16, #147).
    public var expectedCloseTick: Int { race.expectedCloseTick }
    /// Whether the player at `seat` left (#16): her seat can't be rejoined.
    public func hasLeft(seat: Int) -> Bool { gone.indices.contains(seat) && gone[seat]?.kind == .left }

    /// The results so far (#148).
    public func liveResults() -> LiveResults {
        let finished = Set(finishers.map(\.seat))
        let sailing = race.isOver ? [] : race.boats.indices.filter { !finished.contains($0) && race.boats[$0].status != .dsq }
        return LiveResults(tick: race.tick, expectedCloseTick: race.expectedCloseTick, finishers: finishers, sailing: sailing,
                           incidents: race.incidents, turnsServed: turnsServed, results: race.results)
    }

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
        guard !isEnded else { return }
        let due = dueTick(at: clock.now())
        let behind = due - race.tick
        if behind > options.behindAlertTicks { onBehind?(behind) }
        while race.tick < due && !isEnded { step() }
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
        guard cancelled == nil else { return }
        if race.tick == 0 { reportAbsentAtGun() }
        for seat in seats.indices { acknowledge(seat) }
        for event in race.drainEvents() {
            noteResults(event)
            enqueue(event, to: EventAudience(event.kind))
        }
        let keys = Self.dueKeys(&keyGenerator, atTick: race.tick)
        revealed += keys
        for key in keys { enqueueReliable(.windKey(key), to: .everyone) }
        flushReliable()
        if race.tick % options.snapshotEvery == 0 { sendSnapshots() }
        if race.isOver { close() }
    }

    /// Keeps the results so far up to date with `event` (#148).
    private func noteResults(_ event: RaceEvent) {
        switch event.kind {
        case .finished(let seat, let place):
            finishers.append(SeatResult(seat: seat, place: place, code: .finished, finishTick: event.tick))
        case .penaltyServed(let seat):
            if turnsServed.indices.contains(seat) { turnsServed[seat] += 1 }
        case .ruleCall, .markTouch, .contact, .disqualified, .protestRecorded, .raceClosed, .penaltyStarted, .penaltyReset:
            break
        default:
            return
        }
        resultsVersion += 1
    }

    /// Makes every key whose reveal tick (`WindKeyWire.revealTick`) is at or before `tick`, not made yet.
    private static func dueKeys(_ generator: inout WindKeyGenerator, atTick tick: Int) -> [WindKey] {
        generator.keys(through: WindKeyWire.lastRevealedWindow(atTick: tick, windows: generator.windows))
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

    /// The fleet, quantised once, to every attached seat with its ack and the server umpire's relations of its
    /// boat to the fleet in range (#96, `WireRelation.relations(of:in:)`): a client's right-of-way glows and rule 17
    /// restrictions are the umpire's, never worked out from its own world (ADR 0005).
    private func sendSnapshots() {
        let world = race.exportSnapshot()
        guard let fleet = try? Snapshot(world: world) else { return }
        for seat in seats.indices where seats[seat].transport != nil {
            var snapshot = fleet
            snapshot.ack = seats[seat].ack
            snapshot.relations = WireRelation.relations(of: seat, in: race)
            send(.snapshot(snapshot), to: seat)
        }
    }

    // MARK: - Events

    /// Sends a race event the host decides, rather than the race, to `audience` only: a targeted notice
    /// such as the recall notice to the boat that is over (#9, #85). Stamped with the current tick.
    public func sendEvent(_ kind: RaceEvent.Kind, to audience: EventAudience) {
        guard !isEnded else { return }
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
        guard !isEnded, humanSeats.contains(seat), gone[seat]?.kind != .left else { return false }
        let rejoin = seats[seat].hasJoined
        // The reliable numbering runs on (#96): an event's seq is its id for the whole race, so a rejoined client
        // never takes a new event for one it showed before. The resync restarts its stream there.
        let reliableSeq = seats[seat].reliableSeq
        seats[seat] = Seat(caps: options.caps)
        seats[seat].reliableSeq = reliableSeq
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
        if !isEnded {
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
        guard !isEnded, humanSeats.contains(seat), gone[seat]?.kind != .left else { return false }
        let transport = seats[seat].transport
        seats[seat].transport = nil
        seats[seat].reliableQueue.removeAll()
        if race.tick < 0 {
            race.record(.leftBeforeGun, seat: seat)
            race.record(.botTookOver(.fleet), seat: seat)
            bots[seat] = .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed))
            seats[seat].holdDeadline = nil
            reportBriefingLeave(seat, .left)
        } else {
            race.record(.left, seat: seat)
            startHold(seat)
        }
        markGone(seat, .left)
        transport?.close()
        checkAllGone()
        if race.isOver { close() }
        return true
    }

    /// Reports `seat` as a briefing leave, once.
    private func reportBriefingLeave(_ seat: Int, _ kind: BriefingLeave.Kind) {
        guard briefingLeavesReported.insert(seat).inserted else { return }
        onBriefingLeave?(BriefingLeave(seat: seat, kind: kind))
    }

    /// At the gun: every human seat with no connection, that didn't leave for good, left the briefing and wasn't back by
    /// the gun (#147, owner Q6): a drop, backgrounding after lock, or a seat never joined. One back by now doesn't count.
    private func reportAbsentAtGun() {
        for seat in humanSeats where seats[seat].transport == nil && gone[seat]?.kind != .left {
            reportBriefingLeave(seat, .absentAtGun)
        }
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
        guard !allGoneFired, !isEnded, !race.isOver, !humanSeats.isEmpty else { return }
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
        let allGone = AllGone(tick: race.tick, leaveOrder: went.map { $0.seat }, isMassDrop: isMassDrop)
        if config.endsRace {
            switch config.ending(allGone) {
            // At the trigger's tick, after its step and seat events (#86): the log records it, and a replay closes the same way.
            case .closeAllGone: race.closeAllGone(atTick: race.tick, leaveOrder: allGone.leaveOrder)
            case .cancel: cancel(.unspecified)
            }
        }
        onAllGone?(allGone)
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
        guard !isEnded, seats.indices.contains(seat), seats[seat].transport != nil else { return }
        advance()
        guard !isEnded, let frame = try? Frame(decoding: bytes) else { return }
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
        // Over before the gun (every human gone, G3): whoever isn't back never came back by the gun.
        if race.tick < 0, race.isOver, cancelled == nil { reportAbsentAtGun() }
        let outcome = RaceOutcome(standings: race.standings(), digest: race.digest(), log: log, results: race.results)
        self.outcome = outcome
        // A cancelled race told its seats so; it has no close to send.
        guard cancelled == nil else { return outcome }
        flushReliable()
        // The results reach clients in the `raceClosed` event (#86); the message's own results stream is
        // #148's: `.none` until then.
        for seat in seats.indices { send(.raceClosed(RaceClosed(results: .none)), to: seat) }
        return outcome
    }

    /// Cancels the race (#30, #148): it never steps again, has no results, and every attached seat is sent
    /// `RaceCancelled` and closed. Nothing if it has already closed or been cancelled.
    public func cancel(_ reason: RaceCancelled.Reason) {
        guard !isEnded else { return }
        cancelled = reason
        for seat in seats.indices {
            guard let transport = seats[seat].transport else { continue }
            send(.raceCancelled(RaceCancelled(reason: reason)), to: seat)
            seats[seat].transport = nil
            seats[seat].reliableQueue.removeAll()
            transport.close()
        }
    }
}
