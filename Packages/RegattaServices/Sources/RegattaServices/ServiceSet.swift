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
    /// Signed in and queued: the countdown runs to fleet lock, and the race session hands off a seat.
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
            let signedIn = scenario != .signedOut

            let identity = ScriptedIdentityService(signedIn
                ? IdentityScenario(initial: .signedIn(player))
                : IdentityScenario(initial: .signedOut, afterSignIn: .signedIn(player)))
            let terms = ScriptedTermsService(scenario == .termsBump
                ? TermsScenario(current: TermsVersion(Self.terms.rawValue + 1), accepted: Self.terms)
                : TermsScenario(current: Self.terms, accepted: signedIn ? Self.terms : nil))

            let queue: ScriptedQueueService
            let raceSession: ScriptedRaceSessionService
            switch scenario {
            case .signedOut: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.notSignedIn)))
            case .multiplayerRestricted: queue = ScriptedQueueService(QueueScenario(initial: .unavailable(.multiplayerRestricted)))
            case .queued:
                queue = ScriptedQueueService(QueueScenario(
                    initial: .queued(QueuedStatus(queuedPlayers: 6, secondsToLock: 30)),
                    background: [.queued(QueuedStatus(queuedPlayers: 9, secondsToLock: 15)),
                                 .queued(QueuedStatus(queuedPlayers: 11, secondsToLock: 5)), .fleetLocked]))
            default: queue = ScriptedQueueService(QueueScenario(initial: .idle))
            }
            switch scenario {
            case .queued:
                raceSession = ScriptedRaceSessionService(RaceSessionScenario(
                    handOff: HandOff(raceID: Self.race, token: RaceToken(bytes: [0xF0, 0x0D]))))
            case .cancelledRace:
                let partial = RaceReport(
                    raceID: Self.race, seat: 0, roster: [RosterEntry(name: player.alias, colorIndex: 0), RosterEntry(name: "Bot Tern", colorIndex: 1)],
                    results: RaceResults(rows: [], rated: true), sailing: [0, 1], incidents: [], isClosed: false)
                raceSession = ScriptedRaceSessionService(RaceSessionScenario(results: [.report(partial), .cancelled(.serverShutdown)]))
            case .onlineResults, .onlineResultsUnrated:
                let pacing = wait.map { RaceSessionPacing(interval: FakeServiceScenario.onlineResultsPacing, wait: $0) }
                raceSession = ScriptedRaceSessionService(
                    FakeServiceScenario.onlineRace(rated: scenario == .onlineResults, pacing: pacing))
            default: raceSession = ScriptedRaceSessionService(RaceSessionScenario())
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
