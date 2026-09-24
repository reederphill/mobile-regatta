import RegattaCore
import RegattaProtocol

/// The server's race clock as seen from the client's monotonic clock, from `Ping` / `Pong` (#64).
///
/// Times are microseconds. The server's clock is its tick plus `Pong.sinceTickMicros`, so tick `t` is
/// at `t · tickMicros` on it. Each pong gives a round trip and, assuming the two legs were equal, the
/// offset between the clocks; the sample with the shortest round trip in the window is the one whose
/// legs were least delayed, so its offset is the estimate (as NTP does). Against that offset every
/// sample then gives its own uplink delay, the time the ping took to reach the server: their spread
/// is the uplink's jitter, which `LeadController` covers.
///
/// Pings go every `fastInterval` until `fastSamples` pongs are in, so the clock and lead settle within
/// a second or so, then every `interval`.
public struct ClockSync: Sendable {
    public static let tickMicros = 1_000_000.0 / Double(Race.tickRate)

    public struct Sample: Hashable, Sendable {
        /// When the ping left, on the client's clock.
        public let sentAt: UInt64
        public let roundTrip: UInt64
        /// The server's clock when it answered.
        public let serverTime: Double
    }

    /// Builder choices: 10 Hz until 8 samples, then 2 Hz; 32 samples (16 s at 2 Hz) in the window.
    public var fastInterval: UInt64 = 100_000
    public var interval: UInt64 = 500_000
    public var fastSamples = 8
    public var window = 32

    /// The latest samples, oldest first, at most `window`.
    public private(set) var samples: [Sample] = []
    /// Pongs received in all, including those that have left the window.
    public private(set) var pongs = 0
    /// Server clock minus client clock, from the fastest sample; nil before the first pong.
    public private(set) var offset: Double?
    private var nextPingAt: UInt64?

    public init() {}

    public var isSynchronised: Bool { offset != nil }

    /// The shortest round trip in the window.
    public var minRoundTrip: UInt64? { samples.map(\.roundTrip).min() }

    /// A ping to send now, if one is due.
    public mutating func pingIfDue(now: UInt64) -> Ping? {
        if let next = nextPingAt, now < next { return nil }
        nextPingAt = now + (pongs < fastSamples ? fastInterval : interval)
        return Ping(clientTime: now)
    }

    /// Takes a pong whose frame tick is `tick`, received at `now`. Ignores one that echoes a time the
    /// client hasn't reached.
    public mutating func receive(_ pong: Pong, tick: Int, now: UInt64) {
        guard pong.clientTime <= now else { return }
        let sample = Sample(sentAt: pong.clientTime, roundTrip: now - pong.clientTime,
                            serverTime: Double(tick) * Self.tickMicros + Double(pong.sinceTickMicros))
        samples.append(sample)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        pongs += 1
        // The first of the fastest samples, so a tie never moves the estimate.
        var best = samples[0]
        for s in samples.dropFirst() where s.roundTrip < best.roundTrip { best = s }
        offset = best.serverTime - (Double(best.sentAt) + Double(best.roundTrip) / 2)
    }

    /// The server's tick at `now`, with its fraction: nil before the first pong.
    public func serverTick(at now: UInt64) -> Double? {
        offset.map { (Double(now) + $0) / Self.tickMicros }
    }

    /// Each sample's uplink delay against the current offset, microseconds, oldest first.
    public var uplinkDelays: [Double] {
        guard let offset else { return [] }
        return samples.map { $0.serverTime - offset - Double($0.sentAt) }
    }
}
