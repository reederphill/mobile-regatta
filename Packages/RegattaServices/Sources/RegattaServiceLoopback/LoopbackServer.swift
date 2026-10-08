import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServices

// An in-process server for the service messages (#143): it decodes each frame a client sends, answers it from
// the service implementations it was given (the scripted fakes, in the contract runner), and encodes the reply,
// so a client adapter over it goes through every byte a real server would see. Which situation a service is in
// is the caller's: it hands over a service already in it. Nothing here is on the wire.

/// The services a loopback server answers for; a request to one it wasn't given closes the link.
public struct LoopbackServices: Sendable {
    public var identity: (any IdentityService)?
    public var terms: (any TermsService)?
    public var queue: (any QueueService)?
    public var raceSession: (any RaceSessionService)?
    public var lobby: (any LobbyService)?
    public var profile: (any ProfileService)?
    public var analytics: (any AnalyticsTransport)?
    public var deletion: (any DataDeletionService)?

    public init(
        identity: (any IdentityService)? = nil, terms: (any TermsService)? = nil, queue: (any QueueService)? = nil,
        raceSession: (any RaceSessionService)? = nil, lobby: (any LobbyService)? = nil, profile: (any ProfileService)? = nil,
        analytics: (any AnalyticsTransport)? = nil, deletion: (any DataDeletionService)? = nil
    ) {
        self.identity = identity
        self.terms = terms
        self.queue = queue
        self.raceSession = raceSession
        self.lobby = lobby
        self.profile = profile
        self.analytics = analytics
        self.deletion = deletion
    }
}

public enum LoopbackServer {
    /// A link to a new in-process server for `services`. The server handles the frames one at a time, in order,
    /// and stops when either end closes; it closes the link on anything the protocol doesn't allow.
    public static func connect(serving services: LoopbackServices) -> any ServiceLink {
        let (client, server) = LoopbackLink.pair()
        Task {
            var dispatcher = Dispatcher(services: services)
            for await bytes in server.incoming {
                guard let reply = await dispatcher.handle(bytes) else { return server.close() }
                for message in reply {
                    dispatcher.seq &+= 1
                    guard let frame = try? Frame(seq: dispatcher.seq, tick: 0, message: message).encoded() else { return server.close() }
                    server.send(frame)
                }
            }
        }
        return client
    }
}

/// One end of an in-process link: what it sends arrives on the other end's `incoming`.
final class LoopbackLink: ServiceLink {
    let incoming: AsyncStream<[UInt8]>
    private let own: AsyncStream<[UInt8]>.Continuation
    private let peer: AsyncStream<[UInt8]>.Continuation

    private init(incoming: AsyncStream<[UInt8]>, own: AsyncStream<[UInt8]>.Continuation, peer: AsyncStream<[UInt8]>.Continuation) {
        self.incoming = incoming
        self.own = own
        self.peer = peer
    }

    static func pair() -> (LoopbackLink, LoopbackLink) {
        let (a, aIn) = AsyncStream<[UInt8]>.makeStream()
        let (b, bIn) = AsyncStream<[UInt8]>.makeStream()
        return (LoopbackLink(incoming: a, own: aIn, peer: bIn), LoopbackLink(incoming: b, own: bIn, peer: aIn))
    }

    func send(_ frame: [UInt8]) { peer.yield(frame) }

    func close() {
        own.finish()
        peer.finish()
    }
}

/// A stream a client opened: each read gives the reply carrying its next item.
private final class OpenStream {
    let next: (UInt32) async -> Message?

    init<Element: Sendable>(_ stream: AsyncStream<Element>, reply: @escaping (UInt32, Element) -> Message) {
        let box = IteratorBox(stream.makeAsyncIterator())
        next = { id in await box.next().map { reply(id, $0) } }
    }
}

private final class IteratorBox<Element: Sendable> {
    var iterator: AsyncStream<Element>.Iterator

    init(_ iterator: AsyncStream<Element>.Iterator) { self.iterator = iterator }

    func next() async -> Element? { await iterator.next() }
}

/// Answers a client's frames from `services`, keeping its open streams.
private struct Dispatcher {
    let services: LoopbackServices
    var seq: UInt32 = 0
    var streams: [UInt32: OpenStream] = [:]

    init(services: LoopbackServices) { self.services = services }

