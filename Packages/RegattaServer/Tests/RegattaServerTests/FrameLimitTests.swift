import NIOCore
import NIOPosix
import RegattaDevAPI
@testable import RegattaServerKit
import Testing

/// Each WebSocket path's decoder has its own frame limit (#145): a race frame over 16 KiB is refused at its header,
/// before its payload is buffered (close 1009, message too big); a service frame may run to the service's cap.
/// Raw bytes over a plain TCP socket, so the test controls exactly what the server has seen.
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

    @Test func aServiceFrameOverTheRaceLimitReachesTheService() async throws {
        try await withServer { server in
            let length = 1 << 20
            #expect(length > RegattaHTTPServer.maxClientMessage && length <= server.services.config.frameCap)
            let socket = try await RawSocket.upgrade(port: server.port, path: ServerPath.service)
            // A whole 1 MiB frame of zeros: the decoder takes it, and the service closes on it as not a Hello (1008),
            // not the decoder as too big (1009).
            try await socket.send(Self.binaryFrameHeader(length: length) + [UInt8](repeating: 0, count: length))
            #expect(try await socket.closeCode() == 1008)
        }
    }

    /// A client binary frame's header: FIN + binary, masked, 64-bit length, a zero mask (so the payload goes as is).
    static func binaryFrameHeader(length: Int) -> [UInt8] {
        [0x82, 0x80 | 127] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) } + [0, 0, 0, 0]
    }
}

/// A TCP connection that sends a WebSocket upgrade and then raw bytes, and reads the server's close frame.
private final class RawSocket: Sendable {
    private let channel: any Channel
    private let bytes: AsyncStream<[UInt8]>

    private init(channel: any Channel, bytes: AsyncStream<[UInt8]>) {
        self.channel = channel
        self.bytes = bytes
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

    /// The status code of the close frame the server sends after its 101 response, or nil if the connection ends
    /// without one. Fails if neither happens within 10 s.
    func closeCode() async throws -> Int? {
        let bytes = self.bytes
        let channel = self.channel
        return try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var received: [UInt8] = []
                for await chunk in bytes {
                    received += chunk
                    if let code = Self.closeCode(in: received) { return code }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TimedOut()
            }
            defer {
                group.cancelAll()
                channel.close(promise: nil)
            }
            return try await group.next() ?? nil
        }
    }

    struct TimedOut: Error {}

    /// The close frame's code in `received`: after the upgrade response's blank line, an unmasked close frame
    /// (0x88) with a payload of at least the 2-byte code.
    private static func closeCode(in received: [UInt8]) -> Int? {
        guard let end = received.firstRange(of: Array("\r\n\r\n".utf8))?.upperBound else { return nil }
        #expect(received.starts(with: Array("HTTP/1.1 101".utf8)))
        let frame = received[end...]
        guard frame.count >= 4, frame[frame.startIndex] == 0x88 else { return nil }
        return Int(frame[frame.startIndex + 2]) << 8 | Int(frame[frame.startIndex + 3])
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
