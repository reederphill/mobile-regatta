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

    /// The scripted fakes in `scenario`, all telling the same story.
    public static func fake(_ scenario: FakeServiceScenario) -> ServiceSet {
        FakeServiceScenario.Story(scenario).services
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

        init(_ scenario: FakeServiceScenario) {
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
            let terms = ScriptedTermsService(TermsScenario(current: Self.terms, accepted: signedIn ? Self.terms : nil))

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
            default: raceSession = ScriptedRaceSessionService(RaceSessionScenario())
            }

            let me = LobbyAuthor(gamePlayerID: player.gamePlayerID, nickname: player.alias,
                                 rating: Rating(value: 1500, isProvisional: true), chip: Self.chip)
            let access: LobbyAccess = !signedIn ? .closed(.notSignedIn) : player.canChat ? .open : .closed(.communicationRestricted)
            let lobby = ScriptedLobbyService(LobbyScenario(
                player: me, state: LobbyState(access: access, canPostFreeText: false),
                history: [
                    LobbyMessage(id: MessageID("fake-1"), kind: .system(.gun(venue: "Dev venue", boats: 10, humans: 2))),
                    LobbyMessage(id: MessageID("fake-2"), kind: .post(LobbyPost(
                        author: LobbyAuthor(gamePlayerID: Self.other, nickname: "Wren", rating: Rating(value: 1610, isProvisional: false), chip: Self.chip),
                        body: .quickChat(.oneMore)))),
                ]))

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
