import RegattaCore
import RegattaProtocol
import RegattaServices

// The service types to and from their wire forms (#143): `init(wire:)` reads one, `wire` writes one. Both ways,
// so the adapters here and a server (the loopback, #145 on) share them.

// MARK: - Identity and terms

extension GameCenterPlayer {
    public init(wire: WirePlayer) {
        self.init(gamePlayerID: GamePlayerID(wire.gamePlayerID), alias: wire.alias, isUnderage: wire.isUnderage,
                  isPersonalizedCommunicationRestricted: wire.isPersonalizedCommunicationRestricted,
                  isMultiplayerGamingRestricted: wire.isMultiplayerGamingRestricted)
    }

    public var wire: WirePlayer {
        WirePlayer(gamePlayerID: gamePlayerID.rawValue, alias: alias, isUnderage: isUnderage,
                   isPersonalizedCommunicationRestricted: isPersonalizedCommunicationRestricted,
                   isMultiplayerGamingRestricted: isMultiplayerGamingRestricted)
    }
}

extension GameCenterState {
    public init(wire: WirePlayer?) { self = wire.map { .signedIn(GameCenterPlayer(wire: $0)) } ?? .signedOut }
    public var wire: WirePlayer? { player?.wire }
}

extension IdentitySignature {
    public init(wire: WireIdentitySignature) {
        self.init(gamePlayerID: GamePlayerID(wire.gamePlayerID), publicKeyURL: wire.publicKeyURL, signature: wire.signature,
                  salt: wire.salt, timestamp: wire.timestamp)
    }

    public var wire: WireIdentitySignature {
        WireIdentitySignature(gamePlayerID: gamePlayerID.rawValue, publicKeyURL: publicKeyURL, signature: signature, salt: salt,
                              timestamp: timestamp)
    }
}

extension TermsStatus {
    public init(wire: WireTermsStatus) {
        switch wire {
        case .accepted(let version): self = .accepted(TermsVersion(version))
        case .needsAcceptance(let current, let last): self = .needsAcceptance(current: TermsVersion(current), lastAccepted: last.map(TermsVersion.init))
        }
    }

    public var wire: WireTermsStatus {
        switch self {
        case .accepted(let version): .accepted(version: version.rawValue)
        case .needsAcceptance(let current, let last): .needsAcceptance(current: current.rawValue, lastAccepted: last?.rawValue)
        }
    }
}

// MARK: - Queue

extension QueueRefusal {
    public init(wire: WireQueueRefusal) {
        switch wire {
        case .notSignedIn: self = .notSignedIn
        case .termsNotAccepted: self = .termsNotAccepted
        case .multiplayerRestricted: self = .multiplayerRestricted
        case .cooldown(let seconds): self = .cooldown(secondsRemaining: seconds)
        case .suspended(let until): self = .suspended(until: until)
        case .attestationFailed: self = .attestationFailed
        case .updateRequired: self = .updateRequired
        }
    }

    public var wire: WireQueueRefusal {
        switch self {
        case .notSignedIn: .notSignedIn
        case .termsNotAccepted: .termsNotAccepted
        case .multiplayerRestricted: .multiplayerRestricted
        case .cooldown(let seconds): .cooldown(secondsRemaining: seconds)
        case .suspended(let until): .suspended(until: until)
        case .attestationFailed: .attestationFailed
        case .updateRequired: .updateRequired
        }
    }
}

extension QueueState {
    public init(wire: WireQueueState) {
        switch wire {
        case .idle: self = .idle
        case .unavailable(let refusal): self = .unavailable(QueueRefusal(wire: refusal))
        case .queued(let players, let seconds): self = .queued(QueuedStatus(queuedPlayers: players, secondsToLock: seconds))
        case .fleetLocked: self = .fleetLocked
        }
    }

    public var wire: WireQueueState {
        switch self {
        case .idle: .idle
        case .unavailable(let refusal): .unavailable(refusal.wire)
        case .queued(let status): .queued(queuedPlayers: status.queuedPlayers, secondsToLock: status.secondsToLock)
        case .fleetLocked: .fleetLocked
        }
    }
}

// MARK: - Race session

extension HandOff {
    public init(wire: WireHandOff) { self.init(raceID: RaceID(wire.raceID), token: RaceToken(bytes: wire.token)) }
    public var wire: WireHandOff { WireHandOff(raceID: raceID.rawValue, token: token.bytes) }
}

