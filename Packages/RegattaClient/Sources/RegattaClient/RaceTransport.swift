/// One end of a race connection, whatever carries it (#64, #18: framing that doesn't depend on the
/// transport). The app wraps its WebSocket in one (#68), the load client its socket (#67), and tests
/// use `FaultInjectingLink`. Each call carries exactly one encoded `Frame`.
///
/// Polled, not pushed: the client reads it from its own update loop, so everything it does happens at
/// a time the caller passes in and a test can replay exactly. An implementation over an asynchronous
/// socket buffers what arrives until `receive()`. Not required to be thread-safe: one owner drives it.
public protocol RaceTransport: AnyObject {
    /// Whether the connection is up. Frames sent while it's down are lost; reconnecting is the owner's
    /// job, with a new transport handed to `RaceClient.attach(_:)`.
    var isConnected: Bool { get }
    /// Sends one frame's bytes. Never blocks.
    func send(_ frame: [UInt8])
    /// The frames that have arrived since the last call, oldest first.
    func receive() -> [[UInt8]]
}
