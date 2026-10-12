import RegattaCore
import RegattaProtocol

/// Every client service, as the app holds them (#242). Until the real services (#161–#166) exist, the app runs on
/// `unconnected(connectivity:)`, or on a `FakeServiceScenario` for UI tests.
public struct ServiceSet: Sendable {
    public var identity: any IdentityService
    public var terms: any TermsService
    public var queue: any QueueService
    public var raceSession: any RaceSessionService
    public var lobby: any LobbyService
    public var profile: any ProfileService
    public var store: any StoreService
    public var analytics: any AnalyticsTransport
    public var connectivity: any ConnectivityService
    public var deletion: any DataDeletionService

    public init(
        identity: any IdentityService, terms: any TermsService, queue: any QueueService, raceSession: any RaceSessionService,
        lobby: any LobbyService, profile: any ProfileService, store: any StoreService, analytics: any AnalyticsTransport,
        connectivity: any ConnectivityService, deletion: any DataDeletionService
    ) {
        self.identity = identity
        self.terms = terms
        self.queue = queue
        self.raceSession = raceSession
        self.lobby = lobby
        self.profile = profile
        self.store = store
        self.analytics = analytics
        self.connectivity = connectivity
        self.deletion = deletion
    }

    /// What the app runs on before the real services: the device's own connectivity, and a player who is signed out
    /// with nothing online, as the home screen's placeholders showed (#108).
    public static func unconnected(connectivity: any ConnectivityService) -> ServiceSet {
        var set = fake(.signedOut)
        set.connectivity = connectivity
        return set
    }

    /// The scripted fakes in `scenario`, all telling the same story. `wait` paces the online results scenarios
    /// (`FakeServiceScenario.onlineResultsPacing` apart); without it their updates all come at once.
    public static func fake(_ scenario: FakeServiceScenario,
                            wait: (@Sendable (Duration) async -> Void)? = nil) -> ServiceSet {
        FakeServiceScenario.Story(scenario, wait: wait).services
    }
}

/// The app's `-fakeServices <scenario>` (#242): a client-visible state of the online services (#16, #17, #26, #34),
/// played by the scripted fakes, for UI tests. The raw value is what the launch argument takes.
public enum FakeServiceScenario: String, CaseIterable, Sendable {
    /// Game Center has no player; signing in gives one.
    case signedOut = "signed-out"
    /// Game Center's `isUnderage`: chat hidden.
    case underage
    /// `isPersonalizedCommunicationRestricted`: chat hidden.
    case communicationRestricted = "communication-restricted"
    /// `isMultiplayerGamingRestricted`: practice races only.
    case multiplayerRestricted = "multiplayer-restricted"
    /// No network.
    case offline
    /// Signed in and queued: the countdown runs to fleet lock, and the race session hands off a seat and its briefing.
    case queued
    /// Signed in, with a race the server cancels before the close.
    case cancelledRace = "cancelled-race"
    /// Signed in, in a rated six-boat race (you, two other humans, three bots) whose results fill in live: a boat
    /// finishes every `onlineResultsPacing`, then the race closes, then the rating change is pushed (#133). One
    /// call against you, its turn done.
    case onlineResults = "online-results"
    /// As `onlineResults`, but every other boat is a bot: unrated (#133).
    case onlineResultsUnrated = "online-results-unrated"
    /// Signed in, having accepted the terms' version 1 when version 2 is current: the sheet asks again (#34, #138).
    case termsBump = "terms-bump"
    /// Signed in, suspended from online racing until a day (#26): Race online says until when (#161).
    case suspended
    /// Suspended for good.
    case suspendedPermanent = "suspended-permanent"
    /// Signed in, in the briefing-leave cooldown (#26): Race online counts it down (#161).
    case cooldown
    /// Signed in, refused the queue for a reason she isn't told (a failed attestation, #147).
    case cannotRace = "cannot-race"
    /// Signed in on a build the server no longer takes.
    case updateRequired = "update-required"
    /// Signed out, and signing in gives a player whose I agree can't be saved (#161).
    case termsSaveFailed = "terms-save-failed"
    /// Game Center has a player on the phone but the server won't sign her in (#161). These fakes are signed out and
    /// stay so; the app plays the session over them, as for `unreachable` and `connecting`.
    case sessionFailed = "session-failed"
    /// Game Center has a player on the phone but the server doesn't answer (#161).
    case unreachable
    /// Game Center has a player on the phone and the server is taking its time to answer (#161).
    case connecting
    /// Signed in and free to join (#140). After a join: one waiting, then three, then four with the lock close, the
    /// fleet being set, and fleet lock, with a seat and its briefing to hand off.
    case joinable
    /// As `joinable`, with nobody else in the queue.
    case joinableAlone = "joinable-alone"
    /// As `joinable`, joined while a running race is about to finish: the lock is held back, then counts down.
    case joinableHold = "joinable-hold"
    /// Signed in, dropped from a race that is still running (#141): the app's fake race session offers the way back.
    case rejoinable
    /// As `joinable`, but the race server never answers after fleet lock (#141).
    case raceGone = "race-gone"

