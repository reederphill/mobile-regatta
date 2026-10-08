import RegattaCore
import RegattaServiceContracts
import RegattaServices
import Testing

/// The seam (#109): a suite takes any conforming implementation. A second, hand-written one passes, and
/// implementations each broken in one way, wrapping the fakes, fail with the check they broke.
@Suite struct ContractSeamTests {
    /// Runs `body` and returns the violation it threw, failing the test if it passed or threw something else.
    static func violation(_ body: () async throws -> Void) async -> ContractViolation? {
        do {
            try await body()
            Issue.record("the suite passed a broken implementation")
        } catch let violation as ContractViolation {
            return violation
        } catch {
            Issue.record("the suite threw \(error), not a ContractViolation")
        }
        return nil
    }

    @Test func suiteRunsAgainstAnyConformingImplementation() async throws {
        // A conforming implementation that shares nothing with the fake passes...
        try await TermsServiceContract().run { situation in
            switch situation {
            case .neverAccepted: MinimalTerms(current: 5, accepted: nil)
            case .accepted: MinimalTerms(current: 5, accepted: 5)
            case .versionBumped: MinimalTerms(current: 6, accepted: 5)
            }
        }

        // ... and each broken one fails, saying which check.
        let terms = await Self.violation {
            try await TermsServiceContract().run { BrokenTerms(base: Fixtures.terms($0)) }
        }
        #expect(terms?.suite == "TermsService")
        #expect(terms?.message.contains("accept(") == true)

        let identity = await Self.violation {
            try await IdentityServiceContract().run { BrokenIdentity(base: Fixtures.identity($0)) }
        }
        #expect(identity?.message.contains("identitySignature() while signed out") == true)

        let queue = await Self.violation {
            try await QueueServiceContract().run { BrokenQueue(base: Fixtures.queue($0)) }
        }
        #expect(queue?.message.contains("join()") == true)

        // Only a suspended player's join goes through: the suspension check catches it (#314).
        let suspended = await Self.violation {
            try await QueueServiceContract().run { SuspendedCanJoinQueue(base: Fixtures.queue($0)) }
        }
        #expect(suspended?.message.contains("a suspended player's join() didn't throw") == true, "\(String(describing: suspended))")

        let livery = await Self.violation {
            try await ProfileServiceContract().run { AnyClassLiveryProfile(base: Fixtures.profile($0)) }
        }
        #expect(livery?.message.contains("another class") == true, "\(String(describing: livery))")

        let session = await Self.violation {
            try await RaceSessionServiceContract().run { BrokenRaceSession(base: Fixtures.raceSession($0)) }
        }
        #expect(session?.message.contains("lastRace()") == true)
    }

    @Test func aViolationSaysWhereItWasChecked() async {
        let violation = await Self.violation {
            try await TermsServiceContract().run { BrokenTerms(base: Fixtures.terms($0)) }
        }
        #expect(violation?.location.contains("TermsServiceContract.swift") == true)
    }
}

// MARK: - Implementations

/// A terms service written without the fake.
private actor MinimalTerms: TermsService {
    let current: Int
    var accepted: Int?

    init(current: Int, accepted: Int?) {
        self.current = current
        self.accepted = accepted
    }

    func status() -> TermsStatus {
        accepted == current
            ? .accepted(TermsVersion(current))
            : .needsAcceptance(current: TermsVersion(current), lastAccepted: accepted.map(TermsVersion.init))
    }

    func accept(_ version: TermsVersion) throws -> TermsStatus {
        guard version.rawValue == current else { throw TermsError.staleVersion(current: TermsVersion(current)) }
        accepted = current
        return status()
    }
}

/// Takes any version, and forgets it.
private struct BrokenTerms: TermsService {
    let base: ScriptedTermsService

    func status() async throws -> TermsStatus { await base.status() }
    func accept(_ version: TermsVersion) async throws -> TermsStatus { .accepted(version) }
}

/// Signs for a player who isn't there.
private struct BrokenIdentity: IdentityService {
    let base: ScriptedIdentityService

    func state() async -> GameCenterState { await base.state() }
    func stateUpdates() -> AsyncStream<GameCenterState> { base.stateUpdates() }
    func gamePlayerID() async -> GamePlayerID? { await base.gamePlayerID() }
    func signIn() async -> GameCenterState { await base.signIn() }
    func identitySignature() async throws -> IdentitySignature {
        IdentitySignature(gamePlayerID: GamePlayerID("G:0"), teamPlayerID: "T:0", publicKeyURL: "https://x.invalid", signature: [1], salt: [1], timestamp: 0)
    }
}

/// Swallows every refusal to join.
private struct BrokenQueue: QueueService {
    let base: ScriptedQueueService

    func stateUpdates() -> AsyncStream<QueueState> { base.stateUpdates() }
    func join() async throws { try? await base.join() }
    func leave() async throws { try await base.leave() }
}

/// Lets a suspended player join, and is right about everything else.
private struct SuspendedCanJoinQueue: QueueService {
    let base: ScriptedQueueService

    func stateUpdates() -> AsyncStream<QueueState> { base.stateUpdates() }
    func join() async throws {
        do {
            try await base.join()
        } catch QueueError.refused(.suspended) {
        }
    }
    func leave() async throws { try await base.leave() }
}

/// Forgets the last race.
private struct BrokenRaceSession: RaceSessionService {
    let base: ScriptedRaceSessionService

    func handOff() async throws -> HandOff { try base.handOff() }
    func rejoin() async throws -> RejoinOffer { try base.rejoin() }
    func results() -> AsyncStream<RaceUpdate> { base.results() }
    func ratingChanges() -> AsyncStream<RatingChange> { base.ratingChanges() }
    func lastRace() async throws -> LastRace? { nil }
}

/// Takes a livery of another boat class.
private struct AnyClassLiveryProfile: ProfileService {
    let base: ScriptedProfileService

    func profile() async throws -> Profile { try await base.profile() }
    func saveLivery(_ livery: Livery) async throws -> Livery {
        if livery.design == ProfileServiceContract.otherClassDesign { return livery }
        return try await base.saveLivery(livery)
    }
}
