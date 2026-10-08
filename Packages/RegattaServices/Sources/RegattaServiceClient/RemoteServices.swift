import RegattaCore
import RegattaProtocol
import RegattaServices

// Each #109 / #241 service protocol over the service messages (#143), on one `ServiceConnection`. The real client
// services (#161–#166) build on these. A call the link can't answer throws `ServiceLinkError`; where the protocol's
// call can't throw, it answers as if offline: signed out, no player, and streams end.

/// Game Center as the server sees it (#16, #314).
public struct RemoteIdentityService: IdentityService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: IdentityCall) async throws -> IdentityResult {
        let reply = try await connection.request { .identityRequest(ServiceRequest(id: $0, call: call)) }
        guard case .identityReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        return reply.result
    }

    private func gameCenterState(_ call: IdentityCall) async -> GameCenterState {
        guard case .state(let player)? = try? await self.call(call) else { return .signedOut }
        return GameCenterState(wire: player)
    }

    public func state() async -> GameCenterState { await gameCenterState(.state) }

    public func stateUpdates() -> AsyncStream<GameCenterState> {
        connection.stream(open: { .identityRequest(ServiceRequest(id: $0, call: .openStateUpdates)) }) { reply in
            guard case .identityReply(let reply) = reply, case .state(let player) = reply.result else { return nil }
            return GameCenterState(wire: player)
        }
    }

    public func gamePlayerID() async -> GamePlayerID? {
        guard case .gamePlayerID(let id)? = try? await call(.gamePlayerID) else { return nil }
        return id.map(GamePlayerID.init)
    }

    public func identitySignature() async throws -> IdentitySignature {
        switch try await call(.identitySignature) {
        case .signature(let signature): return IdentitySignature(wire: signature)
        case .notSignedIn: throw IdentityError.notSignedIn
        case let other: throw ServiceLinkError.unexpectedReply("\(other) to identitySignature")
        }
    }

    public func signIn() async -> GameCenterState { await gameCenterState(.signIn) }
}

/// The Terms of Use acceptance (#34).
public struct RemoteTermsService: TermsService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: TermsCall) async throws -> TermsStatus {
        let reply = try await connection.request { .termsRequest(ServiceRequest(id: $0, call: call)) }
        guard case .termsReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        switch reply.result {
        case .status(let status): return TermsStatus(wire: status)
        case .staleVersion(let current): throw TermsError.staleVersion(current: TermsVersion(current))
        }
    }

    public func status() async throws -> TermsStatus { try await call(.status) }
    public func accept(_ version: TermsVersion) async throws -> TermsStatus { try await call(.accept(version: version.rawValue)) }
}

/// The one global queue (#16).
public struct RemoteQueueService: QueueService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    public func stateUpdates() -> AsyncStream<QueueState> {
        connection.stream(open: { .queueRequest(ServiceRequest(id: $0, call: .openStateUpdates)) }) { reply in
            guard case .queueReply(let reply) = reply, case .state(let state) = reply.result else { return nil }
            return QueueState(wire: state)
        }
    }

    private func call(_ call: QueueCall) async throws {
        let reply = try await connection.request { .queueRequest(ServiceRequest(id: $0, call: call)) }
        guard case .queueReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        switch reply.result {
        case .done: return
        case .refused(let refusal): throw QueueError.refused(QueueRefusal(wire: refusal))
        case .alreadyQueued: throw QueueError.alreadyQueued
        case .notQueued: throw QueueError.notQueued
        case .state: throw ServiceLinkError.unexpectedReply("a state to \(call)")
        }
    }

    public func join() async throws { try await call(.join) }
    public func leave() async throws { try await call(.leave) }
}

/// The player's race around the race transport: hand-off, rejoin, results, rating, last race (#16, #24).
public struct RemoteRaceSessionService: RaceSessionService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: RaceSessionCall) async throws -> RaceSessionResult {
        let reply = try await connection.request { .raceSessionRequest(ServiceRequest(id: $0, call: call)) }
        guard case .raceSessionReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        if case .noRace = reply.result { throw RaceSessionError.noRace }
        return reply.result
    }

    public func handOff() async throws -> HandOff {
        guard case .handOff(let handOff) = try await call(.handOff) else { throw ServiceLinkError.unexpectedReply("handOff") }
        return HandOff(wire: handOff)
    }

    public func rejoin() async throws -> RejoinOffer {
        guard case .rejoin(let offer) = try await call(.rejoin) else { throw ServiceLinkError.unexpectedReply("rejoin") }
        return RejoinOffer(wire: offer)
    }

    public func results() -> AsyncStream<RaceUpdate> {
        connection.stream(open: { .raceSessionRequest(ServiceRequest(id: $0, call: .openResults)) }) { reply in
            guard case .raceSessionReply(let reply) = reply, case .update(let update) = reply.result else { return nil }
            return RaceUpdate(wire: update)
        }
    }

    public func ratingChanges() -> AsyncStream<RatingChange> {
        connection.stream(open: { .raceSessionRequest(ServiceRequest(id: $0, call: .openRatingChanges)) }) { reply in
            guard case .raceSessionReply(let reply) = reply, case .ratingChange(let change) = reply.result else { return nil }
            return RatingChange(wire: change)
        }
    }

    public func lastRace() async throws -> LastRace? {
        switch try await call(.lastRace) {
        case .lastRace(let report, let rating): return LastRace(report: RaceReport(wire: report), rating: rating.map(RatingChange.init(wire:)))
        case .noLastRace: return nil
        case let other: throw ServiceLinkError.unexpectedReply("\(other) to lastRace")
        }
    }
}