extension RejoinOffer {
    public init(wire: WireRejoinOffer) {
        self.init(handOff: HandOff(wire: wire.handOff), seat: wire.seat,
                  clock: RaceClockReading(tick: wire.tick, expectedCloseTick: wire.expectedCloseTick))
    }

    public var wire: WireRejoinOffer {
        WireRejoinOffer(handOff: handOff.wire, seat: seat, tick: clock.tick, expectedCloseTick: clock.expectedCloseTick)
    }
}

extension RaceReport {
    public init(wire: WireRaceReport) {
        self.init(
            raceID: RaceID(wire.raceID), seat: wire.seat, roster: wire.roster, results: wire.results, sailing: wire.sailing,
            incidents: wire.incidents.map {
                SeatIncidents(seat: $0.seat, incidents: $0.incidents, markTouches: $0.markTouches, protests: $0.protests,
                              turnsServed: $0.turnsServed)
            },
            isClosed: wire.isClosed, flaggedSeats: wire.flaggedSeats)
    }

    public var wire: WireRaceReport {
        WireRaceReport(
            raceID: raceID.rawValue, seat: seat, roster: roster, results: results, sailing: sailing,
            incidents: incidents.map {
                WireSeatIncidents(seat: $0.seat, incidents: $0.incidents, markTouches: $0.markTouches, protests: $0.protests,
                                  turnsServed: $0.turnsServed)
            },
            isClosed: isClosed, flaggedSeats: flaggedSeats)
    }
}

extension RaceUpdate {
    public init(wire: WireRaceUpdate) {
        switch wire {
        case .report(let report): self = .report(RaceReport(wire: report))
        case .cancelled(let reason): self = .cancelled(reason)
        }
    }

    public var wire: WireRaceUpdate {
        switch self {
        case .report(let report): .report(report.wire)
        case .cancelled(let reason): .cancelled(reason)
        }
    }
}

extension Rating {
    public init(wire: WireRating) { self.init(value: wire.value, isProvisional: wire.isProvisional) }
    public var wire: WireRating { WireRating(value: value, isProvisional: isProvisional) }
}

extension RatingChange {
    public init(wire: WireRatingChange) {
        switch wire.outcome {
        case .rated(let before, let after):
            self.init(raceID: RaceID(wire.raceID), outcome: .rated(before: Rating(wire: before), after: Rating(wire: after)))
        case .unrated: self.init(raceID: RaceID(wire.raceID), outcome: .unrated)
        }
    }

    public var wire: WireRatingChange {
        switch outcome {
        case .rated(let before, let after): WireRatingChange(raceID: raceID.rawValue, outcome: .rated(before: before.wire, after: after.wire))
        case .unrated: WireRatingChange(raceID: raceID.rawValue, outcome: .unrated)
        }
    }
}

// MARK: - Lobby

extension LobbyAuthor {
    public init(wire: WireLobbyAuthor) {
        self.init(gamePlayerID: GamePlayerID(wire.gamePlayerID), nickname: wire.nickname, rating: Rating(wire: wire.rating),
                  chip: LiveryChip(deck: SwatchID(wire.deck), sail: SwatchID(wire.sail)))
    }

    public var wire: WireLobbyAuthor {
        WireLobbyAuthor(gamePlayerID: gamePlayerID.rawValue, nickname: nickname, rating: rating.wire, deck: chip.deck.rawValue,
                        sail: chip.sail.rawValue)
    }
}

extension QuickChat {
    public init(wire: WireQuickChat) {
        switch wire {
        case .gg: self = .gg
        case .goodRace: self = .goodRace
        case .oneMore: self = .oneMore
        case .wave: self = .wave
        }
    }

    public var wire: WireQuickChat {
        switch self {
        case .gg: .gg
        case .goodRace: .goodRace
        case .oneMore: .oneMore
        case .wave: .wave
        }
    }
}

extension LobbyMessage {
    public init(wire: WireLobbyMessage) {
        let kind: Kind = switch wire.kind {
        case .post(let author, let body, let isSent):
            .post(LobbyPost(author: LobbyAuthor(wire: author), body: PostBody(wire: body), delivery: isSent ? .sent : .notSent))
        case .gun(let venue, let boats, let humans): .system(.gun(venue: venue, boats: boats, humans: humans))
        case .winner(let venue, let nickname): .system(.winner(venue: venue, nickname: nickname))
        }
        self.init(id: MessageID(wire.id), kind: kind)
    }

