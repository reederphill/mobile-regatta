import RegattaCore
import RegattaServices
import Synchronization
import Testing

/// The telemetry client (#128): the buffer, the install id, the Share usage data gate, the event catalogue.
@Suite struct AnalyticsTests {
    /// Counts every call and keeps every batch it's given, failing the first `failures` calls as unreachable.
    actor CountingTransport: AnalyticsTransport {
        let base = ScriptedAnalyticsTransport()
        private var failures: Int
        private(set) var calls = 0
        private(set) var batches: [AnalyticsBatch] = []

        init(failures: Int = 0) { self.failures = failures }

        func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
            calls += 1
            if failures > 0 {
                failures -= 1
                throw AnalyticsError.unavailable
            }
            batches.append(batch)
            return try await base.send(batch)
        }
    }

    /// Holds each send until `release()` while `isHolding`, counting releases, so a test can act mid-send.
    actor HeldTransport: AnalyticsTransport {
        let base = ScriptedAnalyticsTransport()
        private var isHolding = true
        private var held: CheckedContinuation<Void, Never>?
        private var waiting: CheckedContinuation<Void, Never>?
        private(set) var calls = 0
        private(set) var releases = 0

        func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
            calls += 1
            if isHolding {
                await withCheckedContinuation { continuation in
                    held = continuation
                    waiting?.resume()
                    waiting = nil
                }
            }
            return try await base.send(batch)
        }

        /// Returns once a send is held.
        func sendHeld() async {
            guard held == nil else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func release() {
            releases += 1
            held?.resume()
            held = nil
        }

        func stopHolding() {
            isHolding = false
            release()
        }
    }

    /// Refuses to store a state with more than `limit` events waiting, as a store that can't encode one would.
    final class RefusingStorage: AnalyticsStorage {
        struct Refused: Error {}
        let base = InMemoryAnalyticsStorage()
        let limit: Int
        init(limit: Int) { self.limit = limit }
        func load() -> AnalyticsState { base.load() }
        func save(_ state: AnalyticsState) throws {
            guard state.pending.count <= limit else { throw Refused() }
            base.save(state)
        }
    }

    /// A count that goes up by one per read.
    final class Counter: Sendable {
        private let value: Mutex<Int>
        init(_ start: Int = 0) { value = Mutex(start) }
        func next() -> Int { value.withLock { $0 += 1; return $0 } }
        var current: Int { value.withLock { $0 } }
    }

    /// A clock that ticks a second per read, and an id maker that counts.
    static func analytics(_ transport: any AnalyticsTransport, storage: any AnalyticsStorage = InMemoryAnalyticsStorage(),
                          isSharing: Bool = true, ids: Counter = Counter()) -> Analytics {
        let clock = Counter(1_000)
        return Analytics(transport: transport, storage: storage, isSharing: isSharing,
                         makeInstallID: { "install-\(ids.next())" }, now: { Int64(clock.next()) })
    }

    @Test func shareUsageOffNeverCallsTransport() async {
        let transport = CountingTransport()
        let off = Self.analytics(transport, isSharing: false)
        off.log(.firstRaceCompleted)
        off.log(.practiceToOnline(.raceOnlineTapped))
        #expect(off.pending.isEmpty)
        await off.flush()
        #expect(await transport.calls == 0)

        // Turned off with events waiting: the buffer empties and nothing goes, then or later.
        let storage = InMemoryAnalyticsStorage()
        let on = Self.analytics(transport, storage: storage)
        on.log(.firstRaceSkipped)
        on.log(.gameCenterPrompt(accepted: true))
        #expect(on.pending.count == 2)
        on.setSharing(false)
        #expect(on.pending.isEmpty)
        #expect(storage.load().pending.isEmpty)
        on.log(.liveryTryOn(DesignID("stripe")))
        await on.flush()
        #expect(await transport.calls == 0)
        #expect(await transport.base.recorded.isEmpty)

        // A launch with sharing off clears what an earlier launch left.
        let left = InMemoryAnalyticsStorage(AnalyticsState(installID: InstallID("x"), nextSequence: 2,
                                                           pending: [AnalyticsEvent(sequence: 1, name: .firstRaceCompleted, time: 5)]))
        let relaunched = Self.analytics(transport, storage: left, isSharing: false)
        #expect(relaunched.pending.isEmpty)
        #expect(left.load().pending.isEmpty)
        await relaunched.flush()
        #expect(await transport.calls == 0)

        // On again: new events go, numbered on from before.
        on.setSharing(true)
        on.log(.firstRaceCompleted)
        await on.flush()
        #expect(await transport.calls == 1)
        #expect(await transport.base.recorded.map(\.sequence) == [3])
    }

    @Test func installIdStableAcrossLaunchesNewAfterReinstall() {
        let transport = ScriptedAnalyticsTransport()
        let ids = Counter()
        let storage = InMemoryAnalyticsStorage()
        let first = Self.analytics(transport, storage: storage, ids: ids).installID
        // A second launch over the same storage, and a toggle off and on, keep it.
        let relaunch = Self.analytics(transport, storage: storage, ids: ids)
        #expect(relaunch.installID == first)
        relaunch.setSharing(false)
        relaunch.setSharing(true)
        #expect(Self.analytics(transport, storage: storage, ids: ids).installID == first)
        // A reinstall starts with empty storage: a new id.
        let reinstalled = Self.analytics(transport, storage: InMemoryAnalyticsStorage(), ids: ids).installID
        #expect(reinstalled != first)
        #expect(ids.current == 2)
    }

    @Test func bufferedEventsFlushInOrder() async throws {
        let transport = CountingTransport(failures: 1)
        let storage = InMemoryAnalyticsStorage()
        let analytics = Self.analytics(transport, storage: storage)
        for index in 0..<250 { analytics.log(.hintRetired("hint-\(index)", mode: .learned)) }
        #expect(analytics.pending.map(\.sequence) == Array(1...250))
        #expect(storage.load().pending.count == 250)

        // Unreachable: everything stays for next time.
        await analytics.flush()
        #expect(await transport.calls == 1)
        #expect(analytics.pending.count == 250)

        // A later launch over the same buffer drains it, oldest first, in batches of at most 100, each once.
        let relaunched = Self.analytics(transport, storage: storage)
        #expect(relaunched.pending.count == 250)
        await relaunched.flush()
        let batches = await transport.batches
        #expect(batches.map(\.events.count) == [100, 100, 50])
        #expect(batches.flatMap(\.events).map(\.sequence) == Array(1...250))
        #expect(batches.flatMap(\.events).map(\.time) == batches.flatMap(\.events).map(\.time).sorted())
        #expect(Set(batches.map(\.installID)).count == 1)
        #expect(relaunched.pending.isEmpty)
        #expect(storage.load().pending.isEmpty)
        #expect(await transport.base.recorded.count == 250)
        await relaunched.flush()
        #expect(await transport.calls == 4)

        // Past the buffer's limit the oldest go.
        for _ in 0..<(Analytics.bufferLimit + 10) { relaunched.log(.firstRaceSkipped) }
        #expect(relaunched.pending.count == Analytics.bufferLimit)
        #expect(relaunched.pending.first?.sequence == 261)
    }

    /// Share usage data turned off while a batch is on its way: nothing is left behind, and nothing more goes.
    @Test func optingOutMidSendLeavesNothingBehind() async {
        let transport = HeldTransport()
        let storage = InMemoryAnalyticsStorage()
        let analytics = Self.analytics(transport, storage: storage)
        for _ in 0..<150 { analytics.log(.firstRaceCompleted) }
        let flush = Task { await analytics.flush() }
        await transport.sendHeld()
        analytics.setSharing(false)
        #expect(analytics.pending.isEmpty)
        await transport.release()
        await flush.value
        // The second batch never went, and the first one's return removed nothing it shouldn't.
        #expect(await transport.calls == 1)
        #expect(analytics.pending.isEmpty)
        #expect(storage.load().pending.isEmpty)

        // On again with a send held, off and on mid-send: what's logged after survives the stale send's return.
        analytics.setSharing(true)
        analytics.log(.firstRaceSkipped)
        let second = Task { await analytics.flush() }
        await transport.sendHeld()
        analytics.setSharing(false)
        analytics.setSharing(true)
        analytics.log(.gameCenterPrompt(accepted: true))
        await transport.release()
        await second.value
        #expect(await transport.calls == 2)
        #expect(analytics.pending.map(\.sequence) == [152])
        #expect(storage.load().pending.map(\.sequence) == [152])

        await transport.stopHolding()
        await analytics.flush()
        #expect(await transport.calls == 3)
        #expect(analytics.pending.isEmpty)
        #expect(await transport.base.recorded.map(\.sequence) == Array(1...100) + [151, 152])
    }

    /// A flush asked for while one runs (going to the background during the launch flush) waits for it.
    @Test func flushWaitsForTheOneRunning() async {
        let transport = HeldTransport()
        let analytics = Self.analytics(transport)
        analytics.log(.firstRaceCompleted)
        let first = Task { await analytics.flush() }
        await transport.sendHeld()
        let second = Task {
            await analytics.flush()
            return await transport.releases
        }
        for _ in 0..<100 { await Task.yield() }
        await transport.release()
        #expect(await second.value == 1)
        #expect(analytics.pending.isEmpty)
        await first.value
        #expect(await transport.calls == 1)
    }

    /// What AppModel's settings change does to the default it's given: nothing.
    @Test func discardingStaysOff() {
        let discarding = Analytics.discarding()
        discarding.setSharing(true)
        #expect(!discarding.isSharing)
        discarding.log(.firstRaceCompleted)
        #expect(discarding.pending.isEmpty)
    }

    /// An event the storage refuses is dropped: what's waiting is never ahead of what's stored.
    @Test func eventTheStorageRefusesIsDropped() {
        let storage = RefusingStorage(limit: 1)
        let analytics = Self.analytics(ScriptedAnalyticsTransport(), storage: storage)
        analytics.log(.firstRaceCompleted)
        analytics.log(.firstRaceSkipped)
        #expect(analytics.pending.map(\.sequence) == [1])
        #expect(storage.load().pending.map(\.sequence) == [1])
        #expect(storage.load().nextSequence == 2)
    }

    @Test func tunedPracticeRaceCarriesTunedFlag() async {
        let tuned = UsageEvent.practiceToOnline(.practiceRaceFinished(tuned: true))
        #expect(tuned.properties == ["step": .string("practice_race_finished"), "tuned": .bool(true)])
        let untuned = UsageEvent.practiceToOnline(.practiceRaceFinished(tuned: false))
        #expect(untuned.properties["tuned"] == .bool(false))
        // Only a practice race's finish carries it.
        #expect(UsageEvent.practiceToOnline(.raceOnlineTapped).properties["tuned"] == nil)

        let transport = ScriptedAnalyticsTransport()
        let analytics = Self.analytics(transport)
        analytics.log(tuned)
        await analytics.flush()
        #expect(await transport.recorded.first?.properties["tuned"] == .bool(true))
    }

    /// The wire names the race server's ingest reads (#156).
    @Test func catalogueNamesArePinned() {
        let steps: [FunnelStep] = [.practiceRaceFinished(tuned: false), .raceOnlineTapped, .gameCenterSignedIn, .termsAccepted, .firstOnlineRace]
        #expect(steps.map(\.name) == ["practice_race_finished", "race_online_tapped", "game_center_signed_in", "terms_accepted", "first_online_race"])
        #expect(UsageEvent.practiceToOnline(.termsAccepted) == UsageEvent(name: AnalyticsEventName("practice_to_online"), properties: ["step": .string("terms_accepted")]))
        #expect(UsageEvent.firstRaceCompleted.name.rawValue == "first_race_completed")
        #expect(UsageEvent.firstRaceSkipped.name.rawValue == "first_race_skipped")
        #expect(UsageEvent.hintRetired("wind_shift", mode: .shownTwice)
            == UsageEvent(name: AnalyticsEventName("hint_retired"), properties: ["hint": .string("wind_shift"), "mode": .string("shown_twice")]))
        #expect(HintRetirement.learned.rawValue == "learned")
        #expect(UsageEvent.gameCenterPrompt(accepted: false)
            == UsageEvent(name: AnalyticsEventName("game_center_prompt"), properties: ["accepted": .bool(false)]))
        #expect(UsageEvent.liveryTryOn(DesignID("chevron"))
            == UsageEvent(name: AnalyticsEventName("livery_try_on"), properties: ["design": .string("chevron")]))
    }

    @Test func metricSummaryFlattensToAPerformanceEvent() {
        var summary = MetricSummary(deviceModel: "iPhone17,1", osVersion: "iOS 26.0", appBuild: "42")
        summary.cpuSeconds = 12.5
        summary.estimatedHangSeconds = 0.75
        summary.memoryLimitExits = 1
        let event = UsageEvent.performance(summary)
        #expect(event.name.rawValue == "performance")
        #expect(event.properties == [
            "device_model": .string("iPhone17,1"), "os_version": .string("iOS 26.0"), "app_build": .string("42"),
            "cpu_s": .double(12.5), "hang_s_est": .double(0.75), "memory_limit_exits": .int(1),
        ])
        // A number the stored buffer can't hold is left out.
        summary.gpuSeconds = .nan
        summary.estimatedLaunchSeconds = .infinity
        #expect(UsageEvent.performance(summary).properties == event.properties)
        let histogram = MetricSummary.histogram([(start: 0, end: 1, count: 2), (start: 1, end: 3, count: 2)])
        #expect(histogram?.total == 5)
        #expect(histogram?.mean == 1.25)
        #expect(MetricSummary.histogram([]) == nil)
    }
}
