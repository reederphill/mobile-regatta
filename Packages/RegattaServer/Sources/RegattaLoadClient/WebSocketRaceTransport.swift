import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RegattaClient
import RegattaDevAPI
import RegattaProtocol
import Synchronization

/// Bytes on the wire, both ways, as TCP carries them: HTTP upgrade, WebSocket headers and all.
public struct WireBytes: Hashable, Sendable {
    public var received = 0
    public var sent = 0

    public init() {}
}

/// Counts every byte at the bottom of a connection's pipeline, before any decoding.
final class ByteCounter: Sendable {
    private let bytes = Mutex(WireBytes())

    var total: WireBytes { bytes.withLock { $0 } }
    func received(_ count: Int) { bytes.withLock { $0.received += count } }
    func sent(_ count: Int) { bytes.withLock { $0.sent += count } }
}

private final class ByteCountingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData

    private let counter: ByteCounter

    init(_ counter: ByteCounter) { self.counter = counter }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        counter.received(unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        counter.sent(unwrapOutboundIn(data).readableBytes)
        context.write(data, promise: promise)
    }
}

public enum LoadClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case upgradeRefused
    case http(status: Int, body: String)
    case handshake(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .upgradeRefused: "the server refused the WebSocket upgrade"
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .handshake(let what): "handshake: \(what)"
        case .timedOut(let what): "timed out \(what)"
        }
    }
}

/// A race connection over a NIO WebSocket, as `RaceClient` polls it (`RaceTransport`). A reader task
/// buffers each binary message as it arrives; `receive()` hands over what has come. Sends are queued on
/// the channel's event loop and never block. Client frames are masked (RFC 6455).
public final class WebSocketRaceTransport: RaceTransport, @unchecked Sendable {
    // @unchecked: every mutable field is behind `state`; the rest are Sendable lets.
    private struct State {
        var inbox: [[UInt8]] = []
        var connected = true
        var closeCode: WebSocketErrorCode?
        var closeReason: String?
        /// Round trips of the clock pings, from each pong's arrival: the network's, without the wait for the
        /// client's next update that `ClockSync` sees.
        var pongRoundTrips: [UInt64] = []
    }

    private let channel: any Channel
    private let counter: ByteCounter
    private let state = Mutex(State())
    private var reader: Task<Void, Never>?
    /// The clock `RaceClient` is updated with, in microseconds: pongs echo its time.
    private let clock: @Sendable () -> UInt64

    /// The largest message the server may send: a `Resync` of a full fleet with its wind keys is a few KB.
    static let maxServerMessage = 1 << 20

    /// Opens `ws://host:port/race`.
    public static func connect(host: String, port: Int, clock: @escaping @Sendable () -> UInt64,
                               group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> WebSocketRaceTransport {
        enum Upgrade: Sendable {
            case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
            case refused
        }
        let counter = ByteCounter()
        let upgrade: EventLoopFuture<Upgrade> = try await ClientBootstrap(group: group)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteCountingHandler(counter))
                    let upgrader = NIOTypedWebSocketClientUpgrader<Upgrade>(
                        maxFrameSize: maxServerMessage,
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(
                                    NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 256,
                                                                maxAccumulatedFrameSize: maxServerMessage))
                                return Upgrade.websocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    var headers = HTTPHeaders()
                    headers.add(name: "Host", value: "\(host):\(port)")
                    headers.add(name: "Content-Length", value: "0")
                    let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                        upgradeRequestHead: HTTPRequestHead(version: .http1_1, method: .GET, uri: ServerPath.race, headers: headers),
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in channel.eventLoop.makeSucceededFuture(Upgrade.refused) }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                }
            }
        switch try await upgrade.get() {
        case .websocket(let channel):
            let transport = WebSocketRaceTransport(channel: channel.channel, counter: counter, clock: clock)
            transport.startReading(channel)
            return transport
        case .refused:
            throw LoadClientError.upgradeRefused
        }
    }

    private init(channel: any Channel, counter: ByteCounter, clock: @escaping @Sendable () -> UInt64) {
        self.channel = channel
        self.counter = counter
        self.clock = clock
    }

    private func startReading(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        reader = Task { [self] in
            try? await channel.executeThenClose { inbound, outbound in
                for try await frame in inbound {
                    switch frame.opcode {
                    case .binary:
                        let bytes = Array(buffer: frame.unmaskedData)
                        let arrived = clock()
                        let roundTrip: UInt64? = if bytes.first == MessageType.pong.rawValue,
                            case .pong(let pong)? = (try? Frame(decoding: bytes))?.message, arrived >= pong.clientTime {
                            arrived - pong.clientTime
                        } else {
                            nil
                        }
                        state.withLock {
                            $0.inbox.append(bytes)
                            if let roundTrip { $0.pongRoundTrips.append(roundTrip) }
                        }
                    case .ping:
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData))
                    case .connectionClose:
                        var data = frame.unmaskedData
                        let code = data.readWebSocketErrorCode()
                        let reason = data.readString(length: data.readableBytes)
                        state.withLock {
                            $0.closeCode = code
                            $0.closeReason = reason
                        }
                        return
                    default:
                        break
                    }
                }
            }
            state.withLock { $0.connected = false }
        }
    }

    /// Every clock ping's round trip so far, µs, measured at the pong's arrival.
    public var pongRoundTrips: [UInt64] { state.withLock { $0.pongRoundTrips } }

    /// Bytes on the wire so far, the upgrade included.
    public var wireBytes: WireBytes { counter.total }
    /// Why the server closed the connection, if it did.
    public var closeReason: (code: WebSocketErrorCode?, reason: String?) { state.withLock { ($0.closeCode, $0.closeReason) } }

    // MARK: RaceTransport

    /// Up until the connection has closed and everything that came before the close has been read, so the
    /// `RaceClosed` just ahead of the server's close still reaches the client.
    public var isConnected: Bool { state.withLock { $0.connected || !$0.inbox.isEmpty } }

    public func send(_ frame: [UInt8]) {
        guard state.withLock({ $0.connected }) else { return }
        let message = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: channel.allocator.buffer(bytes: frame))
        channel.writeAndFlush(message, promise: nil)
    }

    public func receive() -> [[UInt8]] {
        state.withLock { state in
            defer { state.inbox.removeAll() }
            return state.inbox
        }
    }

    /// Puts frames back at the front of the inbox, for the owner that read past the handshake.
    func unreceive(_ frames: [[UInt8]]) {
        guard !frames.isEmpty else { return }
        state.withLock { $0.inbox.insert(contentsOf: frames, at: 0) }
    }

    /// Says goodbye and closes; waits for the reader to finish.
    public func close() async {
        if state.withLock({ $0.connected }) {
            var data = channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .normalClosure)
            let channel = channel
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: data)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        await reader?.value
        state.withLock { $0.connected = false }
    }
}