    public var wire: WireLobbyMessage {
        let kind: WireLobbyMessage.Kind = switch kind {
        case .post(let post): .post(author: post.author.wire, body: post.body.wire, isSent: post.delivery == .sent)
        case .system(.gun(let venue, let boats, let humans)): .gun(venue: venue, boats: boats, humans: humans)
        case .system(.winner(let venue, let nickname)): .winner(venue: venue, nickname: nickname)
        }
        return WireLobbyMessage(id: id.rawValue, kind: kind)
    }
}

extension PostBody {
    public init(wire: WirePostBody) {
        switch wire {
        case .text(let text): self = .text(text)
        case .quickChat(let quick): self = .quickChat(QuickChat(wire: quick))
        }
    }

    public var wire: WirePostBody {
        switch self {
        case .text(let text): .text(text)
        case .quickChat(let quick): .quickChat(quick.wire)
        }
    }
}

extension LobbyClosure {
    public init(wire: WireLobbyClosure) {
        switch wire {
        case .notSignedIn: self = .notSignedIn
        case .termsNotAccepted: self = .termsNotAccepted
        case .communicationRestricted: self = .communicationRestricted
        case .racing: self = .racing
        }
    }

    public var wire: WireLobbyClosure {
        switch self {
        case .notSignedIn: .notSignedIn
        case .termsNotAccepted: .termsNotAccepted
        case .communicationRestricted: .communicationRestricted
        case .racing: .racing
        }
    }
}

extension LobbyState {
    public init(wire: WireLobbyState) {
        let standing: ChatStanding = switch wire.standing {
        case .clear: .clear
        case .muted(let until, let isAutomatic): .muted(until: until, isAutomatic: isAutomatic)
        case .banned: .banned
        }
        self.init(access: wire.closure.map { .closed(LobbyClosure(wire: $0)) } ?? .open, canPostFreeText: wire.canPostFreeText,
                  standing: standing)
    }

    public var wire: WireLobbyState {
        let closure: WireLobbyClosure? = if case .closed(let closure) = access { closure.wire } else { nil }
        let standing: WireChatStanding = switch standing {
        case .clear: .clear
        case .muted(let until, let isAutomatic): .muted(until: until, isAutomatic: isAutomatic)
        case .banned: .banned
        }
        return WireLobbyState(closure: closure, canPostFreeText: canPostFreeText, standing: standing)
    }
}

extension LobbyEvent {
    public init(wire: WireLobbyEvent) {
        switch wire {
        case .state(let state): self = .state(LobbyState(wire: state))
        case .message(let message): self = .message(LobbyMessage(wire: message))
        case .removed(let id): self = .removed(MessageID(id))
        }
    }

    public var wire: WireLobbyEvent {
        switch self {
        case .state(let state): .state(state.wire)
        case .message(let message): .message(message.wire)
        case .removed(let id): .removed(messageID: id.rawValue)
        }
    }
}

extension RaceReportReason {
    public init(wire: WireRaceReportReason) {
        switch wire {
        case .unsportingConduct: self = .unsportingConduct
        case .suspectedCheating: self = .suspectedCheating
        }
    }

    public var wire: WireRaceReportReason {
        switch self {
        case .unsportingConduct: .unsportingConduct
        case .suspectedCheating: .suspectedCheating
        }
    }
}

extension LobbyError {
    public init(wire: WireLobbyError) {
        switch wire {
        case .closed(let closure): self = .closed(LobbyClosure(wire: closure))
        case .freeTextLocked: self = .freeTextLocked
        case .empty: self = .empty
        case .tooLong(let limit): self = .tooLong(limit: limit)
        case .rateLimited(let seconds): self = .rateLimited(retryAfterSeconds: seconds)
        case .muted(let until): self = .muted(until: until)
        case .banned: self = .banned
        case .unknownMessage: self = .unknownMessage
        case .notReportable: self = .notReportable
        case .cannotBlockSelf: self = .cannotBlockSelf
        }
    }

    public var wire: WireLobbyError {
        switch self {
        case .closed(let closure): .closed(closure.wire)
        case .freeTextLocked: .freeTextLocked
        case .empty: .empty
        case .tooLong(let limit): .tooLong(limit: limit)
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .muted(let until): .muted(until: until)
        case .banned: .banned
        case .unknownMessage: .unknownMessage
        case .notReportable: .notReportable
        case .cannotBlockSelf: .cannotBlockSelf
        }
    }
}

// MARK: - Profile