    /// The replies to one frame (none for a stream's opening or closing), or nil when the frame breaks the protocol
    /// or asks for a service this server doesn't have.
    mutating func handle(_ bytes: [UInt8]) async -> [Message]? {
        guard let message = try? Frame(decoding: bytes).message, message.type.direction == .clientToServer else { return nil }
        switch message {
        case .streamNext(let next):
            guard let stream = streams[next.stream] else { return [.streamEnd(StreamEnd(id: next.id))] }
            if let reply = await stream.next(next.id) { return [reply] }
            streams[next.stream] = nil
            return [.streamEnd(StreamEnd(id: next.id))]
        case .streamClose(let close):
            streams[close.stream] = nil
            return []
        case .identityRequest(let request):
            guard let service = services.identity else { return nil }
            if request.call == .openStateUpdates {
                return open(request.id, service.stateUpdates()) { .identityReply(ServiceReply(id: $0, result: .state($1.wire))) }
            }
            return await ServiceAnswers.identity(request.call, service).map { [.identityReply(ServiceReply(id: request.id, result: $0))] }
        case .termsRequest(let request):
            guard let service = services.terms else { return nil }
            return await ServiceAnswers.terms(request.call, service).map { [.termsReply(ServiceReply(id: request.id, result: $0))] }
        case .queueRequest(let request):
            guard let service = services.queue else { return nil }
            if request.call == .openStateUpdates {
                return open(request.id, service.stateUpdates()) { .queueReply(ServiceReply(id: $0, result: .state($1.wire))) }
            }
            return await ServiceAnswers.queue(request.call, service).map { [.queueReply(ServiceReply(id: request.id, result: $0))] }
        case .raceSessionRequest(let request):
            guard let service = services.raceSession else { return nil }
            switch request.call {
            case .openResults:
                return open(request.id, service.results()) { .raceSessionReply(ServiceReply(id: $0, result: .update($1.wire))) }
            case .openRatingChanges:
                return open(request.id, service.ratingChanges()) { .raceSessionReply(ServiceReply(id: $0, result: .ratingChange($1.wire))) }
            default:
                return await ServiceAnswers.raceSession(request.call, service).map { [.raceSessionReply(ServiceReply(id: request.id, result: $0))] }
            }
        case .lobbyRequest(let request):
            guard let service = services.lobby else { return nil }
            if request.call == .openFeed {
                return open(request.id, service.feed()) { .lobbyReply(ServiceReply(id: $0, result: .event($1.wire))) }
            }
            return await ServiceAnswers.lobby(request.call, service).map { [.lobbyReply(ServiceReply(id: request.id, result: $0))] }
        case .profileRequest(let request):
            guard let service = services.profile else { return nil }
            return await ServiceAnswers.profile(request.call, service).map { [.profileReply(ServiceReply(id: request.id, result: $0))] }
        case .analyticsRequest(let request):
            guard let service = services.analytics else { return nil }
            return await ServiceAnswers.analytics(request.call, service).map { [.analyticsReply(ServiceReply(id: request.id, result: $0))] }
        case .deletionRequest(let request):
            guard let service = services.deletion else { return nil }
            return await ServiceAnswers.deletion(request.call, service).map { [.deletionReply(ServiceReply(id: request.id, result: $0))] }
        default:
            return nil
        }
    }

    /// Opens a stream under `id`: the service's stream is taken now, in order with the requests around it.
    private mutating func open<Element: Sendable>(
        _ id: UInt32, _ stream: AsyncStream<Element>, reply: @escaping (UInt32, Element) -> Message
    ) -> [Message] {
        streams[id] = OpenStream(stream, reply: reply)
        return []
    }
}

/// Each service call answered from a service implementation, as its wire result: nil when the call has no reply
/// (a stream's opening) or the service failed in a way the protocol has no answer for (the link closes). The
/// loopback answers with it, and so does the real server (#145), so both map every call and error alike.
public enum ServiceAnswers {
    public static func identity(_ call: IdentityCall, _ service: any IdentityService) async -> IdentityResult? {
        switch call {
        case .state: return .state(await service.state().wire)
        case .signIn: return .state(await service.signIn().wire)
        case .gamePlayerID: return .gamePlayerID(await service.gamePlayerID()?.rawValue)
        case .identitySignature:
            do {
                return .signature(try await service.identitySignature().wire)
            } catch IdentityError.notSignedIn {
                return .notSignedIn
            } catch {
                return nil
            }
        case .openStateUpdates: return nil
        }
    }

