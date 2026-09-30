import RegattaServices

/// What `AnalyticsTransport` promises (#28): batches are recorded whole, each event once, so resending is safe.
public struct AnalyticsTransportContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// The server records batches, and has nothing yet from `installID`.
        case accepting
        /// The server can't be reached.
        case unavailable
    }

    public let name = "AnalyticsTransport"
    /// The install the suite sends as: a runner passes a fresh one for each run.
    public let installID: InstallID

    public init(installID: InstallID = InstallID("contract-install")) { self.installID = installID }

    public func run(_ makeService: (Situation) async throws -> any AnalyticsTransport) async throws {
        let transport = try await makeService(.accepting)
        let first = batch(1...3)
        try await require(try await transport.send(first) == AnalyticsReceipt(accepted: 3, duplicates: 0), "a new batch of 3 wasn't all accepted")
        try await require(try await transport.send(first) == AnalyticsReceipt(accepted: 0, duplicates: 3), "resending a batch recorded it again")
        try await require(try await transport.send(batch(3...5)) == AnalyticsReceipt(accepted: 2, duplicates: 1), "an overlapping batch wasn't counted once")
        try await require(try await transport.send(batch(6..<6)) == AnalyticsReceipt(accepted: 0, duplicates: 0), "an empty batch recorded something")

        let tooMany = batch(100...(100 + AnalyticsBatch.maxEvents))
        try await requireThrows(AnalyticsError.batchTooLarge(max: AnalyticsBatch.maxEvents), "a batch of \(tooMany.events.count)") {
            try await transport.send(tooMany)
        }
        // Refused whole: its first event is still new.
        try await require(try await transport.send(batch(100...100)) == AnalyticsReceipt(accepted: 1, duplicates: 0), "a refused batch was partly recorded")

        let down = try await makeService(.unavailable)
        try await requireThrows(AnalyticsError.unavailable, "send() while unavailable") { try await down.send(first) }
    }

    private func batch<Sequences: Sequence<Int>>(_ sequences: Sequences) -> AnalyticsBatch {
        AnalyticsBatch(installID: installID, events: sequences.map {
            AnalyticsEvent(sequence: $0, name: .hintRetired, time: 1_790_000_000 + Int64($0), properties: ["hint": .string("tack"), "learned": .bool(true)])
        })
    }
}
