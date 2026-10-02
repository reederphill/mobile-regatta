import Foundation
import MetricKit
import RegattaServices

// The app's side of usage analytics (#28, #128): `Analytics` from RegattaServices over the device's defaults, the
// wall clock and a random UUID, sent through the services' `AnalyticsTransport` (the fake until #166). Share usage
// data gates everything, MetricKit's summaries included: they go through the same `log`. Apple's crash reports follow
// the iOS setting and aren't forwarded.

extension Analytics {
    /// The app's analytics: kept in `defaults` (a reinstall forgets it, so the install id is new), or in memory for UI
    /// tests; on while Settings' Share usage data is.
    static func app(transport: any AnalyticsTransport, launchOptions: LaunchOptions = .current,
                    defaults: UserDefaults = .standard) -> Analytics {
        let storage: any AnalyticsStorage = launchOptions.uiTesting ? InMemoryAnalyticsStorage() : UserDefaultsAnalyticsStorage(defaults: defaults)
        return Analytics(transport: transport, storage: storage, isSharing: DeviceSettings(defaults: defaults).sharesUsageData,
                         makeInstallID: { UUID().uuidString }, now: { Int64(Date().timeIntervalSince1970) })
    }
}

extension UsageEvent {
    /// A practice race finished: `tuned` when it sailed tuned copies (#229), which only Debug builds can (ADR 0004).
    static func practiceRaceFinished(_ config: RaceConfig) -> UsageEvent {
        .practiceToOnline(.practiceRaceFinished(tuned: config.files.isTuned))
    }
}

/// Keeps `Analytics`' state in `UserDefaults` under `analytics.` keys, apart from the `hints.` ones Reset hints
/// clears. Not the keychain, so a reinstall starts a new install id. Unchecked: `UserDefaults` is thread-safe but not
/// marked `Sendable`, and this holds nothing else.
nonisolated final class UserDefaultsAnalyticsStorage: AnalyticsStorage, @unchecked Sendable {
    enum Key {
        static let installID = "analytics.installID"
        static let nextSequence = "analytics.nextSequence"
        static let pending = "analytics.pending"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> AnalyticsState {
        let pending = defaults.data(forKey: Key.pending)
            .flatMap { try? JSONDecoder().decode([StoredEvent].self, from: $0) }?
            .map(\.event) ?? []
        return AnalyticsState(installID: defaults.string(forKey: Key.installID).map(InstallID.init),
                              nextSequence: max(1, defaults.integer(forKey: Key.nextSequence)), pending: pending)
    }

    func save(_ state: AnalyticsState) {
        if let id = state.installID { defaults.set(id.rawValue, forKey: Key.installID) }
        defaults.set(state.nextSequence, forKey: Key.nextSequence)
        if state.pending.isEmpty {
            defaults.removeObject(forKey: Key.pending)
        } else if let data = try? JSONEncoder().encode(state.pending.map(StoredEvent.init)) {
            defaults.set(data, forKey: Key.pending)
        }
    }

    /// An event as stored: `AnalyticsEvent` isn't `Codable`, and the stored form is the app's own business.
    private struct StoredEvent: Codable {
        enum Value: Codable {
            case int(Int)
            case double(Double)
            case string(String)
            case bool(Bool)
        }

        var sequence: Int
        var name: String
        var time: Int64
        var properties: [String: Value]

        init(_ event: AnalyticsEvent) {
            sequence = event.sequence
            name = event.name.rawValue
            time = event.time
            properties = event.properties.mapValues { value in
                switch value {
                case .int(let int): .int(int)
                case .double(let double): .double(double)
                case .string(let string): .string(string)
                case .bool(let bool): .bool(bool)
                }
            }
        }

        var event: AnalyticsEvent {
            AnalyticsEvent(sequence: sequence, name: AnalyticsEventName(name), time: time, properties: properties.mapValues { value in
                switch value {
                case .int(let int): .int(int)
                case .double(let double): .double(double)
                case .string(let string): .string(string)
                case .bool(let bool): .bool(bool)
                }
            })
        }
    }
}

/// Forwards MetricKit's daily summaries as `performance` events (#28) through `Analytics.log`, so Share usage data
/// off keeps them on the device too. Diagnostics (crashes, hangs' call stacks) aren't forwarded.
nonisolated final class MetricKitForwarder: NSObject, MXMetricManagerSubscriber, Sendable {
    let analytics: Analytics

    init(analytics: Analytics) { self.analytics = analytics }

    /// Subscribes; MetricKit delivers at most daily, at launch or later.
    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { analytics.log(.performance(Self.summary(of: payload))) }
    }

    static func summary(of payload: MXMetricPayload) -> MetricSummary {
        let meta = payload.metaData
        var summary = MetricSummary(deviceModel: meta?.deviceType ?? "unknown", osVersion: meta?.osVersion ?? "unknown",
                                    appBuild: meta?.applicationBuildVersion ?? payload.latestApplicationVersion)
        summary.periodSeconds = payload.timeStampEnd.timeIntervalSince(payload.timeStampBegin)
        summary.foregroundSeconds = payload.applicationTimeMetrics.map { seconds($0.cumulativeForegroundTime) }
        summary.backgroundSeconds = payload.applicationTimeMetrics.map { seconds($0.cumulativeBackgroundTime) }
        summary.cpuSeconds = payload.cpuMetrics.map { seconds($0.cumulativeCPUTime) }
        summary.gpuSeconds = payload.gpuMetrics.map { seconds($0.cumulativeGPUTime) }
        summary.peakMemoryMegabytes = payload.memoryMetrics.map { $0.peakMemoryUsage.converted(to: .megabytes).value }
        summary.hangSeconds = payload.applicationResponsivenessMetrics
            .flatMap { MetricSummary.histogram(buckets($0.histogrammedApplicationHangTime))?.total }
        summary.launchSeconds = payload.applicationLaunchMetrics
            .flatMap { MetricSummary.histogram(buckets($0.histogrammedTimeToFirstDraw))?.mean }
        summary.foregroundAbnormalExits = payload.applicationExitMetrics.map { $0.foregroundExitData.cumulativeAbnormalExitCount }
        summary.memoryLimitExits = payload.applicationExitMetrics.map {
            $0.foregroundExitData.cumulativeMemoryResourceLimitExitCount + $0.backgroundExitData.cumulativeMemoryResourceLimitExitCount
        }
        return summary
    }

    private static func seconds(_ duration: Measurement<UnitDuration>) -> Double {
        duration.converted(to: .seconds).value
    }

    private static func buckets(_ histogram: MXHistogram<UnitDuration>) -> [(start: Double, end: Double, count: Int)] {
        histogram.bucketEnumerator.allObjects.compactMap { $0 as? MXHistogramBucket<UnitDuration> }.map {
            (start: seconds($0.bucketStart), end: seconds($0.bucketEnd), count: $0.bucketCount)
        }
    }
}
