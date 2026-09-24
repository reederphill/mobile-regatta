import RegattaCore
import RegattaProtocol

/// An online race as the client sails it (#64): the clock sync, the adaptive lead, the input stamping
/// under the caps, the predicted fleet and its resyncs, over one `RaceTransport`.
///
/// The owner (the app's online driver, #68, or the load client, #67) makes the connection, does the
/// handshake and joins the race, then hands the `RaceStart` and the transport over. After that it sets
/// the helm (`setHeld`), taps (`tap`), and calls `update(now:)` every frame with its monotonic clock
/// in microseconds; the client does nothing between calls. It reads `predicted` to draw the fleet and
/// `drainServerEvents()` for the server's rule calls and results. Not thread-safe: one owner drives it.
///
/// Each update:
/// 1. reads every frame that has arrived: pongs into the clock, snapshots and resyncs into the
///    prediction, reliable events and keys in order, and the server's input feedback into the lead;
/// 2. pings if one is due;
/// 3. once the clock is synchronised, moves the client's tick to `⌊server tick + lead⌋`, never back,
///    sends the input messages due (stamped for the first tick it's about to sail) and sails the fleet
///    to the client's tick;
/// 4. asks for a `Resync` when it can't go on without one: a wind key it needs is missing (never
///    guessed, ADR 0001), the reliable stream has a gap, or a snapshot won't import. At most once per
///    `resyncInterval`, until one comes.
public final class RaceClient {
    public enum Status: Equatable, Sendable {
        /// Waiting for the first pong: not sailing or sending inputs yet.
        case synchronising
        case predicting
        /// Stopped before a tick whose wind needs this key, and asking for a resync.
        case waitingForWindKey(Int)
        case disconnected
        /// `RaceClosed` or `RaceCancelled` came.
        case finished
    }

    /// What the client has done, for tests, the load client's report (#67) and the HUD's lag warning.
    public struct Stats: Hashable, Sendable {
        public var heldSent = 0
        public var tapsSent = 0
        public var tapsRefused = 0
        public var pingsSent = 0
        public var resyncRequests = 0
        public var resyncsApplied = 0
        public var snapshotsRefused = 0
        public var undecodableFrames = 0
    }

    /// A builder choice: at most one resync request a second while waiting for one.
    public var resyncInterval: UInt64 = 1_000_000

    public private(set) var transport: RaceTransport
    public private(set) var predicted: PredictedRace
    public private(set) var clock = ClockSync()
    public private(set) var lead = LeadController()
    public private(set) var stamper: InputStamper
    public private(set) var stats = Stats()
    public private(set) var status: Status = .synchronising
    /// The client's tick: the one the race is sailed to, and after which inputs are stamped.
    public private(set) var clientTick: Int

    private var reliable = ReliableStream(next: 1)
    private var serverEvents: [RaceEvent] = []
    private var lastAckSeq: UInt32?
    private var lastResyncRequest: UInt64?
    private var wantsResync = false
    private var otherSeq: UInt32 = 1
    private var closed = false
    private var started = false

    public init(start: RaceStart, transport: RaceTransport, limits: InputLimits = InputLimits()) {
        self.transport = transport
        predicted = PredictedRace(start: start)
        stamper = InputStamper(limits: limits)
        clientTick = predicted.tick
    }

    public var seat: Int { predicted.seat }

    /// The player's held input from now on; it goes out at the next update if it changed.
    public func setHeld(_ input: BoatInput) { stamper.setHeld(input) }

    /// Queues a tap for the next update. False if it would pass the tap cap (#26): it's dropped.
    @discardableResult
    public func tap(_ tap: BoatTap, now: UInt64) -> Bool {
        let accepted = stamper.tap(tap, now: now)
        if !accepted { stats.tapsRefused += 1 }
        return accepted
    }

    /// The server's events since the last call, in order: the only rule calls, penalties and results a
    /// client shows (#18).
    public func drainServerEvents() -> [RaceEvent] {
        defer { serverEvents.removeAll() }
        return serverEvents
    }

    /// Carries on over a new connection, after a reconnect and join (#68): asks for a resync straight away.
    public func attach(_ transport: RaceTransport) {
        self.transport = transport
        wantsResync = true
        lastResyncRequest = nil
        if status == .disconnected { status = clock.isSynchronised ? .predicting : .synchronising }
    }

