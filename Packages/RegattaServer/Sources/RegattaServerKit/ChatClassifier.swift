import ChatFilter
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

// The lobby's classifier call (#152): bounded, timed and behind a breaker, so the service being down costs a post at
// most the time limit, and nothing once the breaker is open. It fails open (owner 2026-10-11): `unavailable` lets the
// message through on the word list alone.

/// A `ToxicityClassifier` as the posting pipeline asks it: at most `maxInFlight` calls at once, each given `timeout`,
/// and none while the breaker is open (5 failures in a row open it for 30 s, then one probe).
public final class ClassifierGate: Sendable {
    public let classifier: any ToxicityClassifier
    public let timeout: Duration
    public let maxInFlight: Int
    private let now: @Sendable () -> Double
    private let state: Mutex<(breaker: CircuitBreaker, inFlight: Int)>

    /// `now`: seconds on a monotonic clock, for the breaker.
    public init(_ classifier: any ToxicityClassifier, timeout: Duration = .milliseconds(2500), maxInFlight: Int = 8,
                breaker: CircuitBreaker = CircuitBreaker(), now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.classifier = classifier
        self.timeout = timeout
        self.maxInFlight = maxInFlight
        self.now = now
        state = Mutex((breaker, 0))
    }

    public var isBreakerOpen: Bool { state.withLock { $0.breaker.isOpen } }

    /// What the classifier makes of `text`. Never throws and never takes longer than `timeout`.
    public func screen(_ text: String) async -> ToxicityScreening {
        let refusal: ToxicityScreening.Unavailable? = state.withLock { state in
            guard state.inFlight < maxInFlight else { return .busy }
            guard state.breaker.allows(at: now()) else { return .breakerOpen }
            state.inFlight += 1
            return nil
        }
        if let refusal { return .unavailable(refusal) }
        let classifier = classifier
        let outcome: ToxicityScreening
        do {
            outcome = try await withDeadline(timeout) { try await classifier.isFlagged(text) } ? .flagged : .clean
        } catch is DeadlineExceeded {
            outcome = .unavailable(.timeout)
        } catch {
            outcome = .unavailable(.error)
        }
        state.withLock { state in
            state.inFlight -= 1
            if case .unavailable = outcome { state.breaker.failed(at: now()) } else { state.breaker.succeeded() }
        }
        return outcome
    }
}

/// OpenAI's moderation endpoint as the lobby's classifier (#51, #152): `POST /v1/moderations`, model
/// `omni-moderation-latest`. Only made when `OPENAI_MODERATION_API_KEY` is configured. It sends the text and the
/// model's name, nothing about the player. HTTP/1.1 on NIO with NIOSSL, as `HTTPSCertificateFetcher`.
///
/// Anything but a 200 with a readable answer throws: the gate reads that as unavailable. No error carries the key or
/// the text.
public struct OpenAIModerationClassifier: ToxicityClassifier {
    public static let defaultEndpoint = "https://api.openai.com/v1/moderations"
    public static let model = "omni-moderation-latest"
    /// The request is the text (at most `ChatText.maxBytes`, doubled if every byte needs escaping) and a few dozen bytes.
    static let maxRequestBody = 2 * 1024
    static let maxResponseBody = 64 * 1024

    public enum CallError: Error, Equatable, Sendable {
        case badEndpoint
        case requestTooLarge
        case status(Int)
        case responseTooLarge
        case incomplete
        case unreadable
    }

    let host: String
    let port: Int
    let path: String
    let key: String
    let group: any EventLoopGroup
    let timeout: Duration
    /// Nil: plain HTTP, which only a loopback endpoint may be (a test's stub).
    let context: NIOSSLContext?

    public init(key: String, endpoint: String = OpenAIModerationClassifier.defaultEndpoint,
                group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, timeout: Duration = .milliseconds(2500)) throws {
        guard !key.isEmpty, let url = URLComponents(string: endpoint), let host = url.host, let scheme = url.scheme else { throw CallError.badEndpoint }
        switch scheme {
        case "https": context = try NIOSSLContext(configuration: .makeClientConfiguration())
        case "http" where ["127.0.0.1", "localhost", "::1"].contains(host): context = nil
        default: throw CallError.badEndpoint
        }
        self.key = key
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
        path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        self.group = group
        self.timeout = timeout
    }

    private struct Request: Encodable {
        let model: String
        let input: String
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            let flagged: Bool
        }

        let results: [Result]
    }

    /// The request's body for `text`.
    static func body(for text: String) throws -> [UInt8] {
        let body = [UInt8](try JSONEncoder().encode(Request(model: model, input: text)))
        guard body.count <= maxRequestBody else { throw CallError.requestTooLarge }
        return body
    }

    public func isFlagged(_ text: String) async throws -> Bool {
        let body = try Self.body(for: text)
        let context = context, host = host
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(timeout.components.seconds) * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000))
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host)) }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        let deadline = Task { [timeout] in
            try await Task.sleep(for: timeout)
            try await channel.channel.close()
        }
        defer { deadline.cancel() }
        return try await channel.executeThenClose { inbound, outbound in
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: host)
            headers.add(name: "Authorization", value: "Bearer \(key)")
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(body.count))
            headers.add(name: "Connection", value: "close")
            try await outbound.write(contentsOf: [
                .head(HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: headers)),
                .body(.byteBuffer(ByteBuffer(bytes: body))),
                .end(nil),
            ])
            var status = 0
            var answer: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let head): status = Int(head.status.code)
                case .body(let buffer):
                    answer += Array(buffer: buffer)
                    guard answer.count <= Self.maxResponseBody else { throw CallError.responseTooLarge }
                case .end:
                    guard status == 200 else { throw CallError.status(status) }
                    guard let response = try? JSONDecoder().decode(Response.self, from: Data(answer)), !response.results.isEmpty else {
                        throw CallError.unreadable
                    }
                    return response.results.contains(where: \.flagged)
                }
            }
            throw CallError.incomplete
        }
    }
}
