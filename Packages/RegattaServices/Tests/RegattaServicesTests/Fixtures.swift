import RegattaCore
import RegattaProtocol
import RegattaServiceContracts
import RegattaServices

/// The scripted fakes, put in each contract suite's situations. Which scenario is which situation is the
/// test's business, not the fake's: #242 names its own scenarios for the app.
enum Fixtures {
    static let ana = GameCenterPlayer(gamePlayerID: GamePlayerID("G:1001"), alias: "Ana")

    static func identity(_ situation: IdentityServiceContract.Situation) -> ScriptedIdentityService {
        switch situation {
        case .signedOut: ScriptedIdentityService(IdentityScenario(initial: .signedOut, afterSignIn: .signedIn(ana)))
        case .signedIn: ScriptedIdentityService(IdentityScenario(initial: .signedIn(ana)))
        case .multiplayerRestricted:
            ScriptedIdentityService(IdentityScenario(initial: .signedIn(
                GameCenterPlayer(gamePlayerID: GamePlayerID("G:1002"), alias: "Kit", isMultiplayerGamingRestricted: true))))
        }
    }

    static func terms(_ situation: TermsServiceContract.Situation) -> ScriptedTermsService {
        switch situation {
        case .neverAccepted: ScriptedTermsService(TermsScenario(current: TermsVersion(2)))
        case .accepted: ScriptedTermsService(TermsScenario(current: TermsVersion(2), accepted: TermsVersion(2)))
        case .versionBumped: ScriptedTermsService(TermsScenario(current: TermsVersion(3), accepted: TermsVersion(2)))
        }
    }

    static func queue(_ situation: QueueServiceContract.Situation) -> ScriptedQueueService {
        let waiting: [QueueState] = [
            .queued(QueuedStatus(queuedPlayers: 3, secondsToLock: 40)),
            .queued(QueuedStatus(queuedPlayers: 9, secondsToLock: 20)),
            .queued(QueuedStatus(queuedPlayers: 12, secondsToLock: 8)),
            .fleetLocked,
        ]
        switch situation {
        case .joinable: return ScriptedQueueService(QueueScenario(initial: .idle, afterJoin: waiting))
        case .cooldown:
            return ScriptedQueueService(QueueScenario(
                initial: .unavailable(.cooldown(secondsRemaining: 3)),
                background: [.unavailable(.cooldown(secondsRemaining: 2)), .unavailable(.cooldown(secondsRemaining: 1)), .idle],
                afterJoin: waiting))
        case .suspended:
            return ScriptedQueueService(QueueScenario(initial: .unavailable(.suspended(until: 1_800_000_000))))
        case .notSignedIn: return ScriptedQueueService(QueueScenario(initial: .unavailable(.notSignedIn)))
        case .termsNotAccepted: return ScriptedQueueService(QueueScenario(initial: .unavailable(.termsNotAccepted)))
        case .multiplayerRestricted: return ScriptedQueueService(QueueScenario(initial: .unavailable(.multiplayerRestricted)))
        }
    }

    // MARK: Race session

    static let race = RaceID("race-7")
    static let handOff = HandOff(raceID: race, token: RaceToken(bytes: [0xA1, 0xB2, 0xC3]))
    /// Seat 0 is the player.
    static let roster = [
        RosterEntry(name: "Ana", colorIndex: 0), RosterEntry(name: "Wren", colorIndex: 1),
        RosterEntry(name: "Bot Marlin", colorIndex: 2), RosterEntry(name: "Bot Skua", colorIndex: 3),
    ]

    /// The player (seat 0) was called against by seat 1 at the first mark.
    static let incident = Incident(
        id: 0, tick: 600, leg: 0, parties: SeatPair(0, 1),
        outcome: .called(RuleCall(
            incidentId: 0, tick: 600, rule: .portStarboard, offender: 0, victim: 1, leg: 0, turnsOwed: 1,
            startDeadlineTick: nil, completeDeadlineTick: nil)))

    static func report(rows: [SeatResult], sailing: [Int], isClosed: Bool) -> RaceReport {
        RaceReport(
            raceID: race, seat: 0, roster: roster, results: RaceResults(rows: rows, rated: true), sailing: sailing,
            incidents: [SeatIncidents(
                seat: 0, incidents: [incident], markTouches: [MarkTouch(tick: 700, leg: 0, seat: 0, mark: "Windward")],
                protests: [Protest(tick: 610, leg: 0, protester: 0, protested: 1, matchedIncidentId: 0)], turnsServed: 1)],
            isClosed: isClosed, flaggedSeats: [0])
    }

