import RegattaCore

/// The client's input caps and heartbeat (#26, #18). Times are microseconds.
public struct InputLimits: Hashable, Sendable {
    /// Held-input messages per `window` (#26: 60 a second).
    public var held = 60
    /// Taps per `window` (#26: 5 a second).
    public var taps = 5
    /// The server's sliding window: one second.
    public var window: UInt64 = 1_000_000
    /// Added to `window` when the client counts its own sends, so that jitter bunching frames up on the
    /// way can't put more than the cap into any second of the server's arrivals: that holds while the
    /// uplink's jitter is under the guard band.
    public var guardBand: UInt64 = 250_000
    /// A held input goes again after this long without one, so the server never mistakes a steady helm
    /// for a dropped player (#18: it holds the last input 0.5 s, then treats the seat as gone). A builder
    /// choice: 200 ms, so two in a row can be lost inside that 0.5 s.
    public var heartbeat: UInt64 = 200_000
    /// A tap not sent within this long of being made is dropped: stamped any later, a tack would
    /// surprise the player. A builder choice: 250 ms.
    public var maxTapAge: UInt64 = 250_000

    public init() {}
}

/// Counts events in a sliding window: allows one only while fewer than `cap` fall in the last `window`.
struct SlidingWindowLimiter: Sendable {
    let cap: Int
    let window: UInt64
    /// Times in the window, oldest first.
    private(set) var times: [UInt64] = []

    init(cap: Int, window: UInt64) {
        self.cap = cap
        self.window = window
    }

    mutating func allows(now: UInt64, extra: Int = 0) -> Bool {
        if let firstInside = times.firstIndex(where: { now - $0 < window }) {
            times.removeFirst(firstInside)
        } else {
            times.removeAll()
        }
        return times.count + extra < cap
    }

    mutating func record(now: UInt64) { times.append(now) }
}

/// One input message the client sends, before it's framed.
public struct StampedInput: Hashable, Sendable {
    /// On the input stream, from 1 (`MessageType.Stream.input`).
    public let seq: UInt32
    /// The tick it applies at.
    public let tick: Int
    public let kind: InputRecord.Kind
}

/// Turns the player's helm and taps into stamped input messages under the caps (#18, #26).
///
/// - The held input goes when it changes, at most once per stamped tick (the server keeps only a seat's
///   last held input for a tick, so more would be wasted), and again every `heartbeat` when it doesn't.
///   Over the cap, a change waits for room and then goes with its latest value: it is never lost.
/// - A tap goes once, stamped with the next tick. Over the cap it is refused when it's made (`tap`
///   returns false), as the server would drop it, rather than delayed until it no longer makes sense;
///   one that can't be sent within `maxTapAge` (the client wasn't synchronised or updating) is dropped.
public struct InputStamper: Sendable {
    public let limits: InputLimits
    /// The input the player holds now.
    public private(set) var held = BoatInput.neutral
    public private(set) var lastSentHeld: BoatInput?
    public private(set) var nextSeq: UInt32 = 1
    private var lastHeldTick: Int?
    private var lastHeldAt: UInt64?
    private struct PendingTap: Sendable {
        let tap: BoatTap
        let madeAt: UInt64
    }

    private var pendingTaps: [PendingTap] = []
    private var heldLimiter: SlidingWindowLimiter
    private var tapLimiter: SlidingWindowLimiter

    public init(limits: InputLimits = InputLimits()) {
        self.limits = limits
        heldLimiter = SlidingWindowLimiter(cap: limits.held, window: limits.window + limits.guardBand)
        tapLimiter = SlidingWindowLimiter(cap: limits.taps, window: limits.window + limits.guardBand)
    }

    public mutating func setHeld(_ input: BoatInput) { held = input }

    /// Queues `tap` for the next send; false, and nothing queued, if it would pass the tap cap.
    public mutating func tap(_ tap: BoatTap, now: UInt64) -> Bool {
        guard tapLimiter.allows(now: now, extra: pendingTaps.count) else { return false }
        pendingTaps.append(PendingTap(tap: tap, madeAt: now))
        return true
    }

    /// Drops the taps not yet sent, e.g. when the connection goes: they'd be stale by the time it's back.
    public mutating func clearPendingTaps() { pendingTaps.removeAll() }

    /// The messages to send at `now`, stamped for `tick`: the held input if it changed or a heartbeat
    /// is due, then any taps.
    public mutating func outgoing(now: UInt64, tick: Int) -> [StampedInput] {
        var out: [StampedInput] = []
        let changed = lastSentHeld != held
        let heartbeat = lastHeldAt.map { now - $0 >= limits.heartbeat } ?? true
        let newTick = lastHeldTick.map { tick > $0 } ?? true
        if (changed || heartbeat) && newTick && heldLimiter.allows(now: now) {
            heldLimiter.record(now: now)
            out.append(StampedInput(seq: takeSeq(), tick: tick, kind: .held(held)))
            lastSentHeld = held
            lastHeldTick = tick
            lastHeldAt = now
        }
        for pending in pendingTaps where now - pending.madeAt <= limits.maxTapAge {
            tapLimiter.record(now: now)
            out.append(StampedInput(seq: takeSeq(), tick: tick, kind: .tap(pending.tap)))
        }
        pendingTaps.removeAll()
        return out
    }

    private mutating func takeSeq() -> UInt32 {
        defer { nextSeq &+= 1 }
        return nextSeq
    }
}
