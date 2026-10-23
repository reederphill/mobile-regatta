import NIOCore
import NIOWebSocket
import RaceHost
import Synchronization

/// A seat's WebSocket, as the host sees it (`SeatTransport`): each frame goes out as one binary message.
/// `send` never blocks the host: the write is queued on the channel's event loop, and NIO buffers it. A
/// client that stops reading can't make the server buffer without bound: past `maxPendingBytes` unsent,
/// the connection is closed, and its seat drops like any lost connection.
public final class WebSocketSeatTransport: SeatTransport {
    public static let maxPendingBytes = 256 * 1024
    /// Unsent bytes past which the connection closes: `maxPendingBytes` for a seat, more for the service endpoint,
    /// whose frames go up to the 32 MiB cap (#145).
    private let maxPending: Int

    private struct State {
        var pending = 0
        var closed = false
        var sentBytes = 0
        var sentMessages = 0
    }

    private let channel: any Channel
    private let state = Mutex(State())

    public init(channel: any Channel, maxPendingBytes: Int = WebSocketSeatTransport.maxPendingBytes) {
        self.channel = channel
        maxPending = maxPendingBytes
    }

    /// Payload bytes and messages sent so far.
    public var sent: (bytes: Int, messages: Int) { state.withLock { ($0.sentBytes, $0.sentMessages) } }
    public var isClosed: Bool { state.withLock { $0.closed } }

    public func send(_ frame: [UInt8]) {
        let overflow: Bool = state.withLock { state in
            guard !state.closed else { return false }
            if state.pending + frame.count > maxPending { return true }
            state.pending += frame.count
            state.sentBytes += frame.count
            state.sentMessages += 1
            return false
        }
        if overflow {
            close(code: .unexpectedServerError, reason: "too far behind")
            return
        }
        guard !isClosed else { return }
        let count = frame.count
        let message = WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(bytes: frame))
        channel.writeAndFlush(message).whenComplete { _ in
            self.state.withLock { $0.pending -= count }
        }
    }

    /// A WebSocket ping carrying `stamp` (#157: the server's round-trip measure), unless the connection is closing.
    func ping(_ stamp: UInt64) {
        guard !state.withLock({ $0.closed }) else { return }
        var data = channel.allocator.buffer(capacity: 8)
        data.writeInteger(stamp)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, data: data), promise: nil)
    }

    /// The host disconnected the seat.
    public func close() { close(code: .normalClosure, reason: nil) }

    /// How long a connection the server has closed waits for the peer's own close before it is dropped.
    public static let closeGrace = TimeAmount.seconds(2)

    /// Sends a WebSocket close after whatever is queued, then shuts the sending side (a FIN after the last frame) and
    /// drops the connection once the peer has closed too, or after `closeGrace`. Once only.
    ///
    /// Not a full close at once: a socket closed with the peer's frames still unread sends a reset, and the reset can
    /// throw away what the peer hadn't read yet. A race's close was lost that way (CI run 39870999248): the app's
    /// inputs were in flight as the race closed, its `RaceClosed` never arrived, and it went Home with no results. The
    /// connection's reader (`serveRace`, `serveService`) drains what still comes in until the peer's close.
    public func close(code: WebSocketErrorCode, reason: String?) {
        let first = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        guard first else { return }
        var data = channel.allocator.buffer(capacity: 2 + (reason?.utf8.count ?? 0))
        data.write(webSocketErrorCode: code)
        if let reason { data.writeString(reason) }
        let channel = channel
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)).whenComplete { _ in
            let shutDown = channel.eventLoop.makePromise(of: Void.self)
            // A channel that can't half-close (or is already closed) closes in full, as before.
            shutDown.futureResult.whenFailure { _ in channel.close(promise: nil) }
            channel.close(mode: .output, promise: shutDown)
            channel.eventLoop.scheduleTask(in: Self.closeGrace) { channel.close(promise: nil) }
        }
    }
}
