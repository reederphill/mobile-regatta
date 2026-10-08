import Foundation
import NIOCore
import NIOPosix
import RegattaDevAPI
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// Each WebSocket path's decoder has its own frame limit (#145): a race frame over 16 KiB is refused at its header,
/// before its payload is buffered (close 1009, message too big). On `/service` the limit is 16 KiB until the
/// connection is signed in, also at the header, and the service's cap after. Raw bytes over a plain TCP socket, so the
/// test controls exactly what the server has seen.
@Suite(.serialized)
struct FrameLimitTests {
    private func withServer(_ body: (RegattaHTTPServer) async throws -> Void) async throws {
        let server = try await RegattaHTTPServer.start(config: .dev(host: "127.0.0.1", port: 0))
        do {
            try await body(server)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func aRaceFrameOverTheLimitIsRefusedAtItsHeader() async throws {
        try await withServer { server in
            let socket = try await RawSocket.upgrade(port: server.port, path: ServerPath.race)
            // The header alone, claiming a 1 MiB payload that never comes.
            try await socket.send(Self.binaryFrameHeader(length: 1 << 20))
            #expect(try await socket.closeCode() == 1009)
        }
    }

    /// Before Hello, and after it but before a session: a header claiming 1 MiB closes the connection at the header.
    @Test(arguments: [false, true])
    func aServiceFrameOverThePreSignInLimitIsRefusedAtItsHeader(afterHello: Bool) async throws {
        try await withServer { server in
            let socket = try await RawSocket.upgrade(port: server.port, path: ServerPath.service)
            if afterHello {
                try await socket.send(Self.binaryFrame(Self.hello()))
                #expect(try await socket.binaryFrames(1).count == 1)
            }
            try await socket.send(Self.binaryFrameHeader(length: 1 << 20))
            #expect(try await socket.closeCode() == 1009)
        }
    }

    /// The same bytes split into fragments are the same message: refused once the fragments pass the limit.
    @Test func aFragmentedServiceMessageOverThePreSignInLimitIsRefused() async throws {
        try await withServer { server in
            let socket = try await RawSocket.upgrade(port: server.port, path: ServerPath.service)
            let fragment = [UInt8](repeating: 0, count: 10_000)
            try await socket.send(Self.frame(opcode: 0x2, fin: false, fragment) + Self.frame(opcode: 0x0, fin: false, fragment))
            #expect(try await socket.closeCode() == 1009)
        }
    }

    @Test func aServiceFrameOverThePreSignInLimitReachesTheServiceOnceSignedIn() async throws {
        try await withServer { server in
            let length = 1 << 20
            #expect(length > server.services.config.preSignInFrameCap && length <= server.services.config.frameCap)
            let socket = try await RawSocket.upgrade(port: server.port, path: ServerPath.service)
            try await socket.send(Self.binaryFrame(Self.hello()))
            let signature = IdentitySignature(gamePlayerID: GamePlayerID("G:big"), teamPlayerID: "T:big",
                                              publicKeyURL: "https://static.gc.apple.com/public-key/test.cer", signature: [9], salt: [3],
                                              timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
            let player = GameCenterPlayer(gamePlayerID: GamePlayerID("G:big"), alias: "big")
            let signIn = Message.sessionRequest(ServiceRequest(id: 1, call: .signIn(signature: signature.wire, player: player.wire)))
            try await socket.send(Self.binaryFrame(try Frame(seq: 2, tick: 0, message: signIn).encoded()))
            let replies = try await socket.binaryFrames(2)
            guard replies.count == 2, case .sessionReply(let reply)? = try? Frame(decoding: replies[1]).message,
                  case .signedIn = reply.result else {
                Issue.record("not signed in: \(replies.map { try? Frame(decoding: $0).message })")
                return
            }
            // A whole 1 MiB frame of zeros: the gate and the decoder take it, and the service closes on it as not a
            // service request (1008), not the transport as too big (1009).
            try await socket.send(Self.binaryFrameHeader(length: length) + [UInt8](repeating: 0, count: length))
            #expect(try await socket.closeCode() == 1008)
        }
    }

    static func hello() throws -> [UInt8] {
        try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded()
    }

    /// A client binary frame's header: FIN + binary, masked, 64-bit length, a zero mask (so the payload goes as is).
    static func binaryFrameHeader(length: Int) -> [UInt8] {
        [0x82, 0x80 | 127] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) } + [0, 0, 0, 0]
    }

    static func binaryFrame(_ payload: [UInt8]) -> [UInt8] { frame(opcode: 0x2, fin: true, payload) }

    /// A client frame, masked with a zero mask, with a 64-bit length.
    static func frame(opcode: UInt8, fin: Bool, _ payload: [UInt8]) -> [UInt8] {
        let first: UInt8 = (fin ? 0x80 : 0) | opcode
        let length = (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        return [first, 0x80 | 127] + length + [0, 0, 0, 0] + payload
    }
}

/// A TCP connection that sends a WebSocket upgrade and then raw bytes, and reads the server's frames.
private final class RawSocket: @unchecked Sendable {
    // @unchecked: one read at a time (each test awaits each read).
    private let channel: any Channel
    private var iterator: AsyncStream<[UInt8]>.AsyncIterator
    private var received: [UInt8] = []

    private init(channel: any Channel, bytes: AsyncStream<[UInt8]>) {
        self.channel = channel
        iterator = bytes.makeAsyncIterator()
    }

    static func upgrade(port: Int, path: String) async throws -> RawSocket {
        let (bytes, continuation) = AsyncStream<[UInt8]>.makeStream()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Collector(continuation)) }
            }
            .connect(host: "127.0.0.1", port: port).get()
        let socket = RawSocket(channel: channel, bytes: bytes)
        let request = "GET \(path) HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try await socket.send(Array(request.utf8))
        return socket
    }

    func send(_ bytes: [UInt8]) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    struct ServerFrame: Sendable {
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// The first `count` binary frames' payloads (fewer if the connection ends first).
    func binaryFrames(_ count: Int) async throws -> [[UInt8]] {
        let frames = try await read { $0.filter { $0.opcode == 0x2 }.count >= count }
        return frames.filter { $0.opcode == 0x2 }.prefix(count).map(\.payload)
    }

    /// The status code of the server's close frame, or nil if the connection ends without one.
    func closeCode() async throws -> Int? {
        defer { channel.close(promise: nil) }
        let frames = try await read { $0.contains { $0.opcode == 0x8 } }
        guard let close = frames.first(where: { $0.opcode == 0x8 }), close.payload.count >= 2 else { return nil }
        return Int(close.payload[0]) << 8 | Int(close.payload[1])
    }

    /// Reads until `done` holds for the frames so far, or the connection ends. Fails after 10 s.
    private func read(_ done: @escaping @Sendable ([ServerFrame]) -> Bool) async throws -> [ServerFrame] {
        try await withThrowingTaskGroup(of: [ServerFrame].self) { group in
            group.addTask {
                var frames = self.frames()
                while !done(frames) {
                    guard let chunk = await self.iterator.next() else { break }
                    self.received += chunk
                    frames = self.frames()
                }
                return frames
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    struct TimedOut: Error {}

    /// The complete server frames after the upgrade response (unmasked, as a server sends them).
    private func frames() -> [ServerFrame] {
        guard let end = received.firstRange(of: Array("\r\n\r\n".utf8))?.upperBound else { return [] }
        #expect(received.starts(with: Array("HTTP/1.1 101".utf8)))
        var frames: [ServerFrame] = []
        var at = end
        while received.count - at >= 2 {
            let short = Int(received[at + 1] & 0x7F)
            let extended = short == 126 ? 2 : short == 127 ? 8 : 0
            guard received.count - at >= 2 + extended else { break }
            let length = extended == 0 ? short : received[(at + 2)..<(at + 2 + extended)].reduce(0) { $0 << 8 | Int($1) }
            let start = at + 2 + extended
            guard received.count - start >= length else { break }
            frames.append(ServerFrame(opcode: received[at] & 0x0F, payload: Array(received[start..<(start + length)])))
            at = start + length
        }
        return frames
    }
}

/// Every byte the server sends, onto a stream that ends when the connection does.
private final class Collector: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<[UInt8]>.Continuation

    init(_ continuation: AsyncStream<[UInt8]>.Continuation) { self.continuation = continuation }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(Array(buffer: unwrapInboundIn(data)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }
}
