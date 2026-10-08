import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import RegattaDevAPI
import RegattaProtocol
import RegattaServiceClient
import Synchronization

/// A service connection over a NIO WebSocket (`/service`, #145), as `ServiceConnection` reads it (`ServiceLink`).
/// The connection's opening (the version handshake, and the session call) is read frame by frame through
/// `nextOpeningFrame()`; `handOver()` then sends every later frame to `incoming`.
public final class WebSocketServiceLink: ServiceLink, @unchecked Sendable {
    // @unchecked: the mutable state is behind `state`; the rest are Sendable lets set in init.
    private struct State {
        var handedOver = false
        var closed = false
    }

    public let incoming: AsyncStream<[UInt8]>
    private let incomingContinuation: AsyncStream<[UInt8]>.Continuation
    private let opening: AsyncStream<[UInt8]>
    private let openingContinuation: AsyncStream<[UInt8]>.Continuation
    private var openingIterator: AsyncStream<[UInt8]>.Iterator
    private let channel: any Channel
    private let state = Mutex(State())

    /// Opens `ws://host:port/service`.
    public static func connect(host: String, port: Int, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> WebSocketServiceLink {
        let channel = try await WebSocketClient.connect(host: host, port: port, path: ServerPath.service, maxMessage: serviceFrameLimit,
                                                        counter: ByteCounter(), group: group)
        let link = WebSocketServiceLink(channel: channel.channel)
        link.startReading(channel)
        return link
    }

    private init(channel: any Channel) {
        self.channel = channel
        (incoming, incomingContinuation) = AsyncStream<[UInt8]>.makeStream()
        (opening, openingContinuation) = AsyncStream<[UInt8]>.makeStream()
        openingIterator = opening.makeAsyncIterator()
    }

    private func startReading(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        Task { [self] in
            try? await channel.executeThenClose { inbound, outbound in
                for try await frame in inbound {
                    switch frame.opcode {
                    case .binary:
                        let bytes = Array(buffer: frame.unmaskedData)
                        if state.withLock({ $0.handedOver }) { incomingContinuation.yield(bytes) } else { openingContinuation.yield(bytes) }
                    case .ping:
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData))
                    case .connectionClose:
                        return
                    default:
                        break
                    }
                }
            }
            state.withLock { $0.closed = true }
            openingContinuation.finish()
            incomingContinuation.finish()
        }
    }

    /// The next frame of the connection's opening, before `handOver()`; nil once the connection has closed.
    public func nextOpeningFrame() async -> [UInt8]? { await openingIterator.next() }

    /// From now on every frame goes to `incoming`.
    public func handOver() {
        state.withLock { $0.handedOver = true }
        openingContinuation.finish()
    }

    public func send(_ frame: [UInt8]) {
        guard !state.withLock({ $0.closed }) else { return }
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: channel.allocator.buffer(bytes: frame)),
                              promise: nil)
    }

    public func close() {
        let first = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        guard first else { return }
        var data = channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .normalClosure)
        let channel = channel
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: data)).whenComplete { _ in
            channel.close(promise: nil)
        }
        incomingContinuation.finish()
    }
}

public enum ServiceEndpointError: Error, Equatable, Sendable, CustomStringConvertible {
    case badEndpoint(String)
    case handshake(String)
    case session(String)

    public var description: String {
        switch self {
        case .badEndpoint(let endpoint): "not a ws://host:port endpoint: \(endpoint)"
        case .handshake(let what): "handshake: \(what)"
        case .session(let what): "session: \(what)"
        }
    }
}

/// The contract runner's way into a dev server (#143's `ServiceEndpointConnector`, #145): a fresh test account per
/// situation, put in it by `POST /dev/situation`, then a service connection past the version handshake, signed in with
/// a dev identity signature (the dev server's verifier takes any fresh, well-formed one) when the situation has a player.
public struct WebSocketServiceConnector: ServiceEndpointConnector {
    let group: any EventLoopGroup

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) { self.group = group }

    /// `ws://host:port`, `http://host:port` or `host:port`.
    public static func hostAndPort(_ endpoint: String) throws -> (host: String, port: Int) {
        var rest = Substring(endpoint)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        guard let colon = rest.lastIndex(of: ":"), let port = Int(rest[rest.index(after: colon)...]), !rest[..<colon].isEmpty else {
            throw ServiceEndpointError.badEndpoint(endpoint)
        }
        return (String(rest[..<colon]), port)
    }

    public func connect(to endpoint: String, service: String, situation: String) async throws -> any ServiceLink {
        let (host, port) = try Self.hostAndPort(endpoint)
        let id = UUID().uuidString.lowercased()
        let request = DevSituationRequest(service: service, situation: situation, teamPlayerID: "T:contract-\(id)",
                                          gamePlayerID: "G:contract-\(id)")
        let (status, body) = try await DevClient.request(.POST, "\(ServerPath.devSituation)?\(request.query)", host: host, port: port, group: group)
        guard status == 200 else { throw LoadClientError.http(status: status, body: String(decoding: body, as: UTF8.self)) }
        let arranged = try JSONDecoder().decode(DevSituationResponse.self, from: Data(body))

        let link = try await WebSocketServiceLink.connect(host: host, port: port, group: group)
        do {
            link.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "contract-runner", files: []))).encoded())
            guard let ack = await link.nextOpeningFrame(), case .helloAck = try Frame(decoding: ack).message else {
                throw ServiceEndpointError.handshake("no HelloAck")
            }
            if arranged.signIn {
                let player = WirePlayer(gamePlayerID: request.gamePlayerID, alias: "Contract", isUnderage: arranged.isUnderage,
                                        isPersonalizedCommunicationRestricted: arranged.isPersonalizedCommunicationRestricted,
                                        isMultiplayerGamingRestricted: arranged.isMultiplayerGamingRestricted)
                let signature = WireIdentitySignature(
                    gamePlayerID: request.gamePlayerID, teamPlayerID: request.teamPlayerID, publicKeyURL: "https://dev.invalid/gc-dev.cer",
                    signature: Array(id.utf8), salt: [1, 2, 3, 4], timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
                // Request id 0: the `ServiceConnection` that takes the link over numbers its requests from 1.
                link.send(try Frame(seq: 2, tick: 0, message: .sessionRequest(ServiceRequest(id: 0, call: .signIn(signature: signature, player: player))))
                    .encoded())
                guard let reply = await link.nextOpeningFrame(), case .sessionReply(let answer) = try Frame(decoding: reply).message,
                      case .signedIn = answer.result
                else { throw ServiceEndpointError.session("the dev sign-in was refused") }
            }
            link.handOver()
            return link
        } catch {
            link.close()
            throw error
        }
    }
}
