import RegattaCore

/// A clock that moves only when told: microseconds, like the client's monotonic clock. Tests, the load
/// client's scripted runs (#67) and the app's transport tests (#68) share one between a
/// `FaultInjectingLink` and whatever drives the client, so a run replays exactly.
public final class VirtualClock {
    public var now: UInt64

    public init(now: UInt64 = 0) { self.now = now }

    public func advance(by micros: UInt64) { now += micros }
}

/// The faults on one direction of a `FaultInjectingLink`. Times are microseconds.
public struct LinkFaults: Hashable, Sendable {
    /// The fixed one-way delay.
    public var delay: UInt64
    /// Extra delay, uniform in 0…`jitter`, drawn per frame.
    public var jitter: UInt64
    /// The chance a frame is lost, 0…1.
    public var loss: Double
    /// The chance a frame is held back a further `reorderDelay`, so frames sent after it overtake it.
    public var reorder: Double
    public var reorderDelay: UInt64
    /// Delivers frames in the order sent, as TCP (and so a WebSocket) does: a delayed frame holds up
    /// the ones behind it. Reordering is then impossible and `reorder` only adds delay.
    public var inOrder: Bool

    public static let none = LinkFaults()

    public init(delay: UInt64 = 0, jitter: UInt64 = 0, loss: Double = 0, reorder: Double = 0,
                reorderDelay: UInt64 = 0, inOrder: Bool = false) {
        self.delay = delay
        self.jitter = jitter
        self.loss = loss
        self.reorder = reorder
        self.reorderDelay = reorderDelay
        self.inOrder = inOrder
    }
}

/// An in-memory connection between a client and a server end, on a `VirtualClock`, that delays,
/// jitters, loses and reorders frames and can be cut (#64). Every fault is drawn from SplitMix64 streams
/// of `seed`, never the standard library's randomness, so a run is the same every time (ADR 0002's
/// rules, kept by the client package too).
public final class FaultInjectingLink {
    public enum Direction: Sendable {
        /// Client → server.
        case uplink
        /// Server → client.
        case downlink
    }

    /// One end of the link.
    public final class Endpoint: RaceTransport {
        /// Weak: an end outliving its link reads as a closed connection.
        weak var link: FaultInjectingLink?
        let sends: Direction
        /// The connection this end belongs to; `reconnect()` starts another.
        let connection: Int

        init(link: FaultInjectingLink, sends: Direction) {
            self.link = link
            self.sends = sends
            connection = link.connection
        }

        public var isConnected: Bool {
            guard let link else { return false }
            return link.isConnected && connection == link.connection
        }

        public func send(_ frame: [UInt8]) {
            guard isConnected, let link else { return }
            link.send(frame, sends)
        }

        public func receive() -> [[UInt8]] {
            guard isConnected, let link else { return [] }
            return link.deliver(sends == .uplink ? .downlink : .uplink)
        }
    }

    /// What the link did with the frames sent, per direction.
    public struct Counts: Hashable, Sendable {
        public var sent = 0
        public var lost = 0
        public var delivered = 0
        public var bytesSent = 0
    }

    public let clock: VirtualClock
    public var uplink: LinkFaults
    public var downlink: LinkFaults
    public private(set) var isConnected = true
    public private(set) var uplinkCounts = Counts()
    public private(set) var downlinkCounts = Counts()
    /// Called for every frame sent while connected, lost or not, with the send time: for tests that
    /// count what an end sent.
    public var onSend: ((Direction, _ time: UInt64, _ frame: [UInt8]) -> Void)?
    /// Scripted loss on top of `loss`: a frame for which it returns true is lost. For tests that need
    /// one particular frame to go missing.
    public var drop: ((Direction, _ frame: [UInt8]) -> Bool)?

    /// The client's end: it sends on the uplink.
    public private(set) var client: Endpoint!
    /// The server's end: it sends on the downlink.
    public private(set) var server: Endpoint!

    private struct InFlight {
        let deliverAt: UInt64
        let order: Int
        let frame: [UInt8]
    }