    /// When the `suspended` scenario's suspension ends, in seconds since the epoch: noon UTC on 14 October 2037.
    public static let suspendedUntil: Int64 = 2_139_134_400
    /// The `cooldown` scenario's seconds to go when its queue state is first read.
    public static let cooldownSeconds = 252

    /// The seconds the queue's hold scenario starts its wait at: more than a countdown alone ever shows (#16, G2).
    public static let holdSeconds = 150

    /// What the scenario's queue says after a join (#140): the wait, fleet lock, and then idle again, since the fakes
    /// sail no race and the queue is free for the next join. Every scenario whose player can get past Race online's
    /// gate has a queue to join (`joinable`'s, unless it is one of the other two); the ones the server refuses, and
    /// the ones that never open a session, have none.
    public var afterJoin: [QueueState] {
        func queued(_ players: Int, _ seconds: Int) -> QueueState {
            .queued(QueuedStatus(queuedPlayers: players, secondsToLock: seconds))
        }
        switch self {
        case .joinableAlone: return [queued(1, 40), queued(1, 25), queued(1, 8), queued(1, 0), .fleetLocked, .idle]
        case .joinableHold:
            return [queued(3, Self.holdSeconds), queued(3, 120), queued(4, 90), queued(4, 60), queued(4, 30), queued(4, 8),
                    queued(4, 0), .fleetLocked, .idle]
        case .queued, .suspended, .suspendedPermanent, .cooldown, .cannotRace, .updateRequired, .multiplayerRestricted,
             .termsSaveFailed, .sessionFailed, .unreachable, .connecting:
            return []
        case .joinable, .rejoinable, .raceGone, .signedOut, .underage, .communicationRestricted, .offline, .cancelledRace, .onlineResults,
             .onlineResultsUnrated, .termsBump:
            return [queued(1, 40), queued(3, 25), queued(4, 8), queued(4, 0), .fleetLocked, .idle]
        }
    }

    /// The briefing every scenario with a queue to join, and `queued`, hands off at fleet lock (#140, #147): six seats on the bundled
    /// defaults, the player in seat 0, three other humans and two bots.
    public static func briefing() -> BriefingPayload {
        let names = [Story.player.alias, "Wren", "Kestrel", "Tern", "Skua", "Petrel"]
        let bots: Set<Int> = [4, 5]
        let setup = try! RaceSetup(raceSeed: RaceSeed(140), seats: names.indices.map { bots.contains($0) ? .bot : .human })
        let liveries = names.indices.map { seat in
            seat == 0 ? Story.livery
                : Story.catalogue.botLivery(boatClass: setup.boatClass.id, seed: UInt64(seat) &* 0x9E37_79B9_7F4A_7C15) ?? Story.livery
        }
        let numbers = LiveryCatalogue.raceSailNumbers(liveries.map(\.sailNumber))
        let fleet = names.indices.map { seat in
            var livery = liveries[seat]
            livery.sailNumber = numbers[seat]
            return BriefingSeat(name: names[seat], isBot: bots.contains(seat), livery: livery, rating: bots.contains(seat) ? nil : 1500)
        }
        return BriefingPayload(setup: setup, fleet: fleet, yourSeat: 0, briefingSeconds: 15, gunInSeconds: 75)
    }

    /// Whether the scenario's player is signed in from the start.
    public var startsSignedIn: Bool {
        switch self {
        case .signedOut, .termsSaveFailed, .sessionFailed, .unreachable, .connecting: false
        default: true
        }
    }

    /// Whether the app plays an online session over the scenario's fakes (#161): the session's own states, which no
    /// service says.
    public var playsSession: Bool { self == .sessionFailed || self == .unreachable || self == .connecting }

    /// How far apart the online results scenarios' updates come.
    public static let onlineResultsPacing = Duration.milliseconds(1500)

    /// The seats the scenario's race gives to bots: the roster doesn't say (`RosterEntry`), the race transport does.
    public var raceBotSeats: [Int] {
        switch self {
        case .onlineResults: [3, 4, 5]
        case .onlineResultsUnrated: [1, 2, 3, 4, 5]
        default: [1]
        }
    }

