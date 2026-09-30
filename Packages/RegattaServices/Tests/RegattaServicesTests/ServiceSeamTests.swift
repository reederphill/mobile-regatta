import RegattaCore
import RegattaServiceContracts
import RegattaServices
import Synchronization
import Testing

/// #241's suites on #109's seam: each fails an implementation broken in one way, wrapping the fake, and says which
/// check it broke.
@Suite struct ServiceSeamTests {
    @Test func eachSuiteCatchesABrokenImplementation() async throws {
        let lobby = await ContractSeamTests.violation {
            try await LobbyServiceContract().run { LeakyLobby(base: Fixtures.lobby($0)) }
        }
        #expect(lobby?.suite == "LobbyService")
        #expect(lobby?.message.contains("reported line still shows") == true)

        let profile = await ContractSeamTests.violation {
            try await ProfileServiceContract().run { LaxProfile(base: Fixtures.profile($0)) }
        }
        #expect(profile?.message.contains("sail number 0") == true)

        let store = await ContractSeamTests.violation {
            try await StoreServiceContract().run { GenerousStore(base: Fixtures.store($0)) }
        }
        #expect(store?.message.contains("pending purchase is owned") == true)

        let analytics = await ContractSeamTests.violation {
            try await AnalyticsTransportContract().run { CountingTwice(base: Fixtures.analytics($0)) }
        }
        #expect(analytics?.message.contains("resending") == true)

        let connectivity = await ContractSeamTests.violation {
            try await ConnectivityServiceContract().run { Stuttering(base: Fixtures.connectivity($0)) }
        }
        #expect(connectivity?.message.contains("the drop read") == true)

        let deletion = await ContractSeamTests.violation {
            try await DataDeletionServiceContract().run { Unconfirmed(base: Fixtures.deletion($0)) }
        }
        #expect(deletion?.message.contains("never issued") == true)
    }

    /// Share usage data off sends nothing and records nothing; on, batches go through (#28).
    @Test func sharingOffSendsNothing() async throws {
        let sink = ScriptedAnalyticsTransport()
        let sharing = Mutex(false)
        let gated = SharingGatedTransport(sink) { sharing.withLock { $0 } }
        let batch = AnalyticsBatch(installID: InstallID("i-1"), events: [AnalyticsEvent(sequence: 1, name: .firstRaceCompleted, time: 1)])
        #expect(try await gated.send(batch) == AnalyticsReceipt(accepted: 0, duplicates: 0))
        #expect(await sink.recorded.isEmpty)
        sharing.withLock { $0 = true }
        #expect(try await gated.send(batch) == AnalyticsReceipt(accepted: 1, duplicates: 0))
        #expect(await sink.recorded == batch.events)
    }

    /// The lobby fake's rate limit lifts once its clock passes the limit.
    @Test func lobbyRateLimitLiftsWithTime() async throws {
        let lobby = Fixtures.lobby(.open)
        _ = try await lobby.post(.gg)
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: LobbyLimits.secondsBetweenPosts)) { try await lobby.post(.gg) }
        await lobby.advance(seconds: LobbyLimits.secondsBetweenPosts)
        #expect(try await lobby.post(.oneMore).post?.delivery == .sent)
        #expect(await lobby.filedReports.isEmpty)
    }

    /// The deletion fake refuses a confirmation it hasn't issued yet, before any plan, rather than trapping.
    @Test func deletionFakeRefusesAConfirmationBeforeAnyPlan() async throws {
        let deletion = Fixtures.deletion(.hasOnlineData)
        await #expect(throws: DataDeletionError.invalidConfirmation) {
            try await deletion.delete(confirmedBy: DeletionConfirmation(token: "delete-1"))
        }
    }
}

// MARK: - Implementations, each broken in one way

/// Reports go nowhere: the reported line stays.
private struct LeakyLobby: LobbyService {
    let base: ScriptedLobbyService

    func state() async throws -> LobbyState { await base.state() }
    func history() async throws -> [LobbyMessage] { try await base.history() }
    func feed() -> AsyncStream<LobbyEvent> { base.feed() }
    func post(_ text: String) async throws -> LobbyMessage { try await base.post(text) }
    func post(_ quickChat: QuickChat) async throws -> LobbyMessage { try await base.post(quickChat) }
    func block(_ player: GamePlayerID) async throws { try await base.block(player) }
    func unblock(_ player: GamePlayerID) async throws { await base.unblock(player) }
    func blockedPlayers() async throws -> [BlockedPlayer] { await base.blockedPlayers() }
    func report(message: MessageID) async throws {}
    func report(player: GamePlayerID) async throws { try await base.report(player: player) }
    func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws { try await base.report(race: race, seat: seat, reason: reason) }
}

/// Stores any livery for a signed-in player, unchecked.
private struct LaxProfile: ProfileService {
    let base: ScriptedProfileService

    func profile() async throws -> Profile { try await base.profile() }
    func saveLivery(_ livery: Livery) async throws -> Livery {
        _ = try await base.profile()
        return livery
    }
}

/// Hands over a design as soon as Ask to Buy starts.
private actor GenerousStore: StoreService {
    let base: ScriptedStoreService
    private var bought: Set<DesignID> = []

    init(base: ScriptedStoreService) { self.base = base }

    func products() async throws -> [StoreProduct] { try await base.products() }
    func ownedDesigns() async -> Set<DesignID> { await base.ownedDesigns().union(bought) }
    func purchase(_ product: ProductID) async throws -> PurchaseOutcome {
        let outcome = try await base.purchase(product)
        if outcome == .pending, let design = try await base.products().first(where: { $0.id == product })?.design {
            bought.insert(design)
        }
        return outcome
    }
    func restore() async throws -> Set<DesignID> { try await base.restore() }
    nonisolated func ownershipUpdates() -> AsyncStream<Set<DesignID>> { base.ownershipUpdates() }
}

/// Records every resend again.
private struct CountingTwice: AnalyticsTransport {
    let base: ScriptedAnalyticsTransport

    func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
        let receipt = try await base.send(batch)
        return AnalyticsReceipt(accepted: receipt.accepted + receipt.duplicates, duplicates: 0)
    }
}

/// Repeats every status it reports.
private struct Stuttering: ConnectivityService {
    let base: ScriptedConnectivityService

    func status() async -> ConnectivityStatus { await base.status() }
    func statusUpdates() -> AsyncStream<ConnectivityStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectivityStatus.self)
        let source = base.statusUpdates()
        Task {
            for await status in source {
                continuation.yield(status)
                continuation.yield(status)
            }
            continuation.finish()
        }
        return stream
    }
}

/// Deletes on any confirmation, even one it never issued.
private struct Unconfirmed: DataDeletionService {
    let base: ScriptedDataDeletionService

    func plan() async throws -> DeletionPlan { try await base.plan() }
    func delete(confirmedBy confirmation: DeletionConfirmation) async throws {
        try await base.delete(confirmedBy: try await base.plan().confirmation)
    }
}
