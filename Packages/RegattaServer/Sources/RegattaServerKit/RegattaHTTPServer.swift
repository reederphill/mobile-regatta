import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RegattaDevAPI

/// The server's one port (ADR 0006): HTTP/1.1 for `/health` and the dev routes, upgraded to a WebSocket at
/// `/race` for races. SwiftNIO's typed upgrade pipeline and async channels; one task per connection.
public final class RegattaHTTPServer: Sendable {
    private enum Connection {
        case race(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    /// The largest WebSocket message a client may send: a client sends nothing near this (#18).
    static let maxClientMessage = 1 << 14

    public let config: ServerConfig
    public let registry: RaceRegistry
    /// The port it listens on (the one it was given, or the free one it picked for port 0).
    public let port: Int
    private let listener: NIOAsyncChannel<EventLoopFuture<Connection>, Never>
    private let handler: RequestHandler
    private let task: Task<Void, Never>

    /// Binds and starts serving. Refuses to start outside `ENV=dev` (dev auth is all there is).
    public static func start(config: ServerConfig, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> RegattaHTTPServer {
        _ = try SeatAuthPolicy.for(config.environment)
        let registry = RaceRegistry(maxRaces: config.maxRaces)
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .bind(host: config.host, port: config.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configure(channel)
                }
            }
        return RegattaHTTPServer(config: config, registry: registry, listener: listener)
    }

    private init(config: ServerConfig, registry: RaceRegistry, listener: NIOAsyncChannel<EventLoopFuture<Connection>, Never>) {
        self.config = config
        self.registry = registry
        self.listener = listener
        port = listener.channel.localAddress?.port ?? config.port
        let handler = RequestHandler(config: config, registry: registry)
        self.handler = handler
        task = Task {
            await withDiscardingTaskGroup { group in
                try? await listener.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask { await Self.serve(connection, handler: handler) }
                    }
                }
                group.cancelAll()
            }
        }
    }

    /// Runs until the listener closes.
    public func wait() async { await task.value }

    /// Stops listening, closes every race where it stands and every connection.
    public func shutdown() async {
        listener.channel.close(promise: nil)
        await registry.closeAll()
        task.cancel()
        await task.value
    }

    private static func configure(_ channel: any Channel) throws -> EventLoopFuture<Connection> {
        let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
            maxFrameSize: maxClientMessage,
            shouldUpgrade: { channel, head in
                let path = RequestHandler.split(head.uri).path
                return channel.eventLoop.makeSucceededFuture(path == ServerPath.race ? HTTPHeaders() : nil)
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 64,
                                                    maxAccumulatedFrameSize: maxClientMessage))
                    return Connection.race(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                }
            }
        )
        let configuration = NIOTypedHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(HTTPResponsePartHandler())
                    return Connection.http(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                }
            }
        )
        return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
            configuration: .init(upgradeConfiguration: configuration))
    }

    private static func serve(_ connection: EventLoopFuture<Connection>, handler: RequestHandler) async {
        do {
            switch try await connection.get() {
            case .race(let channel): try await serveRace(channel, handler: handler)
            case .http(let channel): try await serveHTTP(channel, handler: handler)
            }
        } catch {
            // One connection's failure is that connection's: the server carries on.
        }
    }

    /// A race connection: each binary message through `SeatConnection`, in order, until either side closes.
    private static func serveRace(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, handler: RequestHandler) async throws {
        let transport = WebSocketSeatTransport(channel: channel.channel)
        var connection = SeatConnection(config: handler.config, registry: handler.registry, transport: transport)
        // A connection that never sends Hello and JoinRace mustn't hold its socket and task for ever.
        let timeout = handler.config.handshakeTimeout
        let handshakeDeadline = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            transport.close(code: .policyViolation, reason: "no JoinRace in time")
        }
        defer { handshakeDeadline.cancel() }
        do {
            try await channel.executeThenClose { inbound, outbound in
                for try await frame in inbound {
                    switch frame.opcode {
                    case .binary:
                        await connection.receive(Array(buffer: frame.unmaskedData))
                        if connection.isSeated { handshakeDeadline.cancel() }
                        if connection.isClosed { return }
                    case .ping:
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                    case .connectionClose:
                        transport.close(code: .normalClosure, reason: nil)
                        return
                    default:
                        break
                    }
                }
            }
        } catch {
            await connection.ended()
            throw error
        }
        await connection.ended()
    }

    /// A plain HTTP connection: one request, one JSON answer, then close.
    private static func serveHTTP(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>,
                                  handler: RequestHandler) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            for try await part in inbound {
                switch part {
                case .head(let requestHead): head = requestHead
                case .body: break
                case .end:
                    guard let head else { return }
                    let reply = await handler.respond(method: head.method, uri: head.uri)
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "application/json")
                    headers.add(name: "Content-Length", value: String(reply.body.count))
                    headers.add(name: "Connection", value: "close")
                    try await outbound.write(contentsOf: [
                        .head(HTTPResponseHead(version: .http1_1, status: reply.status, headers: headers)),
                        .body(ByteBuffer(bytes: head.method == .HEAD ? [] : reply.body)),
                        .end(nil),
                    ])
                    return
                }
            }
        }
    }
}

/// Lets the HTTP async channel write `ByteBuffer` bodies.
private final class HTTPResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer): context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