    /// Seat 2 finishes, then the player, and at the close one boat is placed by distance and one retired.
    static let reports = [
        report(rows: [SeatResult(seat: 2, place: 1, code: .finished, finishTick: 9000)], sailing: [0, 1, 3], isClosed: false),
        report(
            rows: [SeatResult(seat: 2, place: 1, code: .finished, finishTick: 9000), SeatResult(seat: 0, place: 2, code: .finished, finishTick: 9300)],
            sailing: [1, 3], isClosed: false),
        report(
            rows: [
                SeatResult(seat: 2, place: 1, code: .finished, finishTick: 9000), SeatResult(seat: 0, place: 2, code: .finished, finishTick: 9300),
                SeatResult(seat: 1, place: 3, code: .byDistance), SeatResult(seat: 3, place: 4, code: .ret),
            ],
            sailing: [], isClosed: true),
    ]
    static let rating = RatingChange(
        raceID: race, outcome: .rated(before: Rating(value: 1500, isProvisional: true), after: Rating(value: 1512, isProvisional: true)))

    static func raceSession(_ situation: RaceSessionServiceContract.Situation) -> ScriptedRaceSessionService {
        switch situation {
        case .fleetLocked: ScriptedRaceSessionService(RaceSessionScenario(handOff: handOff))
        case .inProgress:
            ScriptedRaceSessionService(RaceSessionScenario(rejoin: RejoinOffer(
                handOff: HandOff(raceID: race, token: RaceToken(bytes: [0xD4, 0xE5])), seat: 0,
                clock: RaceClockReading(tick: 3600, expectedCloseTick: 9600))))
        case .closed:
            ScriptedRaceSessionService(RaceSessionScenario(
                results: reports.map(RaceUpdate.report), ratingChanges: [rating],
                lastRace: LastRace(report: reports[2], rating: rating)))
        case .cancelled:
            ScriptedRaceSessionService(RaceSessionScenario(results: [.report(reports[0]), .cancelled(.serverShutdown)]))
        case .noRace: ScriptedRaceSessionService(RaceSessionScenario())
        }
    }
}

// MARK: - #241: lobby, profile, store, analytics, connectivity, deletion

