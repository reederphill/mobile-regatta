import RegattaProtocol
import Synchronization

// The client side of the service messages (#143): a connection that pairs each request with its reply by id, and
// reads streams one item per `StreamNext`. The adapters (`Remote…Service`) put each service protocol on it.

/// What carries the service frames: each `send` is one whole frame, delivered in order, and `incoming` gives the
/// peer's frames in order. The transport behind it (the server's, or an in-process loopback) is the implementer's:
/// this package names none.
public protocol ServiceLink: Sendable {
    /// Sends one frame, in order after every earlier `send`. Returns at once.
    func send(_ frame: [UInt8])
    /// The peer's frames, in order. Finishes when the link closes.
    var incoming: AsyncStream<[UInt8]> { get }
    /// Closes the link: `incoming` finishes here, and the peer's finishes too.
    func close()
}

/// Opens links to a service endpoint (#143's `CONTRACT_ENDPOINT`): the server tickets (#145 on) plug one in. The
/// endpoint arranges the asked-for situation (a test account in that state) before the link is handed over.
public protocol ServiceEndpointConnector: Sendable {
    /// A link to `endpoint` for `service` (a contract suite's name) put in `situation` (its `Situation` case's name).
    func connect(to endpoint: String, service: String, situation: String) async throws -> any ServiceLink
}

public enum ServiceLinkError: Error, Equatable, Sendable {
    /// The link closed before the reply came.
    case closed
    /// The peer sent something the protocol doesn't allow: bytes that don't decode, a message the client never
    /// receives, or a reply to no request in flight. The connection closes.
    case protocolViolation(String)
    /// A reply that isn't an answer to what was asked.
    case unexpectedReply(String)
    /// The request can't be put on the wire (`WireError` on encoding).
    case unencodable(WireError)
}

/// One client's connection to the services. Requests can be in flight together; each waits for the reply with its id.
public final class ServiceConnection: Sendable {
    private struct State {
        var nextID: UInt32 = 1
        var seq: UInt32 = 0
        var pending: [UInt32: CheckedContinuation<Message, any Error>] = [:]
        var failure: ServiceLinkError?
    }

    private let link: any ServiceLink
    private let state = Mutex(State())

    public init(_ link: any ServiceLink) {
        self.link = link
        let incoming = link.incoming
        Task { [weak self] in
            for await bytes in incoming {
                guard let self else { return }
                self.receive(bytes)
            }
            self?.fail(.closed)
        }
    }

    deinit { link.close() }

    /// Sends the request `make` builds with a fresh id, and returns the reply to it.
    public func request(_ make: (UInt32) -> Message) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            switch frame(make, pending: continuation) {
            case .success(let bytes): link.send(bytes)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    /// Sends a message that has no reply (a stream's opening or closing), at once, and returns the id it used.
    @discardableResult
    public func post(_ make: (UInt32) -> Message) throws -> UInt32 {
        var id: UInt32 = 0
        let bytes = try frame({ id = $0; return make($0) }, pending: nil).get()
        link.send(bytes)
        return id
    }

    /// A stream the call `open` opens, read one item per `StreamNext`: `item` turns each reply into an element.
    /// It ends at the server's `StreamEnd`, when the link fails, or at a reply `item` can't read (nil). The
    /// stream is opened now, in order with the requests around it; dropping it closes it on the server.
    public func stream<Element: Sendable>(
        open: (UInt32) -> Message, item: @escaping @Sendable (Message) -> Element?
    ) -> AsyncStream<Element> {
        guard let id = try? post(open) else { return AsyncStream { $0.finish() } }
        let token = StreamToken(stream: id) { [weak self] in _ = try? self?.post { _ in .streamClose(StreamClose(stream: id)) } }
        return AsyncStream {
            let next = { (request: UInt32) in Message.streamNext(StreamNext(id: request, stream: token.stream)) }
            guard let reply = try? await self.request(next) else { return nil }
            if case .streamEnd = reply { return nil }
            return item(reply)
        }
    }

    /// The frame for `make`'s message under a fresh id, registering `pending` for its reply; or the reason it can't go.
    private func frame(_ make: (UInt32) -> Message, pending: CheckedContinuation<Message, any Error>?) -> Result<[UInt8], ServiceLinkError> {
        state.withLock { state in
            if let failure = state.failure { return .failure(failure) }
            let id = state.nextID
            state.nextID &+= 1
            state.seq &+= 1
            do {
                let bytes = try Frame(seq: state.seq, tick: 0, message: make(id)).encoded()
                if let pending { state.pending[id] = pending }
                return .success(bytes)
            } catch let error as WireError {
                return .failure(.unencodable(error))
            } catch {
                return .failure(.unencodable(.outOfRange("\(error)")))
            }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        let message: Message
        do {
            message = try Frame(decoding: bytes).message
        } catch {
            return fail(.protocolViolation("undecodable frame: \(error)"))
        }
        guard message.type.direction == .serverToClient, let id = message.replyID else {
            return fail(.protocolViolation("\(message.type) from the server"))
        }
        guard let continuation = state.withLock({ $0.pending.removeValue(forKey: id) }) else {
            return fail(.protocolViolation("a reply to request \(id), which isn't in flight"))
        }
        continuation.resume(returning: message)
    }

    /// Fails every request in flight and every later one with `error`, and closes the link.
    private func fail(_ error: ServiceLinkError) {
        let pending = state.withLock { state in
            if state.failure == nil { state.failure = error }
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: error) }
        link.close()
    }
}

/// Closes its stream on the server when the stream it belongs to is dropped.
private final class StreamToken: Sendable {
    let stream: UInt32
    let close: @Sendable () -> Void

    init(stream: UInt32, close: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.close = close
    }

    deinit { close() }
}
