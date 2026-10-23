import Foundation
import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Testing
@testable import Regatta

/// `OnlineStatus` over an online session on the network stub (`StubService`), with the app's analytics on the session's
/// transport (#166).
@MainActor struct OnlineDataRig {
    static let wren = DevicePlayer(teamPlayerID: "T:wren", player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:wren"), alias: "Wren"))

    let service = StubService()
    let tokens = InMemorySessionTokenStore()
    let session: OnlineSession
    let status: OnlineStatus
    let analytics: Analytics

    /// `started`: the session follows the device's player from the start, as at launch (else from her first tap).
    init(sharing: Bool = true, termsAccepted: Bool = true, held: any HeldPlayerStore = InMemoryHeldPlayerStore(),
         started: Bool = false) async {
        let (service, tokens) = (service, tokens)
        if termsAccepted { service.state.withLock { $0.terms = .accepted(version: 1) } }
        let device = ScriptedDeviceIdentity(player: Self.wren) { player in
            IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID,
                              publicKeyURL: "https://test.invalid/key.cer", signature: [1], salt: [2], timestamp: 3)
        }
        // A wait that only its cancelling ends: no deadline or back-off comes round in a test.
        session = OnlineSession(OnlineSession.Dependencies(
            connect: { try service.connect() }, device: device, tokens: tokens,
            sleep: { _ in for await _ in AsyncStream<Void>.makeStream().stream {}; throw CancellationError() },
            jitter: { 0 }, clientBuild: "test", held: held))
        var services = ServiceSet.fake(.signedOut)
        services.adopt(session)
        analytics = Analytics(transport: services.analytics, storage: InMemoryAnalyticsStorage(), isSharing: sharing,
                              makeInstallID: { "install" }, now: { 0 })
        status = OnlineStatus(services: services, session: OnlineStatus.Session(session: session, device: device), analytics: analytics)
        if started { await session.deviceChanged(Self.wren) }
        await status.deviceChanged(Self.wren)
    }

    /// The analytics batches the stub was sent, as "analytics <events>".
    var batches: [String] { service.calls.filter { $0.hasPrefix("analytics") } }

    /// Race online's Sign in: the session opens, and the gate's flush follows.
    func signIn() async {
        _ = await status.signIn(analytics: .discarding())
        await eventually { status.sessionPhase == .open(Self.wren.player) && status.lobbyStatus.isSignedIn }
    }

    /// Waits (3 s at most) for `condition`: the session's phase and the gate's flush come over streams and tasks.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets the tasks the last step started run.
    func settle() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
        await status.analyticsFlush?.value
    }
}

/// Usage analytics on the real transport (#166): Share usage data off, no ingest request ever; on, a batch as the
/// session comes through the terms and on going to the background, never before the terms and never during a race.
@MainActor @Suite struct AnalyticsUploadTests {
    private static let summary = MetricSummary(deviceModel: "iPhone17,1", osVersion: "27.0", appBuild: "1")

    /// The acceptance: Share usage data off, events and a MetricKit summary logged, the gate's flush and the background
    /// flush run: 0 `analyticsRequest` frames. Then on, 3 events: exactly 1 batch of 3.
    @Test func shareUsageOffSendsNoIngestRequests() async {
        let rig = await OnlineDataRig(sharing: false)
        rig.analytics.log(.practiceToOnline(.raceOnlineTapped))
        rig.analytics.log(.gameCenterPrompt(accepted: true))
        rig.analytics.log(.performance(Self.summary))
        await rig.signIn()
        await rig.settle()
        #expect(rig.status.lobbyStatus.hasAcceptedTerms)
        #expect(rig.status.analyticsFlush != nil, "the gate never flushed")
        rig.status.setSceneActive(false)
        await rig.settle()
        #expect(rig.batches == [])
        #expect(rig.analytics.pending.isEmpty)

        // The control: back in the foreground, sharing on, 3 events, the background flush.
        rig.status.setSceneActive(true)
        await rig.eventually { rig.service.connects == 2 && rig.status.sessionPhase == .open(OnlineDataRig.wren.player) }
        await rig.settle()
        rig.analytics.setSharing(true)
        rig.analytics.log(.practiceToOnline(.raceOnlineTapped))
        rig.analytics.log(.gameCenterPrompt(accepted: true))
        rig.analytics.log(.performance(Self.summary))
        rig.status.setSceneActive(false)
        await rig.settle()
        #expect(rig.batches == ["analytics 3"])
        #expect(rig.analytics.pending.isEmpty)
    }