    public static func terms(_ call: TermsCall, _ service: any TermsService) async -> TermsResult? {
        do {
            switch call {
            case .status: return .status(try await service.status().wire)
            case .accept(let version): return .status(try await service.accept(TermsVersion(version)).wire)
            }
        } catch TermsError.staleVersion(let current) {
            return .staleVersion(current: current.rawValue)
        } catch {
            return nil
        }
    }

    public static func queue(_ call: QueueCall, _ service: any QueueService) async -> QueueResult? {
        do {
            switch call {
            case .join: try await service.join()
            case .leave: try await service.leave()
            case .openStateUpdates: return nil
            }
            return .done
        } catch let error as QueueError {
            switch error {
            case .refused(let refusal): return .refused(refusal.wire)
            case .alreadyQueued: return .alreadyQueued
            case .notQueued: return .notQueued
            }
        } catch {
            return nil
        }
    }

    public static func raceSession(_ call: RaceSessionCall, _ service: any RaceSessionService) async -> RaceSessionResult? {
        do {
            switch call {
            case .handOff: return .handOff(try await service.handOff().wire)
            case .rejoin: return .rejoin(try await service.rejoin().wire)
            case .lastRace:
                guard let last = try await service.lastRace() else { return .noLastRace }
                return .lastRace(report: last.report.wire, rating: last.rating?.wire)
            case .openResults, .openRatingChanges: return nil
            }
        } catch RaceSessionError.noRace {
            return .noRace
        } catch {
            return nil
        }
    }

    public static func lobby(_ call: LobbyCall, _ service: any LobbyService) async -> LobbyResult? {
        do {
            switch call {
            case .state: return .state(try await service.state().wire)
            case .history: return .history(try await service.history().map(\.wire))
            case .postText(let text): return .posted(try await service.post(text).wire)
            case .postQuickChat(let quick): return .posted(try await service.post(QuickChat(wire: quick)).wire)
            case .block(let id): try await service.block(GamePlayerID(id))
            case .unblock(let id): try await service.unblock(GamePlayerID(id))
            case .blockedPlayers:
                return .blockedPlayers(try await service.blockedPlayers().map {
                    WireBlockedPlayer(gamePlayerID: $0.gamePlayerID.rawValue, nickname: $0.nickname)
                })
            case .reportMessage(let id): try await service.report(message: MessageID(id))
            case .reportPlayer(let id): try await service.report(player: GamePlayerID(id))
            case .reportRace(let raceID, let seat, let reason):
                try await service.report(race: RaceID(raceID), seat: seat, reason: RaceReportReason(wire: reason))
            case .openFeed: return nil
            }
            return .done
        } catch let error as LobbyError {
            return .failure(error.wire)
        } catch {
            return nil
        }
    }

    public static func profile(_ call: ProfileCall, _ service: any ProfileService) async -> ProfileResult? {
        do {
            switch call {
            case .profile: return .profile(try await service.profile().wire)
            case .saveLivery(let livery): return .livery(try await service.saveLivery(livery))
            }
        } catch let error as ProfileError {
            switch error {
            case .notSignedIn: return .notSignedIn
            case .invalidLivery(let problem): return .invalidLivery(problem.wire)
            case .liveryLocked: return .liveryLocked
            }
        } catch {
            return nil
        }
    }

    public static func analytics(_ batch: WireAnalyticsBatch, _ service: any AnalyticsTransport) async -> AnalyticsResult? {
        do {
            let receipt = try await service.send(AnalyticsBatch(wire: batch))
            return .receipt(accepted: receipt.accepted, duplicates: receipt.duplicates)
        } catch let error as AnalyticsError {
            switch error {
            case .batchTooLarge(let max): return .batchTooLarge(max: max)
            case .unavailable: return .unavailable
            }
        } catch {
            return nil
        }
    }

    public static func deletion(_ call: DeletionCall, _ service: any DataDeletionService) async -> DeletionResult? {
        do {
            switch call {
            case .plan: return .plan(try await service.plan().wire)
            case .delete(let token):
                try await service.delete(confirmedBy: DeletionConfirmation(token: token))
                return .deleted
            }
        } catch let error as DataDeletionError {
            switch error {
            case .notSignedIn: return .notSignedIn
            case .nothingToDelete: return .nothingToDelete
            case .invalidConfirmation: return .invalidConfirmation
            }
        } catch {
            return nil
        }
    }
}
