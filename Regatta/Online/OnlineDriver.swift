import Foundation
import RegattaBots
import RegattaClient
import RegattaCore
import RegattaProtocol

/// Sails an online race for the app (#68): `RaceClient` (#64) predicts the whole fleet ahead of the server
/// on the last inputs it knows (ADR 0005), and this draws it. Not pausable: the race goes on without you.
///
/// Each display frame it hands the client your helm, updates it on the monotonic clock `now`, and keeps
/// the predicted race's tick as `currentFrame`. When a snapshot or resync moves the prediction, each boat
/// is drawn from where it was shown and eased onto the new track with its `VisualCorrection` (about
/// 150 ms, or a snap past a hull length).
///
/// Rule calls, OCS, penalties and finishes come only from the server's events (`drainEvents` is
/// `RaceClient.drainServerEvents()`); the prediction's own are dropped, so nothing is shown before the
/// server calls it (#18). The race is over when the server says so.
///
/// When the connection drops it rejoins on a new one from `connect` with the same race token (`RaceJoin`),
/// every `retryInterval` until one gets in, and hands it to the client, which asks for a `Resync` and
/// sails again once it's in. An `UpdateRequired` answer stops the retries.
final class OnlineDriver: RaceDriver {
    enum Connection: Equatable {
        case connected
        /// The connection dropped: rejoining, then waiting for the `Resync`.
        case reconnecting
        /// A rejoin was refused: this build can't race here any more.
        case updateRequired(UpdateRequired.Reason)
        /// The server closed the race.
        case closed
    }

    let myBoatIndex: Int
    let course: Course
    let boatClass: BoatClass
    let isPausable = false
    /// Names and bot marks, from the race's setup (#60).
    let roster: FleetRoster
    let client: RaceClient

    private(set) var previousFrame: TickFrame
    private(set) var currentFrame: TickFrame
    private(set) var alpha = 0.0
    private(set) var connection = Connection.connected
    /// Rejoins that got back into the race.
    private(set) var reconnects = 0
    /// Round trips over 250 ms for about 5 s (#18): a signal for the HUD, which #124 draws.
    var lagWarning: Bool { lag.isWarning }

    /// A builder choice: a failed rejoin is tried again a second later.
    var retryInterval: UInt64 = 1_000_000

    private let now: () -> UInt64
    private let connect: () -> RaceTransport
    private let token: [UInt8]
    private let clientBuild: String
    private var rejoin: RaceJoin?
    private var nextRejoinAt: UInt64 = 0
    private var lag = LagMonitor()
    private var corrections: [VisualCorrection]
    private var events: [RaceEvent] = []
    private var isClosed = false

    /// Sails the race `start` joined on `transport`. `now` is the monotonic clock in microseconds;
    /// `connect` opens a new connection to the race server for a rejoin with `token`.
    init(start: RaceStart, transport: RaceTransport, token: [UInt8], clientBuild: String,
         now: @escaping () -> UInt64, connect: @escaping () -> RaceTransport) {
        client = RaceClient(start: start, transport: transport)
        self.now = now
        self.connect = connect
        self.token = token
        self.clientBuild = clientBuild
        let race = client.predicted.race
        myBoatIndex = start.yourSeat
        course = race.course
        boatClass = race.boatClass
        roster = FleetRoster(setup: start.setup)
        corrections = race.boats.map { _ in VisualCorrection(snapDistance: race.boatClass.hull.length) }
        currentFrame = TickFrame(race: race, isOver: false)
        previousFrame = currentFrame
    }

    /// Whether the server has closed the race, or its event state says it's over.
    var isOver: Bool { isClosed || client.predicted.events.isOver }

    var renderWorld: RenderWorld {
        RenderWorld(course: course, boatClass: boatClass, myBoatIndex: myBoatIndex,
                    previous: previousFrame, current: currentFrame, alpha: alpha)
            .drawing { seat, boat in corrections.indices.contains(seat) ? corrections[seat].applied(to: boat) : boat }
    }