    /// The online results scenarios' race (#133): seat 0 is the player. Boats finish one by one, the race closes
    /// with two boats placed by distance, then the rating follows.
    public static func onlineRace(rated: Bool, pacing: RaceSessionPacing? = nil) -> RaceSessionScenario {
        let player = Story.player
        let names = rated
            ? [player.alias, "Wren", "Kestrel", "Tern", "Skua", "Petrel"]
            : [player.alias, "Gannet", "Kestrel", "Tern", "Skua", "Petrel"]
        let roster = names.enumerated().map { RosterEntry(name: $1, colorIndex: $0) }
        let call = RuleCall(incidentId: 0, tick: 2400, rule: .portStarboard, offender: 0, victim: 1, leg: 0, turnsOwed: 1,
                            startDeadlineTick: nil, completeDeadlineTick: nil)
        let mine = SeatIncidents(
            seat: 0, incidents: [Incident(id: 0, tick: 2400, leg: 0, parties: SeatPair(0, 1), outcome: .called(call))],
            turnsServed: 1)
        let finishes = [
            SeatResult(seat: 3, place: 1, code: .finished, finishTick: 9000),
            SeatResult(seat: 1, place: 2, code: .finished, finishTick: 9150),
            SeatResult(seat: 0, place: 3, code: .finished, finishTick: 9420),
            SeatResult(seat: 4, place: 4, code: .finished, finishTick: 9600),
        ]
        let atClose = finishes + [SeatResult(seat: 2, place: 5, code: .byDistance), SeatResult(seat: 5, place: 6, code: .byDistance)]
        func report(_ rows: [SeatResult], isClosed: Bool) -> RaceReport {
            let scored = Set(rows.map(\.seat))
            return RaceReport(
                raceID: Story.race, seat: 0, roster: roster, results: RaceResults(rows: rows, rated: rated),
                sailing: roster.indices.filter { !scored.contains($0) }, incidents: [mine], isClosed: isClosed,
                flaggedSeats: [0])
        }
        let reports = (1...finishes.count).map { report(Array(finishes.prefix($0)), isClosed: false) } + [report(atClose, isClosed: true)]
        let rating = RatingChange(raceID: Story.race, outcome: rated
            ? .rated(before: Rating(value: 1500, isProvisional: true), after: Rating(value: 1512, isProvisional: true))
            : .unrated)
        return RaceSessionScenario(
            results: reports.map(RaceUpdate.report), ratingChanges: [rating],
            lastRace: LastRace(report: reports[reports.count - 1], rating: rating), pacing: pacing)
    }

    /// The fakes for one scenario, built from the same player.
    struct Story {

        let services: ServiceSet

        static let player = GameCenterPlayer(gamePlayerID: GamePlayerID("G:fake-1"), alias: "Sailor")
        static let other = GamePlayerID("G:fake-2")
        static let terms = TermsVersion(1)
        static let race = RaceID("fake-race")
        static let livery = Livery(design: DesignID("skiff-plain"), colours: [SwatchID("sky-blue"), SwatchID("white")], sailNumber: 207)
        static let chip = LiveryChip(deck: SwatchID("sky-blue"), sail: SwatchID("white"))
        /// The bundled livery catalogue (#118), which RegattaCore always ships.
        static let catalogue = try! LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1).content