    /// The terms due: the gate doesn't flush, and the background flush's transport sends nothing (the server would close
    /// the connection on it): 0 frames, 1 connect. I agree sends them.
    @Test func noIngestBeforeTheTerms() async {
        let rig = await OnlineDataRig(termsAccepted: false)
        rig.analytics.log(.practiceToOnline(.raceOnlineTapped))
        rig.analytics.log(.gameCenterPrompt(accepted: true))
        await rig.signIn()
        await rig.settle()
        #expect(!rig.status.lobbyStatus.hasAcceptedTerms)
        #expect(rig.status.analyticsFlush == nil, "the gate flushed before the terms")
        rig.status.setSceneActive(false)
        await rig.settle()
        #expect(rig.batches == [])
        #expect(rig.service.connects == 1)
        #expect(rig.analytics.pending.count == 2)

        rig.status.setSceneActive(true)
        await rig.eventually { rig.service.connects == 2 && rig.status.sessionPhase == .open(OnlineDataRig.wren.player) }
        await rig.settle()
        #expect(await rig.status.acceptTerms(TermsVersion(1), analytics: .discarding()))
        await rig.settle()
        #expect(rig.batches == ["analytics 2"])
    }

    /// In a race nothing goes, at the gate or in the background; the next trigger after it takes the buffer.
    @Test func noFlushDuringARace() async {
        let rig = await OnlineDataRig()
        var racing = true
        rig.status.isRacing = { racing }
        rig.analytics.log(.practiceToOnline(.raceOnlineTapped))
        await rig.signIn()
        await rig.settle()
        rig.status.setSceneActive(false)
        await rig.settle()
        #expect(rig.status.analyticsFlush == nil)
        #expect(rig.batches == [])

        racing = false
        rig.status.setSceneActive(true)
        await rig.eventually { rig.batches.count == 1 }
        #expect(rig.batches == ["analytics 1"])
    }
}

