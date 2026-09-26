import RegattaCore
import RegattaProtocol

/// An online race as the client sails it (#64): the clock sync, the adaptive lead, the input stamping
/// under the caps, the predicted fleet and its resyncs, over one `RaceTransport`.
///
/// The owner (the app's online driver, #68, or the load client, #67) makes the connection, does the
/// handshake and joins the race, then hands the `RaceStart` and the transport over. After that it sets
/// the helm (`setHeld`), taps (`tap`), and calls `update(now:)` every frame with its monotonic clock
/// in microseconds; the client does nothing between calls. It reads `predicted` to draw the fleet,
/// `predicted.events` for the server's finishes, places and whether the race is over, and
/// `drainServerEvents()` for the server's calls as they happen. Not thread-safe: one owner drives it.
///
/// Each update:
/// 1. reads every frame that has arrived: pongs into the clock, snapshots and resyncs into the
///    prediction, reliable events and keys in order, and the server's input feedback into the lead;
/// 2. pings if one is due;
/// 3. once the clock is synchronised, moves the client's tick to `⌊server tick + lead⌋`, never back,
///    sends the input messages due, stamped from the clock (`max(client tick + 1, ⌊server tick + lead⌋)`,
///    so an update that comes late never stamps behind the server), and sails the fleet to the client's
///    tick, unless it is waiting for a resync to rebuild it;
/// 4. asks for a `Resync` when it can't go on without one: a wind key it needs is missing (never
///    guessed, ADR 0001), the reliable stream has a gap, a snapshot won't import, or it has joined a race
///    under way (`attach`, a second `RaceStart`, `joiningUnderway`). At most once per `resyncInterval`,
///    until one comes. In the last case it sails nothing until the resync is in: sailing a fresh race
///    from the start sequence to the server's tick would take the whole race's simulation in one frame.
public final class RaceClient {
    public enum Status: Equatable, Sendable {
        /// Waiting for the first pong: not sailing or sending inputs yet.
        case synchronising
        case predicting
        /// Stopped before a tick whose wind needs this key, and asking for a resync.
        case waitingForWindKey(Int)
        /// Joined a race under way, or reconnected: not sailing until the resync is in.
        case awaitingResync
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
        /// Snapshots skipped unimported because a newer one arrived in the same update.
        public var snapshotsSuperseded = 0
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
    /// Sail nothing until a resync is applied.
    private var awaitingResync = false

    /// `joiningUnderway`: the race started before this client joined it (a rejoin, #68). The server
    /// sends a `Resync` after the `RaceStart`; the client asks for one too, and sails from it.
    public init(start: RaceStart, transport: RaceTransport, limits: InputLimits = InputLimits(),
                joiningUnderway: Bool = false) {
        self.transport = transport
        predicted = PredictedRace(start: start)
        stamper = InputStamper(limits: limits)
        clientTick = predicted.tick
        if joiningUnderway { awaitResync() }
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

    /// Carries on over a new connection, after a reconnect and join (#68): asks for a resync straight
    /// away, and sails nothing until it's in.
    public func attach(_ transport: RaceTransport) {
        self.transport = transport
        lastResyncRequest = nil
        awaitResync()
    }

    public func update(now: UInt64) {
        guard transport.isConnected else {
            status = .disconnected
            // Taps made while the connection is down would be stale when it's back.
            stamper.clearPendingTaps()
            return
        }
        var frames: [Frame] = []
        for bytes in transport.receive() {
            guard let frame = try? Frame(decoding: bytes) else {
                stats.undecodableFrames += 1
                continue
            }
            frames.append(frame)
        }
        // Only the newest snapshot of a batch is imported: each holds the whole fleet, and each import
        // re-predicts to the client's tick. Importing every one of a backlog (after a stall) would cost a
        // re-prediction apiece, and a client that falls behind that way never catches up.
        var newestSnapshot: Int?
        for (index, frame) in frames.enumerated() {
            guard case .snapshot = frame.message else { continue }
            if let newest = newestSnapshot, frames[newest].tick > frame.tick { continue }
            newestSnapshot = index
        }
        for (index, frame) in frames.enumerated() {
            if case .snapshot = frame.message, index != newestSnapshot {
                stats.snapshotsSuperseded += 1
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
        if let serverTick = clock.serverTick(at: now) { sail(now: now, serverTick: serverTick) }
        if reliable.isBroken(now: now) { wantsResync = true }
        if wantsResync { requestResync(now: now) }
    }

    /// Sends the inputs due and sails the fleet to the client's tick, once the clock is synchronised.
    private func sail(now: UInt64, serverTick: Double) {
        lead.update(uplinkDelays: clock.uplinkDelays, now: now)

        let target = Int((serverTick + lead.lead).rounded(.down))
        // Stamped from the clock: after a late update (a hitch, the first update, a stall) the ticks
        // before `target` are already past on the clock, and stamping them would make the input late.
        let stamp = max(clientTick + 1, target)
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
        guard !awaitingResync else {
            status = .awaitingResync
            return
        }
        predicted.advance(to: clientTick)

        if let key = predicted.missingWindKey {
            status = .waitingForWindKey(key)
            wantsResync = true
        } else {
            status = .predicting
        }
    }

    // MARK: - Receiving

    private func receive(_ frame: Frame, now: UInt64) {
        switch frame.message {
        case .pong(let pong):
            clock.receive(pong, tick: frame.tick, now: now)
        case .snapshot(let snapshot):
            // Until the resync is in, the race is at another tick altogether: nothing to import into.
            guard !awaitingResync else { return }
            do {
                // Feedback only from a snapshot newer than the last: a stale one's ack is older news.
                guard try predicted.apply(snapshot, tick: frame.tick) else { return }
                if let ack = snapshot.ack, ack.seq != lastAckSeq {
                    lastAckSeq = ack.seq
                    lead.feedback(margin: Int(ack.margin), now: now)
                }
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
                awaitingResync = false
                let next = resync.eventState.nextEventSeq
                if let already = reliable.delivered(since: next) {
                    // Frames from `next` on reached us before the resync, and the server won't send them
                    // again: its state lacks them, so they go on top. Shown once already, so not again.
                    for frame in already { apply(frame) }
                } else {
                    reliable.restart(at: next)
                    for ready in reliable.drain(now: now) { deliver(ready) }
                }
            } catch {
                wantsResync = true
            }
        case .raceStart(let start):
            // A rejoin (#68): the race again, then the resync to bring it up to the server's tick.
            predicted = PredictedRace(start: start)
            clientTick = max(clientTick, predicted.tick)
            reliable = ReliableStream(next: 1)
            awaitResync()
        case .raceClosed, .raceCancelled:
            closed = true
        case .hello, .joinRace, .inputHeld, .inputTap, .ping, .requestResync, .helloAck, .updateRequired:
            break
        }
    }

    /// A reliable frame, in order, for the first time: into the prediction, and an event to the owner.
    private func deliver(_ frame: Frame) {
        apply(frame)
        if let event = frame.raceEvent { serverEvents.append(event) }
    }

    private func apply(_ frame: Frame) {
        switch frame.message {
        case .event:
            guard let event = frame.raceEvent else { return }
            predicted.record(event, seq: frame.seq)
        case .windKey(let key):
            predicted.reveal(key, seq: frame.seq)
        default:
            break
        }
    }

    private func awaitResync() {
        awaitingResync = true
        wantsResync = true
        status = .awaitingResync
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
