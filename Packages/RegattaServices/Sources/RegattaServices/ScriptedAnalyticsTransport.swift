/// A server-side analytics sink in memory: records each (install, sequence) once, or refuses everything while
/// unavailable.
public actor ScriptedAnalyticsTransport: AnalyticsTransport {
    private let isAvailable: Bool
    private var seen: Set<String> = []
    /// Every event recorded, in the order it arrived, for tests.
    public private(set) var recorded: [AnalyticsEvent] = []

    public init(isAvailable: Bool = true) { self.isAvailable = isAvailable }

    public func send(_ batch: AnalyticsBatch) throws -> AnalyticsReceipt {
        guard isAvailable else { throw AnalyticsError.unavailable }
        guard batch.events.count <= AnalyticsBatch.maxEvents else { throw AnalyticsError.batchTooLarge(max: AnalyticsBatch.maxEvents) }
        var receipt = AnalyticsReceipt(accepted: 0, duplicates: 0)
        for event in batch.events {
            if seen.insert("\(batch.installID.rawValue)#\(event.sequence)").inserted {
                recorded.append(event)
                receipt.accepted += 1
            } else {
                receipt.duplicates += 1
            }
        }
        return receipt
    }
}