/// Settings → Delete my online data (#166): the plan on the tap, the delete, the device's online caches wiped (bought
/// designs kept), every outcome's notice, and the hold that keeps her offline across a relaunch.
@MainActor @Suite struct OnlineDataDeleterTests {
    /// A private defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let name = "OnlineDataDeleterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    private func model(_ defaults: UserDefaults) -> AppModel {
        AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta"]), defaults: defaults)
    }

    private static func onlineLastRace() throws -> RaceResultViewModel {
        RaceResultViewModel(lastRace: try #require(FakeServiceScenario.onlineRace(rated: true).lastRace), livery: FleetLiveries.yours)
    }

    @Test func successClearsOnlineCachesKeepsPurchases() async throws {
        try await withDefaults { defaults in
            let model = model(defaults)
            let online = try Self.onlineLastRace()
            #expect(online.online != nil)
            model.keepLastRace(online)
            defaults.set(Data([1]), forKey: LastHandOffStore.key)
            let completed = CompletedRacesStore(defaults: defaults)
            completed.count = 4
            completed.countCompletion(of: "race-5")
            defaults.set(["skiff-stripe"], forKey: StubStoreService.ownedKey)
            defaults.set(Data("history".utf8), forKey: PracticeHistoryStore.key)
            defaults.set(1, forKey: LocalTermsService.key(for: OnlineDataRig.wren.player.gamePlayerID))
            model.deviceSettings.laylines.toggle()
            let laylines = model.deviceSettings.laylines
            let livery = model.myLivery

            let rig = await OnlineDataRig()
            let install = rig.analytics.installID
            await rig.signIn()
            let deleter = OnlineDataDeleter.app(status: rig.status, model: model, defaults: defaults)
            guard case .confirm(let plan) = await deleter.prepare() else { Issue.record("no plan"); return }
            #expect(await deleter.confirm(plan) == OnlineDataDeleter.Notice.deleted)
            #expect(rig.service.calls.filter { ["plan", "delete"].contains($0) } == ["plan", "delete"])
            await rig.eventually { rig.status.sessionPhase == .idle }

            // Cleared: her session, terms record, online Last race and race counts; the livery waits to be uploaded.
            #expect(rig.tokens.all == [:])
            #expect(await rig.session.phase == .idle && rig.status.sessionPhase == .idle)
            #expect(!rig.status.lobbyStatus.isSignedIn)
            #expect(defaults.object(forKey: LocalTermsService.key(for: OnlineDataRig.wren.player.gamePlayerID)) == nil)
            #expect(model.lastRace == nil && LastRaceStore(defaults: defaults).load() == nil)
            #expect(defaults.object(forKey: LastHandOffStore.key) == nil)
            #expect(defaults.object(forKey: CompletedRacesStore.key) == nil)
            #expect(defaults.object(forKey: CompletedRacesStore.lastCountedKey) == nil)
            #expect(model.myBoat.completedRaces == 0)
            #expect(defaults.bool(forKey: LiverySync.pendingKey))
            // Kept: bought designs, her boat, practice history, settings and the install id.
            #expect(defaults.stringArray(forKey: StubStoreService.ownedKey) == ["skiff-stripe"])
            #expect(StubStoreService.owned(in: defaults) == [DesignID("skiff-stripe")])
            #expect(model.myLivery == livery)
            #expect(defaults.data(forKey: PracticeHistoryStore.key) == Data("history".utf8))
            #expect(model.deviceSettings.laylines == laylines)
            #expect(rig.analytics.installID == install)
        }
    }

    /// A practice Last race isn't online data: it stays.
    @Test func aPracticeLastRaceStays() async throws {
        try await withDefaults { defaults in
            let model = model(defaults)
            let practice = RaceResultViewModel(rows: [], card: nil, isFinal: true, mySeat: 0)
            model.keepLastRace(practice)
            model.forgetOnlineData()
            #expect(model.lastRace == practice)
            #expect(LastRaceStore(defaults: defaults).load() == practice)
        }
    }

    /// A deletion service that answers as told.
    private struct Answering: DataDeletionService {
        var plan: (any Error)?
        var delete: (any Error)?

        func plan() async throws -> DeletionPlan {
            if let plan { throw plan }
            return DeletionPlan(deletes: DeletionPlan.required, anonymisesRaceLogs: true, confirmation: DeletionConfirmation(token: "c"))
        }

        func delete(confirmedBy confirmation: DeletionConfirmation) async throws {
            if let delete { throw delete }
        }
    }

    /// Each outcome's notice (O4), and whether the device's online caches go: only when the server holds nothing more.
    @Test func outcomes() async {
        var wipes = 0
        func deleter(_ service: Answering) -> OnlineDataDeleter {
            OnlineDataDeleter(deletion: service, player: { nil }, wipe: { _ in wipes += 1 }, settled: {})
        }
        typealias Notice = OnlineDataDeleter.Notice
        let plan = DeletionPlan(deletes: DeletionPlan.required, anonymisesRaceLogs: true, confirmation: DeletionConfirmation(token: "c"))

        #expect(await deleter(Answering(plan: DataDeletionError.notSignedIn)).prepare() == .notice(Notice.notSignedIn))
        #expect(wipes == 0)
        #expect(await deleter(Answering(plan: OnlineSessionError.notConnected)).prepare() == .notice(Notice.unreachable))
        #expect(await deleter(Answering(plan: OnlineSessionError.timedOut)).prepare() == .notice(Notice.unreachable))
        #expect(wipes == 0)
        #expect(await deleter(Answering(plan: DataDeletionError.nothingToDelete)).prepare() == .notice(Notice.nothingToDelete))
        #expect(wipes == 1)

        #expect(await deleter(Answering()).prepare() == .confirm(plan))
        #expect(await deleter(Answering(delete: DataDeletionError.invalidConfirmation)).confirm(plan) == Notice.expired)
        #expect(await deleter(Answering(delete: OnlineSessionError.timedOut)).confirm(plan) == Notice.unreachable)
        #expect(await deleter(Answering(delete: DataDeletionError.notSignedIn)).confirm(plan) == Notice.notSignedIn)
        #expect(wipes == 1)
        #expect(await deleter(Answering(delete: DataDeletionError.nothingToDelete)).confirm(plan) == Notice.nothingToDelete)
        #expect(wipes == 2)
        #expect(await deleter(Answering()).confirm(plan) == Notice.deleted)
        #expect(wipes == 3)
    }

    /// The hold is kept in the app's defaults (O1, T3): a relaunch (a new session over the same defaults) opens nothing
    /// for her, and a held player's tap is answered with no connection (T9), until her own Sign in.
    @Test func theHoldSurvivesARelaunch() async throws {
        try await withDefaults { defaults in
            let rig = await OnlineDataRig(held: DefaultsHeldPlayerStore(defaults: defaults))
            await rig.signIn()
            let deleter = OnlineDataDeleter.app(status: rig.status, model: model(defaults), defaults: defaults)
            guard case .confirm(let plan) = await deleter.prepare() else { Issue.record("no plan"); return }
            #expect(await deleter.confirm(plan) == OnlineDataDeleter.Notice.deleted)
            #expect(defaults.stringArray(forKey: DefaultsHeldPlayerStore.key) == ["T:wren"])

            let relaunch = await OnlineDataRig(held: DefaultsHeldPlayerStore(defaults: defaults), started: true)
            relaunch.status.setSceneActive(true)
            await relaunch.settle()
            #expect(relaunch.service.connects == 0)
            #expect(relaunch.status.sessionPhase == .idle && !relaunch.status.lobbyStatus.isSignedIn)
            let held = OnlineDataDeleter.app(status: relaunch.status, model: model(defaults), defaults: defaults)
            #expect(await held.prepare() == .notice(OnlineDataDeleter.Notice.nothingToDelete))
            #expect(relaunch.service.connects == 0 && relaunch.service.calls == [])

            // Her own Sign in: one connect, and the terms asked afresh.
            await relaunch.signIn()
            #expect(relaunch.service.connects == 1)
            #expect(defaults.object(forKey: DefaultsHeldPlayerStore.key) == nil)
        }
    }
}
