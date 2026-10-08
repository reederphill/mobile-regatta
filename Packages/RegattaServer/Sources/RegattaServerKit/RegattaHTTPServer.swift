import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RegattaDevAPI

/// The server's one port (ADR 0006): HTTP/1.1 for `/health` and the dev routes, upgraded to a WebSocket at
/// `/race` for races and at `/service` for the service messages (#145). SwiftNIO's typed upgrade pipeline and async
/// channels; one task per connection.
public final class RegattaHTTPServer: Sendable {
    private enum Connection {
        case race(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case service(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    /// The largest WebSocket message a client may send: a client sends nothing near this (#18).
    static let maxClientMessage = 1 << 14

    public let config: ServerConfig
    public let registry: RaceRegistry
    public let services: ServiceEndpoint
    /// The port it listens on (the one it was given, or the free one it picked for port 0).
    public let port: Int
    private let listener: NIOAsyncChannel<EventLoopFuture<Connection>, Never>
    private let handler: RequestHandler
    /// The accept loop; ends with the listener's error, or nil if the listener closed.
    private let task: Task<(any Error)?, Never>

    /// Binds and starts serving. Refuses to start outside `ENV=dev` (dev auth is all there is). `services` is the
    /// service endpoint; by default the config's, with its accounts in memory (a dev server without a database).
    public static func start(config: ServerConfig, services: ServiceEndpoint? = nil,
                             group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> RegattaHTTPServer {
        _ = try SeatAuthPolicy.for(config.environment)
        let services = try services ?? ServiceEndpoint.make(config: config, store: InMemoryAccountStore())
        let frameCap = services.config.frameCap
        let registry = RaceRegistry(maxRaces: config.maxRaces)
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // A TCP-level option. (`.socketOption(.tcp_nodelay)` is SOL_SOCKET option 1: SO_DEBUG on Linux,
            // which needs CAP_NET_ADMIN, so every accepted connection failed in the container (#67).)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .bind(host: config.host, port: config.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configure(channel, frameCap: frameCap)
                }
            }
        do {
            try await listener.channel.eventLoop.submit {
                let pipeline = listener.channel.pipeline.syncOperations
                let accept = try pipeline.context(name: "AcceptHandler")
                try pipeline.addHandler(ConnectionSetupErrorHandler(), position: .after(accept.handler))
            }.get()
        } catch {
            try? await listener.channel.close()
            throw error
        }
        return RegattaHTTPServer(config: config, registry: registry, services: services, listener: listener)
    }

    private init(config: ServerConfig, registry: RaceRegistry, services: ServiceEndpoint,
                 listener: NIOAsyncChannel<EventLoopFuture<Connection>, Never>) {
        self.config = config
        self.registry = registry
        self.services = services
        self.listener = listener
        port = listener.channel.localAddress?.port ?? config.port
        let handler = RequestHandler(config: config, registry: registry, services: services)
        self.handler = handler
        task = Task {
            await withDiscardingTaskGroup { group in
                defer { group.cancelAll() }
                do {
                    try await listener.executeThenClose { inbound in
                        for try await connection in inbound {
                            group.addTask { await Self.serve(connection, handler: handler) }
                        }
                    }
                    return nil
                } catch {
                    return error
                }
            }
        }
    }

    /// The listening channel, for tests.
    var listenerChannel: any Channel { listener.channel }

    /// Runs until the listener stops, and throws its error if it failed. Only `shutdown()` stops it on purpose;
    /// no single connection can.
    public func wait() async throws {
        if let error = await task.value { throw error }
    }

    /// Stops listening, closes every race where it stands and every connection.
    public func shutdown() async {
        listener.channel.close(promise: nil)
        await registry.closeAll()
        task.cancel()
        _ = await task.value
    }

    private static func configure(_ channel: any Channel, frameCap: Int) throws -> EventLoopFuture<Connection> {
        // One WebSocket upgrader per path, so each path's decoder has its own frame limit: a race frame over
        // `maxClientMessage` is refused at its header, before its payload is buffered; a service frame may run to the
        // service's cap.
        let shouldUpgrade: @Sendable (any Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> = { channel, head in
            let path = RequestHandler.split(head.uri).path
            let upgrades = path == ServerPath.race || path == ServerPath.service
            return channel.eventLoop.makeSucceededFuture(upgrades ? HTTPHeaders() : nil)
        }
        let race = NIOTypedWebSocketServerUpgrader<Connection>(
            maxFrameSize: maxClientMessage, shouldUpgrade: shouldUpgrade,
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 64,
                                                    maxAccumulatedFrameSize: maxClientMessage))
                    return Connection.race(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                }
            }
        )
        let service = NIOTypedWebSocketServerUpgrader<Connection>(
            maxFrameSize: max(maxClientMessage, frameCap), shouldUpgrade: shouldUpgrade,
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 4096,
                                                    maxAccumulatedFrameSize: frameCap))
                    return Connection.service(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                }
            }
        )
        let upgrader = PathWebSocketUpgrader(race: race, service: service)
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
            case .service(let channel): try await serveService(channel, handler: handler)
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

    /// A service connection (#145): each binary message through `ServiceConnectionHandler`, in order, until either
    /// side closes. A connection that doesn't send `Hello` in time is closed, as on `/race`.
    private static func serveService(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, handler: RequestHandler) async throws {
        guard let services = handler.services else { return }
        let transport = WebSocketSeatTransport(channel: channel.channel, maxPendingBytes: 2 * services.config.frameCap)
        let connection = ServiceConnectionHandler(endpoint: services, sink: ServiceSink(transport: transport))
        let timeout = handler.config.handshakeTimeout
        let handshakeDeadline = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            transport.close(code: .policyViolation, reason: "no Hello in time")
        }
        defer { handshakeDeadline.cancel() }
        do {
            try await channel.executeThenClose { inbound, outbound in
                for try await frame in inbound {
                    switch frame.opcode {
                    case .binary:
                        await connection.receive(Array(buffer: frame.unmaskedData))
                        handshakeDeadline.cancel()
                        if await connection.isClosed { return }
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

/// On the listener, after NIO's accept handler: a connection that fails to set up (a socket option, its
/// pipeline) fires its error down the listener's pipeline, and the async listener would end on it, taking
/// the server with it. That connection is already closed; log it and keep accepting.
private final class ConnectionSetupErrorHandler: ChannelInboundHandler {
    typealias InboundIn = any Channel

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        FileHandle.standardError.write(Data("RegattaServer: a connection failed to set up: \(error)\n".utf8))
    }
}

/// The service connection's frames onto its WebSocket.
private struct ServiceSink: ServiceFrameSink {
    let transport: WebSocketSeatTransport

    func send(_ frame: [UInt8]) { transport.send(frame) }
    func close(reason: String) { transport.close(code: .policyViolation, reason: String(reason.prefix(120))) }
}

/// The WebSocket upgrade, by path: `/service` to its own upgrader (its decoder takes frames up to the service cap),
/// everything else to the race one (16 KiB).
private struct PathWebSocketUpgrader<UpgradeResult: Sendable>: NIOTypedHTTPServerProtocolUpgrader {
    let race: NIOTypedWebSocketServerUpgrader<UpgradeResult>
    let service: NIOTypedWebSocketServerUpgrader<UpgradeResult>

    var supportedProtocol: String { race.supportedProtocol }
    var requiredUpgradeHeaders: [String] { race.requiredUpgradeHeaders }

    private func upgrader(for head: HTTPRequestHead) -> NIOTypedWebSocketServerUpgrader<UpgradeResult> {
        RequestHandler.split(head.uri).path == ServerPath.service ? service : race
    }

    func buildUpgradeResponse(channel: any Channel, upgradeRequest: HTTPRequestHead,
                              initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        upgrader(for: upgradeRequest).buildUpgradeResponse(channel: channel, upgradeRequest: upgradeRequest,
                                                           initialResponseHeaders: initialResponseHeaders)
    }

    func upgrade(channel: any Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<UpgradeResult> {
        upgrader(for: upgradeRequest).upgrade(channel: channel, upgradeRequest: upgradeRequest)
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
