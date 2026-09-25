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

    private struct State {
        var pending = 0
        var closed = false
        var sentBytes = 0
        var sentMessages = 0
    }

    private let channel: any Channel
    private let state = Mutex(State())

    public init(channel: any Channel) { self.channel = channel }

    /// Payload bytes and messages sent so far.
    public var sent: (bytes: Int, messages: Int) { state.withLock { ($0.sentBytes, $0.sentMessages) } }
    public var isClosed: Bool { state.withLock { $0.closed } }

    public func send(_ frame: [UInt8]) {
        let overflow: Bool = state.withLock { state in
            guard !state.closed else { return false }
            if state.pending + frame.count > Self.maxPendingBytes { return true }
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

    /// The host disconnected the seat.
    public func close() { close(code: .normalClosure, reason: nil) }

    /// Sends a WebSocket close after whatever is queued, then closes the connection. Once only.
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
            channel.close(promise: nil)
        }
    }
}