/// The global lobby (#17, #34).
public struct RemoteLobbyService: LobbyService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: LobbyCall) async throws -> LobbyResult {
        let reply = try await connection.request { .lobbyRequest(ServiceRequest(id: $0, call: call)) }
        guard case .lobbyReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        if case .failure(let error) = reply.result { throw LobbyError(wire: error) }
        return reply.result
    }

    private func done(_ call: LobbyCall) async throws {
        guard case .done = try await self.call(call) else { throw ServiceLinkError.unexpectedReply("to \(call)") }
    }

    private func posted(_ call: LobbyCall) async throws -> LobbyMessage {
        guard case .posted(let message) = try await self.call(call) else { throw ServiceLinkError.unexpectedReply("to a post") }
        return LobbyMessage(wire: message)
    }

    public func state() async throws -> LobbyState {
        guard case .state(let state) = try await call(.state) else { throw ServiceLinkError.unexpectedReply("to state") }
        return LobbyState(wire: state)
    }

    public func history() async throws -> [LobbyMessage] {
        guard case .history(let messages) = try await call(.history) else { throw ServiceLinkError.unexpectedReply("to history") }
        return messages.map(LobbyMessage.init(wire:))
    }

    public func feed() -> AsyncStream<LobbyEvent> {
        connection.stream(open: { .lobbyRequest(ServiceRequest(id: $0, call: .openFeed)) }) { reply in
            guard case .lobbyReply(let reply) = reply, case .event(let event) = reply.result else { return nil }
            return LobbyEvent(wire: event)
        }
    }

    public func post(_ text: String) async throws -> LobbyMessage { try await posted(.postText(text)) }
    public func post(_ quickChat: QuickChat) async throws -> LobbyMessage { try await posted(.postQuickChat(quickChat.wire)) }
    public func block(_ player: GamePlayerID) async throws { try await done(.block(gamePlayerID: player.rawValue)) }
    public func unblock(_ player: GamePlayerID) async throws { try await done(.unblock(gamePlayerID: player.rawValue)) }

    public func blockedPlayers() async throws -> [BlockedPlayer] {
        guard case .blockedPlayers(let players) = try await call(.blockedPlayers) else {
            throw ServiceLinkError.unexpectedReply("to blockedPlayers")
        }
        return players.map { BlockedPlayer(gamePlayerID: GamePlayerID($0.gamePlayerID), nickname: $0.nickname) }
    }

    public func report(message: MessageID) async throws { try await done(.reportMessage(messageID: message.rawValue)) }
    public func report(player: GamePlayerID) async throws { try await done(.reportPlayer(gamePlayerID: player.rawValue)) }

    public func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws {
        try await done(.reportRace(raceID: race.rawValue, seat: seat, reason: reason.wire))
    }
}

/// The player's online profile and stored livery (#25, #21).
public struct RemoteProfileService: ProfileService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: ProfileCall) async throws -> ProfileResult {
        let reply = try await connection.request { .profileRequest(ServiceRequest(id: $0, call: call)) }
        guard case .profileReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        switch reply.result {
        case .notSignedIn: throw ProfileError.notSignedIn
        case .invalidLivery(let problem): throw ProfileError.invalidLivery(LiveryProblem(wire: problem))
        case .liveryLocked: throw ProfileError.liveryLocked
        case .profile, .livery: return reply.result
        }
    }

    public func profile() async throws -> Profile {
        guard case .profile(let profile) = try await call(.profile) else { throw ServiceLinkError.unexpectedReply("to profile") }
        return Profile(wire: profile)
    }

    public func saveLivery(_ livery: Livery) async throws -> Livery {
        guard case .livery(let stored) = try await call(.saveLivery(livery)) else { throw ServiceLinkError.unexpectedReply("to saveLivery") }
        return stored
    }
}

/// Usage analytics to the race server (#28).
public struct RemoteAnalyticsTransport: AnalyticsTransport {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    public func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
        let wire = batch.wire
        let reply = try await connection.request { .analyticsRequest(ServiceRequest(id: $0, call: wire)) }
        guard case .analyticsReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to a batch") }
        switch reply.result {
        case .receipt(let accepted, let duplicates): return AnalyticsReceipt(accepted: accepted, duplicates: duplicates)
        case .batchTooLarge(let max): throw AnalyticsError.batchTooLarge(max: max)
        case .unavailable: throw AnalyticsError.unavailable
        }
    }
}

/// Delete my online data (#28).
public struct RemoteDataDeletionService: DataDeletionService {
    public let connection: ServiceConnection

    public init(_ connection: ServiceConnection) { self.connection = connection }

    private func call(_ call: DeletionCall) async throws -> DeletionResult {
        let reply = try await connection.request { .deletionRequest(ServiceRequest(id: $0, call: call)) }
        guard case .deletionReply(let reply) = reply else { throw ServiceLinkError.unexpectedReply("\(reply.type) to \(call)") }
        switch reply.result {
        case .notSignedIn: throw DataDeletionError.notSignedIn
        case .nothingToDelete: throw DataDeletionError.nothingToDelete
        case .invalidConfirmation: throw DataDeletionError.invalidConfirmation
        case .plan, .deleted: return reply.result
        }
    }

    public func plan() async throws -> DeletionPlan {
        guard case .plan(let plan) = try await call(.plan) else { throw ServiceLinkError.unexpectedReply("to plan") }
        return DeletionPlan(wire: plan)
    }

    public func delete(confirmedBy confirmation: DeletionConfirmation) async throws {
        guard case .deleted = try await call(.delete(confirmation: confirmation.token)) else {
            throw ServiceLinkError.unexpectedReply("to delete")
        }
    }
}