extension Fixtures {
    /// The bundled livery catalogue (#118): the designs and safe palette a stored livery is checked against.
    static let catalogue = try! LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1).content
    static let starter = DesignID("skiff-plain")
    static let earned10 = DesignID("skiff-earned-10")
    static let earned50 = DesignID("skiff-earned-50")
    static let paid = DesignID("skiff-pinstripe")
    static let paidWave = DesignID("skiff-band")
    static let livery = Livery(design: starter, colours: [SwatchID("sky-blue"), SwatchID("white")], sailNumber: 4127)

    static func author(_ id: String, _ nickname: String, rating: Int = 1500) -> LobbyAuthor {
        LobbyAuthor(gamePlayerID: GamePlayerID(id), nickname: nickname, rating: Rating(value: rating, isProvisional: rating == 1500),
                    chip: LiveryChip(deck: SwatchID("charcoal"), sail: SwatchID("white")))
    }

    static let me = author("G:1001", "Ana", rating: 1532)
    static let wren = author("G:2002", "Wren", rating: 1610)
    static let lobbyHistory: [LobbyMessage] = [
        LobbyMessage(id: MessageID("m1"), kind: .system(.gun(venue: "Dev venue", boats: 10, humans: 3))),
        LobbyMessage(id: MessageID("m2"), kind: .post(LobbyPost(author: wren, body: .text("anyone for one more?")))),
        LobbyMessage(id: MessageID("m3"), kind: .post(LobbyPost(author: wren, body: .quickChat(.gg)))),
        LobbyMessage(id: MessageID("m4"), kind: .system(.winner(venue: "Dev venue", nickname: "Wren"))),
    ]

    static func lobby(_ situation: LobbyServiceContract.Situation) -> ScriptedLobbyService {
        func scenario(_ state: LobbyState, background: [LobbyEvent] = []) -> LobbyScenario {
            LobbyScenario(
                player: me, state: state, history: lobbyHistory, background: background,
                filteredWords: [LobbyServiceContract.filteredText],
                races: [LobbyServiceContract.race: [.player, .human(wren.gamePlayerID), .bot]])
        }
        let open = LobbyState(access: .open, canPostFreeText: true)
        return switch situation {
        case .open:
            ScriptedLobbyService(scenario(open, background: [
                .message(LobbyMessage(id: MessageID("m5"), kind: .post(LobbyPost(author: wren, body: .text("still here?"))))),
            ]))
        case .freeTextLocked: ScriptedLobbyService(scenario(LobbyState(access: .open, canPostFreeText: false)))
        case .muted: ScriptedLobbyService(scenario(LobbyState(access: .open, canPostFreeText: true, standing: .muted(until: 1_790_086_400, isAutomatic: true))))
        case .banned: ScriptedLobbyService(scenario(LobbyState(access: .open, canPostFreeText: true, standing: .banned)))
        case .racing:
            ScriptedLobbyService(scenario(
                LobbyState(access: .closed(.racing), canPostFreeText: true),
                background: [.state(open), .message(LobbyMessage(id: MessageID("m5"), kind: .post(LobbyPost(author: wren, body: .quickChat(.goodRace)))))]))
        case .notSignedIn: ScriptedLobbyService(scenario(LobbyState(access: .closed(.notSignedIn), canPostFreeText: false)))
        case .termsNotAccepted: ScriptedLobbyService(scenario(LobbyState(access: .closed(.termsNotAccepted), canPostFreeText: false)))
        case .communicationRestricted: ScriptedLobbyService(scenario(LobbyState(access: .closed(.communicationRestricted), canPostFreeText: true)))
        }
    }

    static func profile(races: Int, wins: Int, suspension: RacingSuspension? = nil) -> Profile {
        let milestones = [EarnedMilestone(design: earned10, completedRaces: 10), EarnedMilestone(design: earned50, completedRaces: 50)]
        return Profile(
            gamePlayerID: me.gamePlayerID, nickname: me.nickname, rating: Rating(value: races == 0 ? 1500 : 1532, isProvisional: races < 10),
            completedRaces: races, wins: wins, suspension: suspension,
            progress: EarnedProgress(earned: milestones.filter { $0.completedRaces <= races }.map(\.design),
                                     next: milestones.first { $0.completedRaces > races }),
            livery: livery)
    }

    static func profile(_ situation: ProfileServiceContract.Situation) -> ScriptedProfileService {
        func service(_ profile: Profile?, locked: Bool = false) -> ScriptedProfileService {
            ScriptedProfileService(ProfileScenario(profile: profile, catalogue: catalogue, unowned: [paid, paidWave], isLiveryLocked: locked))
        }
        return switch situation {
        case .signedOut: service(nil)
        case .newPlayer: service(profile(races: 0, wins: 0))
        case .established: service(profile(races: 32, wins: 4))
        case .suspended: service(profile(races: 32, wins: 4, suspension: RacingSuspension(until: 1_790_086_400)))
        case .banned: service(profile(races: 32, wins: 4, suspension: RacingSuspension(until: nil)))
        case .liveryLocked: service(profile(races: 32, wins: 4), locked: true)
        }
    }

    static let products = [
        StoreProduct(id: ProductID("com.phillreeder.regatta.skiff.pinstripe"), design: paid, boatClass: "skiff", tier: .tier1, displayPrice: "$0.99"),
        StoreProduct(id: ProductID("com.phillreeder.regatta.skiff.band"), design: paidWave, boatClass: "skiff", tier: .tier1, displayPrice: "$0.99"),
    ]

    static func store(_ situation: StoreServiceContract.Situation) -> ScriptedStoreService {
        switch situation {
        case .nothingOwned: ScriptedStoreService(StoreScenario(products: products))
        case .askToBuyApproved: ScriptedStoreService(StoreScenario(products: products, checkout: .askToBuy(approved: true)))
        case .cancels: ScriptedStoreService(StoreScenario(products: products, checkout: .cancels))
        case .refunded: ScriptedStoreService(StoreScenario(products: products, owned: [paid, paidWave], background: [[paidWave]]))
        case .offline: ScriptedStoreService(StoreScenario(products: products, owned: [paid], isOnline: false))
        }
    }

    static func analytics(_ situation: AnalyticsTransportContract.Situation) -> ScriptedAnalyticsTransport {
        ScriptedAnalyticsTransport(isAvailable: situation == .accepting)
    }

    static func connectivity(_ situation: ConnectivityServiceContract.Situation) -> ScriptedConnectivityService {
        switch situation {
        case .online: ScriptedConnectivityService(.online)
        case .offline: ScriptedConnectivityService(.offline)
        // The repeat shows the stream drops it.
        case .dropsAndRecovers: ScriptedConnectivityService(.online, changes: [.offline, .offline, .online])
        }
    }

    static func deletion(_ situation: DataDeletionServiceContract.Situation) -> ScriptedDataDeletionService {
        switch situation {
        case .hasOnlineData: ScriptedDataDeletionService(DataDeletionScenario(held: Set(OnlineData.allCases), hasRaced: true))
        case .nothingHeld: ScriptedDataDeletionService(DataDeletionScenario(held: [], hasRaced: false))
        case .signedOut: ScriptedDataDeletionService(DataDeletionScenario(isSignedIn: false, held: Set(OnlineData.allCases), hasRaced: true))
        }
    }
}
