/// The host's limits on what a seat may send (#18, #26).
public struct InputCaps: Hashable, Sendable {
    /// Held-input messages per `window` (#26: 60 a second). More are dropped.
    public var held = 60
    /// Taps per `window` (#26: 5 a second). More are dropped.
    public var taps = 5
    /// The sliding window the caps count over, in microseconds: one second, by arrival time.
    public var window: UInt64 = 1_000_000
    /// How far past the host's next tick a stamp may be, in ticks (#18: 1 s ahead). Further is rejected
    /// before it reaches `Race`, so a client can't grow the race's pending queue without limit.
    public var maxTicksAhead = 30
    /// A seat that has messages dropped in this many separate windows within `strikeWindow` is
    /// disconnected (#26: "a client that keeps hitting the caps"). Builder choice: 3 in 10 s.
    public var strikesToDisconnect = 3
    public var strikeWindow: UInt64 = 10_000_000

    public init() {}
}

/// Counts events in a sliding window: allows one only while fewer than `cap` fall in the last `window`.
struct SlidingWindow: Sendable {
    let cap: Int
    let window: UInt64
    private var times: [UInt64] = []

    init(cap: Int, window: UInt64) {
        self.cap = cap
        self.window = window
    }

    /// Whether one more is allowed at `now`; records it if so.
    mutating func admit(now: UInt64) -> Bool {
        times.removeAll { now >= $0 && now - $0 >= window }
        guard times.count < cap else { return false }
        times.append(now)
        return true
    }
}

/// One seat's rate caps and strikes.
struct InputGate: Sendable {
    enum Kind { case held, tap }

    private let caps: InputCaps
    private var held: SlidingWindow
    private var taps: SlidingWindow
    /// When each strike was given, oldest first. At most one per `caps.window`.
    private var strikes: [UInt64] = []

    init(caps: InputCaps) {
        self.caps = caps
        held = SlidingWindow(cap: caps.held, window: caps.window)
        taps = SlidingWindow(cap: caps.taps, window: caps.window)
    }

    /// Whether a message of `kind` arriving at `now` is within the cap. A dropped one may give a strike.
    mutating func admit(_ kind: Kind, now: UInt64) -> Bool {
        let allowed = switch kind {
        case .held: held.admit(now: now)
        case .tap: taps.admit(now: now)
        }
        if !allowed { strike(now: now) }
        return allowed
    }

    /// Whether the seat has kept hitting the caps: `strikesToDisconnect` strikes within `strikeWindow`.
    var shouldDisconnect: Bool { strikes.count >= caps.strikesToDisconnect }

    private mutating func strike(now: UInt64) {
        strikes.removeAll { now >= $0 && now - $0 >= caps.strikeWindow }
        if let last = strikes.last, now >= last, now - last < caps.window { return }
        strikes.append(now)
    }
}
