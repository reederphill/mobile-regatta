// Usage analytics (#28): first-party only, to the race server, keyed to a random install ID and never to the Game
// Center player. No third-party SDKs, no advertising identifier, no tracking. Settings → Share usage data (on by
// default) turned off means the device sends nothing, and racing is unaffected. The server keeps raw events 90 days.
// Race balance comes from the kept race logs on the server, not from here.

/// A random id made on install, the only key device analytics carry.
public struct InstallID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What an event measures (#28). Extensible: a name is its raw value.
public struct AnalyticsEventName: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    // Onboarding.
    public static let firstRaceCompleted = AnalyticsEventName("first_race_completed")
    public static let firstRaceSkipped = AnalyticsEventName("first_race_skipped")
    /// How a hint retired: learned, or shown twice.
    public static let hintRetired = AnalyticsEventName("hint_retired")
    public static let practiceToOnline = AnalyticsEventName("practice_to_online")
    public static let gameCenterPrompt = AnalyticsEventName("game_center_prompt")
    // Matchmaking and netcode.
    public static let queueWait = AnalyticsEventName("queue_wait")
    public static let briefingLeave = AnalyticsEventName("briefing_leave")
    public static let drop = AnalyticsEventName("drop")
    public static let rejoin = AnalyticsEventName("rejoin")
    /// The RTT distribution and time over the 250 ms warning, per race.
    public static let roundTrip = AnalyticsEventName("round_trip")
    // Liveries.
    public static let liveryTryOn = AnalyticsEventName("livery_try_on")
}

public enum AnalyticsValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
}

public struct AnalyticsEvent: Equatable, Sendable {
    /// This install's count of events, from 1, increasing: how the server recognises one it already has.
    public var sequence: Int
    public var name: AnalyticsEventName
    /// When it happened, seconds since the epoch, as the device's clock said.
    public var time: Int64
    public var properties: [String: AnalyticsValue]

    public init(sequence: Int, name: AnalyticsEventName, time: Int64, properties: [String: AnalyticsValue] = [:]) {
        self.sequence = sequence
        self.name = name
        self.time = time
        self.properties = properties
    }
}

public struct AnalyticsBatch: Equatable, Sendable {
    public var installID: InstallID
    public var events: [AnalyticsEvent]

    public init(installID: InstallID, events: [AnalyticsEvent]) {
        self.installID = installID
        self.events = events
    }

    /// The most events one batch may carry.
    public static let maxEvents = 100
}

/// What the server made of a batch.
public struct AnalyticsReceipt: Equatable, Sendable {
    /// Events recorded for the first time.
    public var accepted: Int
    /// Events the server already had (same install and sequence), recorded once: resending is safe.
    public var duplicates: Int

    public init(accepted: Int, duplicates: Int) {
        self.accepted = accepted
        self.duplicates = duplicates
    }
}

public enum AnalyticsError: Error, Equatable, Sendable {
    /// Over `AnalyticsBatch.maxEvents`: nothing recorded.
    case batchTooLarge(max: Int)
    /// The server can't be reached: nothing recorded, send it again later.
    case unavailable
}

public protocol AnalyticsTransport: Sendable {
    /// Sends a batch. The whole batch is recorded or none of it; an event already recorded counts as a duplicate.
    func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt
}

/// Share usage data (#28): passes batches on while `isSharing` says so, and otherwise sends nothing, reporting
/// nothing accepted.
public struct SharingGatedTransport<Base: AnalyticsTransport>: AnalyticsTransport {
    public let base: Base
    public let isSharing: @Sendable () -> Bool

    public init(_ base: Base, isSharing: @escaping @Sendable () -> Bool) {
        self.base = base
        self.isSharing = isSharing
    }

    public func send(_ batch: AnalyticsBatch) async throws -> AnalyticsReceipt {
        guard isSharing() else { return AnalyticsReceipt(accepted: 0, duplicates: 0) }
        return try await base.send(batch)
    }
}
