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
            incidents: [SeatIncidents(seat: 0, incidents: [incident])], isClosed: isClosed)
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