extension Profile {
    public init(wire: WireProfile) {
        let suspension: RacingSuspension? = switch wire.suspension {
        case nil: nil
        case .permanent: RacingSuspension(until: nil)
        case .until(let until): RacingSuspension(until: until)
        }
        self.init(
            gamePlayerID: GamePlayerID(wire.gamePlayerID), nickname: wire.nickname, rating: Rating(wire: wire.rating),
            completedRaces: wire.completedRaces, wins: wire.wins, suspension: suspension,
            progress: EarnedProgress(earned: wire.earned.map(DesignID.init),
                                     next: wire.next.map { EarnedMilestone(design: DesignID($0.design), completedRaces: $0.completedRaces) }),
            livery: wire.livery)
    }

    public var wire: WireProfile {
        let suspension: WireProfile.Suspension? = suspension.map { $0.until.map(WireProfile.Suspension.until) ?? .permanent }
        return WireProfile(
            gamePlayerID: gamePlayerID.rawValue, nickname: nickname, rating: rating.wire, completedRaces: completedRaces, wins: wins,
            suspension: suspension, earned: progress.earned.map(\.rawValue),
            next: progress.next.map { WireMilestone(design: $0.design.rawValue, completedRaces: $0.completedRaces) }, livery: livery)
    }
}

extension LiveryProblem {
    public init(wire: WireLiveryProblem) {
        switch wire {
        case .sailNumber: self = .sailNumber
        case .slotCount: self = .slotCount
        case .colour: self = .colour
        case .unknownDesign: self = .unknownDesign
        case .notOwned: self = .notOwned
        }
    }

    public var wire: WireLiveryProblem {
        switch self {
        case .sailNumber: .sailNumber
        case .slotCount: .slotCount
        case .colour: .colour
        case .unknownDesign: .unknownDesign
        case .notOwned: .notOwned
        }
    }
}

// MARK: - Analytics and deletion

extension AnalyticsBatch {
    public init(wire: WireAnalyticsBatch) {
        self.init(installID: InstallID(wire.installID), events: wire.events.map { event in
            var properties: [String: AnalyticsValue] = [:]
            for property in event.properties {
                properties[property.key] = switch property.value {
                case .int(let v): .int(Int(truncatingIfNeeded: v))
                case .double(let v): .double(v)
                case .string(let v): .string(v)
                case .bool(let v): .bool(v)
                }
            }
            return AnalyticsEvent(sequence: event.sequence, name: AnalyticsEventName(event.name), time: event.time, properties: properties)
        })
    }

    /// Properties in key order (`WireAnalyticsEvent.keyPrecedes`), as the wire has them.
    public var wire: WireAnalyticsBatch {
        WireAnalyticsBatch(installID: installID.rawValue, events: events.map { event in
            let properties = event.properties.map { key, value in
                let wire: WireAnalyticsValue = switch value {
                case .int(let v): .int(Int64(v))
                case .double(let v): .double(v)
                case .string(let v): .string(v)
                case .bool(let v): .bool(v)
                }
                return WireAnalyticsProperty(key: key, value: wire)
            }
            return WireAnalyticsEvent(sequence: event.sequence, name: event.name.rawValue, time: event.time,
                                      properties: properties.sorted { WireAnalyticsEvent.keyPrecedes($0.key, $1.key) })
        })
    }
}

extension OnlineData {
    public init(wire: WireOnlineData) {
        switch wire {
        case .profile: self = .profile
        case .rating: self = .rating
        case .livery: self = .livery
        case .chatHistory: self = .chatHistory
        case .reportsFiled: self = .reportsFiled
        case .leaderboardEntry: self = .leaderboardEntry
        case .termsAcceptance: self = .termsAcceptance
        }
    }

    public var wire: WireOnlineData {
        switch self {
        case .profile: .profile
        case .rating: .rating
        case .livery: .livery
        case .chatHistory: .chatHistory
        case .reportsFiled: .reportsFiled
        case .leaderboardEntry: .leaderboardEntry
        case .termsAcceptance: .termsAcceptance
        }
    }
}

extension DeletionPlan {
    public init(wire: WireDeletionPlan) {
        self.init(deletes: Set(wire.deletes.map(OnlineData.init(wire:))), anonymisesRaceLogs: wire.anonymisesRaceLogs,
                  confirmation: DeletionConfirmation(token: wire.confirmation))
    }

    /// The kinds in code order, as the wire has them.
    public var wire: WireDeletionPlan {
        WireDeletionPlan(deletes: WireOnlineData.allCases.filter { deletes.contains(OnlineData(wire: $0)) },
                         anonymisesRaceLogs: anonymisesRaceLogs, confirmation: confirmation.token)
    }
}
