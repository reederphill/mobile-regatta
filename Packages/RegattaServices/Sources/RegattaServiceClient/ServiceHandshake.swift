import RegattaProtocol
import Synchronization

// The opening of a service connection (#145, #161): `Hello`, answered `HelloAck` or `UpdateRequired`, before a
// `ServiceConnection` takes the link (it reads replies only, and a `HelloAck` is none).

/// A service link the session can keep alive.
public protocol SessionLink: ServiceLink {
    /// One keep-alive round trip (the transport's own ping, not a service message): returns at the peer's answer,
    /// throws when the link has closed or closes first.
    func ping() async throws
}

/// A link past its handshake. `incoming` gives every frame after the server's first; `closed` finishes when the
/// link has.
public final class HandshakenLink: SessionLink {
    public let incoming: AsyncStream<[UInt8]>
    /// Yields nothing; finishes when the link closes, from either end.
    public let closed: AsyncStream<Void>
    private let base: any SessionLink
    private let opening: AsyncStream<[UInt8]>

    init(_ base: any SessionLink) {
        self.base = base
        let (incoming, later) = AsyncStream.makeStream(of: [UInt8].self)
        let (opening, first) = AsyncStream.makeStream(of: [UInt8].self)
        let (closed, end) = AsyncStream.makeStream(of: Void.self)
        (self.incoming, self.opening, self.closed) = (incoming, opening, closed)
        let frames = base.incoming
        Task {
            var isFirst = true
            for await bytes in frames {
                if isFirst {
                    isFirst = false
                    first.yield(bytes)
                    first.finish()
                } else {
                    later.yield(bytes)
                }
            }
            first.finish()
            later.finish()
            end.finish()
        }
    }

    /// The server's first frame, or nil if the link closed without one.
    func openingFrame() async -> [UInt8]? {
        var iterator = opening.makeAsyncIterator()
        return await iterator.next()
    }

    public func send(_ frame: [UInt8]) { base.send(frame) }
    public func close() { base.close() }
    public func ping() async throws { try await base.ping() }
}

public enum HandshakeOutcome: Sendable {
    case accepted(HandshakenLink)
    /// The server won't serve this build. The link is closed.
    case updateRequired(UpdateRequired.Reason)
    /// No answer, or not one a handshake allows. The link is closed.
    case failed
}

public enum ServiceHandshake {
    /// Sends `Hello` on `link` and reads the server's answer.
    public static func open(_ link: any SessionLink, clientBuild: String) async -> HandshakeOutcome {
        let handshaken = HandshakenLink(link)
        guard let hello = try? Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: clientBuild, files: []))).encoded() else {
            link.close()
            return .failed
        }
        link.send(hello)
        guard let bytes = await handshaken.openingFrame(), let answer = try? Frame(decoding: bytes).message else {
            link.close()
            return .failed
        }
        switch answer {
        case .helloAck: return .accepted(handshaken)
        case .updateRequired(let update):
            link.close()
            return .updateRequired(update.reason)
        default:
            link.close()
            return .failed
        }
    }
}