    public func update(now: UInt64) {
        guard transport.isConnected else {
            status = .disconnected
            return
        }
        for bytes in transport.receive() {
            guard let frame = try? Frame(decoding: bytes) else {
                stats.undecodableFrames += 1
                continue
            }
            receive(frame, now: now)
        }
        guard !closed else {
            status = .finished
            return
        }
        if let ping = clock.pingIfDue(now: now) {
            send(.ping(ping), tick: clientTick)
            stats.pingsSent += 1
        }
        guard let serverTick = clock.serverTick(at: now) else { return }
        lead.update(uplinkDelays: clock.uplinkDelays, now: now)

        let target = Int((serverTick + lead.lead).rounded(.down))
        if !started {
            // The first synchronised update: the race start's tick is long gone on the server.
            started = true
            clientTick = max(clientTick, target - 1)
        }
        // Inputs are stamped for the first tick this update sails.
        let stamp = clientTick + 1
        for input in stamper.outgoing(now: now, tick: stamp) {
            switch input.kind {
            case .held(let held):
                send(.inputHeld(held), seq: input.seq, tick: input.tick)
                stats.heldSent += 1
            case .tap(let tap):
                send(.inputTap(tap), seq: input.seq, tick: input.tick)
                stats.tapsSent += 1
            }
            predicted.sent(input)
        }
        clientTick = max(clientTick, target)
        predicted.advance(to: clientTick)

        if let key = predicted.missingWindKey {
            status = .waitingForWindKey(key)
            wantsResync = true
        } else {
            status = .predicting
        }
        if reliable.isBroken(now: now) { wantsResync = true }
        if wantsResync { requestResync(now: now) }
    }

    // MARK: - Receiving

    private func receive(_ frame: Frame, now: UInt64) {
        switch frame.message {
        case .pong(let pong):
            clock.receive(pong, tick: frame.tick, now: now)
        case .snapshot(let snapshot):
            if let ack = snapshot.ack, ack.seq != lastAckSeq {
                lastAckSeq = ack.seq
                lead.feedback(margin: Int(ack.margin), now: now)
            }
            do {
                try predicted.apply(snapshot, tick: frame.tick)
            } catch {
                stats.snapshotsRefused += 1
                wantsResync = true
            }
        case .event, .windKey:
            for ready in reliable.receive(frame, now: now) { deliver(ready) }
        case .resync(let resync):
            do {
                try predicted.apply(resync, tick: frame.tick)
                stats.resyncsApplied += 1
                wantsResync = false
                reliable.restart(at: resync.eventState.nextEventSeq)
                for ready in reliable.drain(now: now) { deliver(ready) }
            } catch {
                wantsResync = true
            }
        case .raceStart(let start):
            // A rejoin (#68): the race again, then a resync to bring it up to the server's tick.
            predicted = PredictedRace(start: start)
            clientTick = max(clientTick, predicted.tick)
            reliable = ReliableStream(next: 1)
            wantsResync = true
        case .raceClosed, .raceCancelled:
            closed = true
        case .hello, .joinRace, .inputHeld, .inputTap, .ping, .requestResync, .helloAck, .updateRequired:
            break
        }
    }

    private func deliver(_ frame: Frame) {
        switch frame.message {
        case .event:
            guard let event = frame.raceEvent else { return }
            predicted.record(event, seq: frame.seq)
            serverEvents.append(event)
        case .windKey(let key):
            predicted.reveal(key, seq: frame.seq)
        default:
            break
        }
    }

    // MARK: - Sending

    private func requestResync(now: UInt64) {
        if let last = lastResyncRequest, now - last < resyncInterval { return }
        lastResyncRequest = now
        send(.requestResync, tick: clientTick)
        stats.resyncRequests += 1
    }

    private func send(_ message: Message, tick: Int) {
        send(message, seq: otherSeq, tick: tick)
        otherSeq &+= 1
    }

    private func send(_ message: Message, seq: UInt32, tick: Int) {
        // A frame the codec refuses can only be a bug here (a tick past int32, a protest of a seat
        // number past 255); it isn't sent.
        guard let bytes = try? Frame(seq: seq, tick: tick, message: message).encoded() else { return }
        transport.send(bytes)
    }
}