        init(_ scenario: FakeServiceScenario, wait: (@Sendable (Duration) async -> Void)? = nil) {
            var player = Self.player
            switch scenario {
            case .underage: player.isUnderage = true
            case .communicationRestricted: player.isPersonalizedCommunicationRestricted = true
            case .multiplayerRestricted: player.isMultiplayerGamingRestricted = true
            default: break
            }
            let signedIn = scenario.startsSignedIn

            let identity = ScriptedIdentityService(signedIn
                ? IdentityScenario(initial: .signedIn(player))
                : IdentityScenario(initial: .signedOut, afterSignIn: scenario.playsSession ? .signedOut : .signedIn(player)))
            let terms = ScriptedTermsService(scenario == .termsBump
                ? TermsScenario(current: TermsVersion(Self.terms.rawValue + 1), accepted: Self.terms)
                : TermsScenario(current: Self.terms, accepted: signedIn ? Self.terms : nil, saves: scenario != .termsSaveFailed))

            let queue: ScriptedQueueService
            let raceSession: ScriptedRaceSessionService
            switch scenario {
            case .signedOut, .termsSaveFailed, .sessionFailed, .unreachable, .connecting:
                // Signed in and agreed, `signed-out`'s player joins the queue (#140).
                queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.notSignedIn), afterJoin: scenario.afterJoin,
                                                           admitsAtJoin: scenario == .signedOut))
            case .suspended:
                queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.suspended(until: FakeServiceScenario.suspendedUntil))))
            case .suspendedPermanent: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.suspended(until: nil))))
            case .cooldown:
                queue = ScriptedQueueService(QueueScenario(
                    initial: .unavailable(.cooldown(secondsRemaining: FakeServiceScenario.cooldownSeconds))))
            case .cannotRace: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.attestationFailed)))
            case .updateRequired: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.updateRequired)))
            case .multiplayerRestricted: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.multiplayerRestricted)))
            case .queued:
                queue = ScriptedQueueService(QueueScenario(
                    initial: .queued(QueuedStatus(queuedPlayers: 6, secondsToLock: 30)),
                    background: [.queued(QueuedStatus(queuedPlayers: 9, secondsToLock: 15)),
                                 .queued(QueuedStatus(queuedPlayers: 11, secondsToLock: 5)), .fleetLocked]))
            default: queue = ScriptedQueueService(QueueScenario(initial: .idle, afterJoin: scenario.afterJoin))
            }
            // The seat a fleet lock hands off, and its briefing.
            let handOff = scenario == .queued || !scenario.afterJoin.isEmpty
                ? HandOff(raceID: Self.race, token: RaceToken(bytes: [0xF0, 0x0D]), briefing: FakeServiceScenario.briefing()) : nil
            switch scenario {
            case .cancelledRace:
                let partial = RaceReport(
                    raceID: Self.race, seat: 0, roster: [RosterEntry(name: player.alias, colorIndex: 0), RosterEntry(name: "Bot Tern", colorIndex: 1)],
                    results: RaceResults(rows: [], rated: true), sailing: [0, 1], incidents: [], isClosed: false)
                raceSession = ScriptedRaceSessionService(RaceSessionScenario(
                    handOff: handOff, results: [.report(partial), .cancelled(.serverShutdown)]))
            case .onlineResults, .onlineResultsUnrated:
                let pacing = wait.map { RaceSessionPacing(interval: FakeServiceScenario.onlineResultsPacing, wait: $0) }
                var race = FakeServiceScenario.onlineRace(rated: scenario == .onlineResults, pacing: pacing)
                race.handOff = handOff
                raceSession = ScriptedRaceSessionService(race)
            default: raceSession = ScriptedRaceSessionService(RaceSessionScenario(handOff: handOff))
            }

            let me = LobbyAuthor(gamePlayerID: player.gamePlayerID, nickname: player.alias,
                                 rating: Rating(value: 1500, isProvisional: true), chip: Self.chip)
            let access: LobbyAccess = !signedIn ? .closed(.notSignedIn) : !player.canChat ? .closed(.communicationRestricted)
                : scenario == .termsBump ? .closed(.termsNotAccepted) : .open
            let lobby = ScriptedLobbyService(LobbyScenario(
                player: me, state: LobbyState(access: access, canPostFreeText: false),
                history: [
                    LobbyMessage(id: MessageID("fake-1"), kind: .system(.gun(venue: "Dev venue", boats: 10, humans: 2))),
                    LobbyMessage(id: MessageID("fake-2"), kind: .post(LobbyPost(
                        author: LobbyAuthor(gamePlayerID: Self.other, nickname: "Wren", rating: Rating(value: 1610, isProvisional: false), chip: Self.chip),
                        body: .quickChat(.oneMore)))),
                ],
                races: [Self.race: (0..<6).map { seat in
                    seat == 0 ? .player : scenario.raceBotSeats.contains(seat) ? .bot : .human(GamePlayerID("G:fake-\(seat + 1)"))
                }]))

            let profile = ScriptedProfileService(ProfileScenario(
                profile: signedIn ? Profile(
                    gamePlayerID: player.gamePlayerID, nickname: player.alias, rating: me.rating, completedRaces: 0, wins: 0, suspension: nil,
                    progress: EarnedProgress(earned: [], next: EarnedMilestone(design: DesignID("skiff-earned-10"), completedRaces: 10)),
                    livery: Self.livery) : nil,
                catalogue: Self.catalogue))
            let isOnline = scenario != .offline
            let store = ScriptedStoreService(StoreScenario(
                products: [StoreProduct(id: ProductID("com.phillreeder.regatta.skiff.chevron-sail"), design: DesignID("skiff-chevron-sail"),
                                        boatClass: "skiff", tier: .tier2, displayPrice: "$1.99")],
                isOnline: isOnline))
            services = ServiceSet(
                identity: identity, terms: terms, queue: queue, raceSession: raceSession, lobby: lobby, profile: profile, store: store,
                analytics: ScriptedAnalyticsTransport(isAvailable: isOnline),
                connectivity: ScriptedConnectivityService(isOnline ? .online : .offline),
                deletion: ScriptedDataDeletionService(DataDeletionScenario(isSignedIn: signedIn, held: [], hasRaced: false)))
        }
    }
}
