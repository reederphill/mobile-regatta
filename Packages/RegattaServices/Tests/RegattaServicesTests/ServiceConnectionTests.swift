import RegattaProtocol
import RegattaServiceClient
import RegattaServiceLoopback
import RegattaServices
import Synchronization
import Testing

/// The client's side of the service messages (#143): replies pair with requests by id, streams read one item per
/// ask, and a server that breaks the protocol closes the connection.
@Suite struct ServiceConnectionTests {
    /// A link whose server answers each frame with `answer`'s messages, and records what it was sent.
    final class ScriptedLink: ServiceLink {
        let incoming: AsyncStream<[UInt8]>
        private let continuation: AsyncStream<[UInt8]>.Continuation
        private let answer: @Sendable (Message) -> [Message]
        let sent = Mutex<[Message]>([])

        init(answer: @escaping @Sendable (Message) -> [Message]) {
            (incoming, continuation) = AsyncStream.makeStream()
            self.answer = answer
        }

        func send(_ frame: [UInt8]) {
            guard let message = try? Frame(decoding: frame).message else { return continuation.finish() }
            sent.withLock { $0.append(message) }
            for reply in answer(message) { continuation.yield(try! Frame(seq: 0, tick: 0, message: reply).encoded()) }
        }

        func close() { continuation.finish() }
    }

    @Test func aReplyToNoRequestInFlightIsRejected() async throws {
        let link = ScriptedLink { message in
            guard case .termsRequest(let request) = message else { return [] }
            return [.termsReply(ServiceReply(id: request.id + 1, result: .status(.accepted(version: 1))))]
        }
        let terms = RemoteTermsService(ServiceConnection(link))
        await #expect(throws: ServiceLinkError.protocolViolation("a reply to request 2, which isn't in flight")) { try await terms.status() }
        // The connection is closed for good.
        await #expect(throws: ServiceLinkError.self) { try await terms.status() }
    }

    @Test func aRequestFromTheServerIsRejected() async throws {
        let link = ScriptedLink { _ in [.identityRequest(ServiceRequest(id: 1, call: .state))] }
        let identity = RemoteIdentityService(ServiceConnection(link))
        await #expect(throws: ServiceLinkError.protocolViolation("identityRequest from the server")) { try await identity.identitySignature() }
        // A call that can't throw answers as if offline.
        #expect(await identity.state() == .signedOut)
    }

    @Test func aReplyOfAnotherServiceIsUnexpected() async throws {
        let link = ScriptedLink { message in
            guard case .termsRequest(let request) = message else { return [] }
            return [.queueReply(ServiceReply(id: request.id, result: .done))]
        }
        let terms = RemoteTermsService(ServiceConnection(link))
        await #expect(throws: ServiceLinkError.unexpectedReply("queueReply to status")) { try await terms.status() }
    }

    /// Replies can come in any order: each finds its request by id.
    @Test func repliesPairByIDInAnyOrder() async throws {
        let held = Mutex<[ServiceRequest<TermsCall>]>([])
        let link = ScriptedLink { message in
            guard case .termsRequest(let request) = message else { return [] }
            let ready: [ServiceRequest<TermsCall>] = held.withLock { held in
                held.append(request)
                guard held.count == 2 else { return [] }
                defer { held.removeAll() }
                return held.reversed()
            }
            return ready.map { request in
                guard case .accept(let version) = request.call else { return .termsReply(ServiceReply(id: request.id, result: .staleVersion(current: 0))) }
                return .termsReply(ServiceReply(id: request.id, result: .status(.accepted(version: version))))
            }
        }
        let terms = RemoteTermsService(ServiceConnection(link))
        async let first = terms.accept(TermsVersion(1))
        async let second = terms.accept(TermsVersion(2))
        #expect(try await [first, second] == [.accepted(TermsVersion(1)), .accepted(TermsVersion(2))])
    }

    /// A stream is opened when it's asked for, in order with the calls after it, and read one `StreamNext` an item;
    /// dropping it closes it on the server.
    @Test func streamsReadOneItemPerAskAndCloseWhenDropped() async throws {
        let link = ScriptedLink { message in
            switch message {
            case .streamNext(let next): [.queueReply(ServiceReply(id: next.id, result: .state(.idle)))]
            case .queueRequest(let request) where request.call == .join: [.queueReply(ServiceReply(id: request.id, result: .done))]
            default: []
            }
        }
        let queue = RemoteQueueService(ServiceConnection(link))
        do {
            let updates = queue.stateUpdates()
            try await queue.join()
            var reader = updates.makeAsyncIterator()
            #expect(await reader.next() == .idle)
            #expect(await reader.next() == .idle)
        }
        let sent = link.sent.withLock { $0 }
        guard case .queueRequest(let open)? = sent.first, open.call == .openStateUpdates else {
            Issue.record("the stream wasn't opened first: \(sent)")
            return
        }
        #expect(sent.map(\.type) == [.queueRequest, .queueRequest, .streamNext, .streamNext, .streamClose])
        #expect(sent.allSatisfy { if case .streamNext(let next) = $0 { next.stream == open.id } else { true } })
        #expect(sent.last == .streamClose(StreamClose(stream: open.id)))
    }

    /// The loopback answers a stream it doesn't have with its end, and a frame it can't read by closing the link.
    @Test func theLoopbackEndsUnknownStreamsAndClosesOnGarbage() async throws {
        let link = LoopbackServer.connect(serving: LoopbackServices())
        let connection = ServiceConnection(link)
        #expect(try await connection.request { .streamNext(StreamNext(id: $0, stream: 99)) } == .streamEnd(StreamEnd(id: 1)))
        link.send([0xFF])
        await #expect(throws: ServiceLinkError.self) { try await connection.request { .streamNext(StreamNext(id: $0, stream: 99)) } }
    }
}
