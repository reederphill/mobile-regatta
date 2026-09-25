/// The host's clock: monotonic microseconds. Injected, so a test drives the host on a virtual clock
/// without sleeping, and the host does everything at a time the caller controls.
public protocol HostClock: Sendable {
    /// Monotonic time in microseconds. Never goes backwards.
    func now() -> UInt64
}

/// The real clock: microseconds since the clock was made, from `ContinuousClock`.
public struct SystemClock: HostClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> UInt64 {
        let elapsed = ContinuousClock.now - origin
        let (seconds, attoseconds) = elapsed.components
        return UInt64(max(0, seconds)) * 1_000_000 + UInt64(max(0, attoseconds)) / 1_000_000_000_000
    }
}

/// One seat's connection, seen from the host: the host pushes each encoded `Frame` into it. What the seat
/// sends comes the other way, through `RaceHost.receive(_:from:)`. The socket behind it (#66) buffers and
/// never blocks the host.
public protocol SeatTransport: AnyObject, Sendable {
    /// Sends one frame's bytes. Never blocks.
    func send(_ frame: [UInt8])
    /// Closes the connection: the host disconnected the seat (#26: a client that keeps hitting the caps).
    func close()
}