    @discardableResult
    func tick(_ dt: Double) -> [TickFrame] {
        let time = now()
        let shown = renderWorld
        let before = client.predicted
        let imported = (before.snapshotsImported, client.stats.resyncsApplied)
        let lastTick = currentFrame.tick

        client.update(now: time)
        events += client.drainServerEvents()
        lag.record(client.clock, now: time)
        keepConnected(now: time)

        let predicted = client.predicted
        let corrected = predicted !== before || (predicted.snapshotsImported, client.stats.resyncsApplied) != imported
        var frames: [TickFrame] = []
        if predicted.tick != lastTick || corrected || isOver != currentFrame.isOver {
            let frame = TickFrame(race: predicted.race, isOver: isOver)
            previousFrame = !corrected && frame.tick == lastTick + 1 ? currentFrame : frame.extrapolatedBackOneTick()
            currentFrame = frame
            if frame.tick != lastTick { frames.append(frame) }
        }
        alpha = drawAhead(now: time)
        if corrected {
            correct(from: shown)
        } else {
            for i in corrections.indices { corrections[i].advance(by: dt) }
        }
        return frames
    }

    func submit(_ input: BoatInput) {
        client.setHeld(input)
    }

    @discardableResult
    func tap(_ tap: BoatTap) -> Bool {
        guard !isOver else { return false }
        return client.tap(tap, now: now())
    }

    func drainEvents() -> [RaceEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - Drawing

    /// How far past the predicted tick the client's clock is, 0…1 of a tick: the server's tick plus the
    /// lead, less the tick the race was sailed to. 1 once it's over or while it waits for a key or resync.
    private func drawAhead(now: UInt64) -> Double {
        guard !isOver else { return 1 }
        guard let serverTick = client.clock.serverTick(at: now) else { return 0 }
        return (serverTick + client.lead.lead - Double(currentFrame.tick)).clamped(to: 0...1)
    }

    /// The prediction moved: each boat eases from where it was drawn, carried on along its velocity to
    /// the time drawn now, onto where the prediction has it.
    private func correct(from shown: RenderWorld) {
        let raw = RenderWorld(course: course, boatClass: boatClass, myBoatIndex: myBoatIndex,
                              previous: previousFrame, current: currentFrame, alpha: alpha)
        guard shown.boats.count == raw.boats.count, raw.boats.count == corrections.count else { return }
        let elapsed = raw.time - shown.time
        for i in corrections.indices {
            var carried = shown.boats[i]
            carried.position += carried.velocity * elapsed
            corrections[i].correct(shown: carried, corrected: raw.boats[i])
        }
    }

    // MARK: - Connection

    private func keepConnected(now: UInt64) {
        if client.status == .finished {
            if !isClosed && !events.contains(where: { $0.kind == .raceClosed }) {
                events.append(RaceEvent(tick: client.predicted.tick, kind: .raceClosed))
            }
            isClosed = true
        }
        if isClosed {
            connection = .closed
            rejoin = nil
            return
        }
        if case .updateRequired = connection { return }
        guard client.status == .disconnected else {
            connection = client.status == .awaitingResync && reconnects > 0 ? .reconnecting : .connected
            return
        }
        connection = .reconnecting
        guard let join = rejoin else {
            if now >= nextRejoinAt {
                rejoin = RaceJoin(connection: connect(), token: token, clientBuild: clientBuild, now: now)
            }
            return
        }
        join.poll(now: now)
        switch join.state {
        case .joined:
            if let transport = join.transport { client.attach(transport) }
            reconnects += 1
            rejoin = nil
        case .updateRequired(let reason):
            connection = .updateRequired(reason)
            rejoin = nil
        case .failed:
            rejoin = nil
            nextRejoinAt = now + retryInterval
        case .awaitingAck, .awaitingStart:
            break
        }
    }
}

/// The lag warning (#18): round trips over `threshold` for `sustain` or more, from the clock's pongs. A
/// ping that has had no pong for longer than the ping interval plus `threshold` counts as over too, so a
/// stalled connection warns as well.
struct LagMonitor {
    static let threshold: UInt64 = 250_000
    static let sustain: UInt64 = 5_000_000

    private(set) var isWarning = false
    /// When the round trips went over, while they still are.
    private(set) var overSince: UInt64?
    private var pongs = 0
    private var lastPongAt: UInt64?

    mutating func record(_ clock: ClockSync, now: UInt64) {
        let over: Bool
        if clock.pongs != pongs, let latest = clock.samples.last {
            pongs = clock.pongs
            lastPongAt = now
            over = latest.roundTrip > Self.threshold
        } else if let lastPongAt {
            over = overSince != nil || now - lastPongAt > clock.interval + Self.threshold
        } else {
            over = false
        }
        overSince = over ? overSince ?? now : nil
        isWarning = overSince.map { now - $0 >= Self.sustain } ?? false
    }
}
