import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// The app's side of usage analytics (#128): the defaults storage, the Share usage data wiring, the `tuned` flag.
@MainActor @Suite struct AnalyticsEmitTests {
    /// A private defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "AnalyticsEmitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func defaultsStorageRoundTripsAndSurvivesResetHints() throws {
        try withDefaults { defaults in
            let storage = UserDefaultsAnalyticsStorage(defaults: defaults)
            #expect(storage.load() == AnalyticsState())
            let state = AnalyticsState(installID: InstallID("abc"), nextSequence: 3, pending: [
                AnalyticsEvent(sequence: 1, name: .practiceToOnline, time: 10, properties: ["step": .string("race_online_tapped"), "tuned": .bool(true)]),
                AnalyticsEvent(sequence: 2, name: .performance, time: 11, properties: ["cpu_s": .double(1.5), "memory_limit_exits": .int(2)]),
            ])
            storage.save(state)
            #expect(UserDefaultsAnalyticsStorage(defaults: defaults).load() == state)
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("analytics.") }.count == 3)

            DeviceSettings.resetHints(in: defaults)
            #expect(storage.load() == state)

            var sent = state
            sent.pending = []
            storage.save(sent)
            #expect(storage.load() == sent)
            #expect(defaults.object(forKey: UserDefaultsAnalyticsStorage.Key.pending) == nil)
        }
    }

    /// The app's analytics over the device's defaults: one id per install, gated by Settings' Share usage data.
    @Test func appAnalyticsFollowsShareUsageData() async throws {
        try withDefaults { defaults in
            let transport = ScriptedAnalyticsTransport()
            let analytics = Analytics.app(transport: transport, launchOptions: LaunchOptions(), defaults: defaults)
            #expect(analytics.isSharing)
            let id = analytics.installID
            #expect(Analytics.app(transport: transport, launchOptions: LaunchOptions(), defaults: defaults).installID == id)

            let model = AppModel(launchOptions: LaunchOptions(), defaults: defaults, analytics: analytics)
            analytics.log(.practiceToOnline(.raceOnlineTapped))
            #expect(analytics.pending.count == 1)
            model.deviceSettings.sharesUsageData = false
            #expect(!analytics.isSharing)
            #expect(analytics.pending.isEmpty)
            analytics.log(.firstRaceCompleted)
            #expect(analytics.pending.isEmpty)
            // The next launch reads the setting as saved.
            #expect(!Analytics.app(transport: transport, launchOptions: LaunchOptions(), defaults: defaults).isSharing)
            model.deviceSettings.sharesUsageData = true
            #expect(analytics.isSharing)
        }
    }

    @Test func practiceRaceFinishedIsTunedOnlyOnTunedFiles() {
        var config = RaceConfig(seed: 1, windSeed: 2)
        #expect(UsageEvent.practiceRaceFinished(config).properties["tuned"] == .bool(false))
        let bundled = config.files.boatClass
        config.files.boatClass = FileRef(id: bundled.id, version: bundled.version, hash: bundled.hash, tune: 1)
        #expect(config.files.isTuned)
        #expect(UsageEvent.practiceRaceFinished(config).properties
            == ["step": .string("practice_race_finished"), "tuned": .bool(true)])
    }
}
