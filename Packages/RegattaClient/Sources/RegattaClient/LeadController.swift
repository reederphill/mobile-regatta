/// How far the client runs ahead of the server (#18, ADR 0005), so its inputs reach the server before
/// the tick they're stamped for.
///
/// **Lead** is ticks ahead of the estimated server tick (`ClockSync.serverTick(at:)`): the client
/// simulates, and stamps its inputs for, `⌊estimated server tick + lead⌋ + 1`. Its target is
///
///     lead = (one-way latency + jitter buffer) / tick + 1 + feedback
///
/// - one-way latency + jitter buffer: the mean uplink delay over the clock-sync window plus two
///   standard deviations of it (`ClockSync.uplinkDelays`). For a uniform jitter of 0…j on a fixed
///   delay d, that's d + 1.08 j: just past the slowest ping.
/// - 1 tick: an input stamped for tick n must arrive before the server steps n, and the client's
///   own tick is a whole number while the server's clock runs between ticks.
/// - feedback: the server's early/late margin (`InputAck.margin`). A late input raises it by the
///   ticks it was late, at most once per `lateHoldoff` (the inputs already in flight were stamped with
///   the old lead); it decays at `decayPerSecond` once no input has been late for `decayAfter`. It
///   corrects what the clock sync can't see, such as an uplink slower than the downlink.
///
/// The lead rises at once (a late input costs a tick of the player's steering) and falls at
/// `fallPerSecond` (running too far ahead only costs responsiveness), and never leaves 0…`maxLead`.
///
/// Early margins steer it only through the target, never directly. The clock sync already measures
/// the uplink every ping, so when the link gets faster the target drops and the lead follows it down
/// within a few seconds. An early margin, on the other hand, is mostly the jitter buffer doing its job:
/// lowering the lead on it would give away the buffer the next slow frame needs, and a late input costs
/// the player more than a tick of extra lead. So the server's early/late feedback steers the lead up
/// (late) directly and down (early) only as the late correction decays and the measured target falls.
public struct LeadController: Sendable {
    /// The server rejects inputs stamped more than 30 ticks (1 s) ahead (#18, #65). The lead plus the
    /// downlink delay must also stay below the wind-key reveal lead (30 ticks, #95), or the client
    /// reaches a window before its key arrives and stops to wait for it (it never guesses the wind).
    /// Since the lead follows the uplink, that holds while the round trip plus jitter is under about a
    /// second; past that the client waits at each window boundary, and the lead is at this cap anyway.
    /// So never raise this above the reveal lead.
    public static let maxLead = 30.0

    public var lateHoldoff: UInt64 = 250_000
    public var decayAfter: UInt64 = 2_000_000
    public var decayPerSecond = 0.5
    public var fallPerSecond = 8.0
    /// The feedback term's bounds, ticks.
    public var maxFeedback = 10.0

    /// Ticks ahead of the estimated server tick; 0 until the first update.
    public private(set) var lead = 0.0
    /// What the lead is heading for.
    public private(set) var target = 0.0
    /// The feedback term, ticks.
    public private(set) var feedback = 0.0
    /// Inputs the server reported late.
    public private(set) var lateInputs = 0

    private var lastLateAt: UInt64?
    private var lastRaiseAt: UInt64?
    private var lastUpdate: UInt64?

    public init() {}

    /// Takes the server's margin for the client's latest input, received at `now`.
    public mutating func feedback(margin: Int, now: UInt64) {
        guard margin < 0 else { return }
        lateInputs += 1
        lastLateAt = now
        if let raised = lastRaiseAt, now - raised < lateHoldoff { return }
        lastRaiseAt = now
        feedback = min(feedback + Double(-margin), maxFeedback)
    }

    /// Moves the lead toward its target at `now`, given the uplink delays in microseconds.
    public mutating func update(uplinkDelays delays: [Double], now: UInt64) {
        let elapsed = lastUpdate.map { Double(now - $0) / 1_000_000 } ?? 0
        lastUpdate = now
        if let late = lastLateAt, now - late >= decayAfter {
            feedback = max(0, feedback - decayPerSecond * elapsed)
        }
        guard !delays.isEmpty else { return }
        let mean = delays.reduce(0, +) / Double(delays.count)
        let variance = delays.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(delays.count)
        let buffered = max(0, mean + 2 * variance.squareRoot())
        target = min(buffered / ClockSync.tickMicros + 1 + feedback, Self.maxLead)
        if target >= lead {
            lead = target
        } else {
            lead = max(target, lead - fallPerSecond * elapsed)
        }
        lead = min(max(lead, 0), Self.maxLead)
    }
}
