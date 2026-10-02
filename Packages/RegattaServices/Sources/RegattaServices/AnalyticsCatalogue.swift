import RegattaCore

// The usage events the app logs (#28, #128): each a name and its properties, before `Analytics` gives it a sequence
// and a time. The raw strings are the wire contract with the race server's ingest (#156): `AnalyticsTests` pins them.

/// An event as the app logs it: what happened, with its details. `Analytics.log` numbers and times it.
public struct UsageEvent: Equatable, Sendable {
    public var name: AnalyticsEventName
    public var properties: [String: AnalyticsValue]

    public init(name: AnalyticsEventName, properties: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}

extension AnalyticsEventName {
    /// A MetricKit summary (#28): hangs, CPU and GPU time, memory, launch time, exits, by device model.
    public static let performance = AnalyticsEventName("performance")
}

/// How a hint retired (#25): the player did what it teaches, or it showed twice.
public enum HintRetirement: String, Sendable, CaseIterable {
    case learned
    case shownTwice = "shown_twice"
}

/// A step of the practice → online funnel (#28), in the order a player takes them.
public enum FunnelStep: Equatable, Sendable {
    /// A practice race finished; `tuned` when it sailed generated tuning files (#229, Debug builds only, ADR 0004).
    case practiceRaceFinished(tuned: Bool)
    case raceOnlineTapped
    case gameCenterSignedIn
    case termsAccepted
    /// The first online race finished.
    case firstOnlineRace

    /// The `step` property's value.
    public var name: String {
        switch self {
        case .practiceRaceFinished: "practice_race_finished"
        case .raceOnlineTapped: "race_online_tapped"
        case .gameCenterSignedIn: "game_center_signed_in"
        case .termsAccepted: "terms_accepted"
        case .firstOnlineRace: "first_online_race"
        }
    }
}

/// What MetricKit reported for a period (#28), as plain values: the app reads them off an `MXMetricPayload`, which
/// tests can't build. A missing measurement is nil and leaves its property out. MetricKit has no frame rate or
/// thermal state, so neither is here.
public struct MetricSummary: Equatable, Sendable {
    public var deviceModel: String
    public var osVersion: String
    public var appBuild: String
    /// The period the payload covers.
    public var periodSeconds: Double?
    public var foregroundSeconds: Double?
    public var backgroundSeconds: Double?
    public var cpuSeconds: Double?
    public var gpuSeconds: Double?
    public var peakMemoryMegabytes: Double?
    /// Total time hung, from the hang-time histogram.
    public var hangSeconds: Double?
    /// Mean time to first draw, from the launch histogram.
    public var launchSeconds: Double?
    public var foregroundAbnormalExits: Int?
    public var memoryLimitExits: Int?

    public init(deviceModel: String, osVersion: String, appBuild: String) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appBuild = appBuild
    }

    /// A histogram's total and mean, each bucket counted at its midpoint; nil when it's empty.
    public static func histogram(_ buckets: [(start: Double, end: Double, count: Int)]) -> (total: Double, mean: Double)? {
        let count = buckets.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        let total = buckets.reduce(0.0) { $0 + Double($1.count) * ($1.start + $1.end) / 2 }
        return (total, total / Double(count))
    }
}

extension UsageEvent {
    public static let firstRaceCompleted = UsageEvent(name: .firstRaceCompleted)
    public static let firstRaceSkipped = UsageEvent(name: .firstRaceSkipped)

    /// A hint retired, and how.
    public static func hintRetired(_ hint: String, mode: HintRetirement) -> UsageEvent {
        UsageEvent(name: .hintRetired, properties: ["hint": .string(hint), "mode": .string(mode.rawValue)])
    }

    /// A practice → online funnel step. Only a practice race's finish carries `tuned`.
    public static func practiceToOnline(_ step: FunnelStep) -> UsageEvent {
        var properties: [String: AnalyticsValue] = ["step": .string(step.name)]
        if case .practiceRaceFinished(let tuned) = step { properties["tuned"] = .bool(tuned) }
        return UsageEvent(name: .practiceToOnline, properties: properties)
    }

    /// The Game Center prompt was answered.
    public static func gameCenterPrompt(accepted: Bool) -> UsageEvent {
        UsageEvent(name: .gameCenterPrompt, properties: ["accepted": .bool(accepted)])
    }

    /// A livery design was tried on.
    public static func liveryTryOn(_ design: DesignID) -> UsageEvent {
        UsageEvent(name: .liveryTryOn, properties: ["design": .string(design.rawValue)])
    }

    /// A MetricKit period, flattened.
    public static func performance(_ summary: MetricSummary) -> UsageEvent {
        var properties: [String: AnalyticsValue] = [
            "device_model": .string(summary.deviceModel),
            "os_version": .string(summary.osVersion),
            "app_build": .string(summary.appBuild),
        ]
        let numbers: [(String, Double?)] = [
            ("period_s", summary.periodSeconds), ("foreground_s", summary.foregroundSeconds),
            ("background_s", summary.backgroundSeconds), ("cpu_s", summary.cpuSeconds), ("gpu_s", summary.gpuSeconds),
            ("peak_memory_mb", summary.peakMemoryMegabytes), ("hang_s", summary.hangSeconds),
            ("launch_s", summary.launchSeconds),
        ]
        for case let (key, value?) in numbers { properties[key] = .double(value) }
        let counts: [(String, Int?)] = [
            ("foreground_abnormal_exits", summary.foregroundAbnormalExits), ("memory_limit_exits", summary.memoryLimitExits),
        ]
        for case let (key, value?) in counts { properties[key] = .int(value) }
        return UsageEvent(name: .performance, properties: properties)
    }
}