    private var rng: (uplink: SplitMix64, downlink: SplitMix64)
    private var inFlight: (uplink: [InFlight], downlink: [InFlight]) = ([], [])
    private var lastDeliverAt: (uplink: UInt64, downlink: UInt64) = (0, 0)
    private var sendCount = 0
    private var connection = 0

    public init(clock: VirtualClock, uplink: LinkFaults = .none, downlink: LinkFaults = .none, seed: UInt64) {
        self.clock = clock
        self.uplink = uplink
        self.downlink = downlink
        // "linkup" and "linkdown" streams: independent of each other and of any other use of the seed.
        rng = (SplitMix64(seed: seed, stream: 0x6C69_6E6B_7570), SplitMix64(seed: seed, stream: 0x6C69_6E6B_646F_776E))
        client = Endpoint(link: self, sends: .uplink)
        server = Endpoint(link: self, sends: .downlink)
    }

    /// Cuts the connection: frames in flight are lost, and so is anything sent until `reconnect()`.
    public func disconnect() {
        isConnected = false
        inFlight = ([], [])
        lastDeliverAt = (0, 0)
    }

    /// Restores the connection, as a new one: the ends are replaced, so an owner still holding an old
    /// end sees it disconnected, as it would a closed socket.
    public func reconnect() {
        isConnected = true
        connection += 1
        client = Endpoint(link: self, sends: .uplink)
        server = Endpoint(link: self, sends: .downlink)
    }

    public func counts(_ direction: Direction) -> Counts {
        direction == .uplink ? uplinkCounts : downlinkCounts
    }

    func send(_ frame: [UInt8], _ direction: Direction) {
        guard isConnected else { return }
        let now = clock.now
        onSend?(direction, now, frame)
        let faults = direction == .uplink ? uplink : downlink
        // Every draw is made for every frame, so one fault's setting never moves another's draws.
        var r = direction == .uplink ? rng.uplink : rng.downlink
        let lost = r.unit() < faults.loss || drop?(direction, frame) == true
        let jitter = faults.jitter == 0 ? 0 : UInt64(r.unit() * Double(faults.jitter + 1))
        let held = r.unit() < faults.reorder
        if direction == .uplink { rng.uplink = r } else { rng.downlink = r }
        update(direction) {
            $0.sent += 1
            $0.bytesSent += frame.count
            if lost { $0.lost += 1 }
        }
        guard !lost else { return }
        var deliverAt = now + faults.delay + min(jitter, faults.jitter) + (held ? faults.reorderDelay : 0)
        if faults.inOrder {
            deliverAt = max(deliverAt, direction == .uplink ? lastDeliverAt.uplink : lastDeliverAt.downlink)
        }
        if direction == .uplink { lastDeliverAt.uplink = deliverAt } else { lastDeliverAt.downlink = deliverAt }
        sendCount += 1
        let item = InFlight(deliverAt: deliverAt, order: sendCount, frame: frame)
        if direction == .uplink { inFlight.uplink.append(item) } else { inFlight.downlink.append(item) }
    }

    /// The frames on `direction` due by now, by delivery time, then in the order sent.
    func deliver(_ direction: Direction) -> [[UInt8]] {
        guard isConnected else { return [] }
        let now = clock.now
        let queue = direction == .uplink ? inFlight.uplink : inFlight.downlink
        let due = queue.filter { $0.deliverAt <= now }
        guard !due.isEmpty else { return [] }
        let rest = queue.filter { $0.deliverAt > now }
        if direction == .uplink { inFlight.uplink = rest } else { inFlight.downlink = rest }
        update(direction) { $0.delivered += due.count }
        return due.sorted { ($0.deliverAt, $0.order) < ($1.deliverAt, $1.order) }.map(\.frame)
    }

    private func update(_ direction: Direction, _ change: (inout Counts) -> Void) {
        if direction == .uplink { change(&uplinkCounts) } else { change(&downlinkCounts) }
    }
}
