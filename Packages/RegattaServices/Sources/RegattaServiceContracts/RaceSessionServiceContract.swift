import RegattaProtocol
import RegattaServices

/// What `RaceSessionService` promises (#16, #24).
public struct RaceSessionServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// The player's fleet has just locked: there's a hand-off, and no race to rejoin.
        case fleetLocked
        /// The player left a race in progress, and can take back control.
        case inProgress
        /// The player's race has finished and closed. Its results stream ends with the closed report, and its
        /// rating change is pushed. Rated: the player raced other humans.
        case closed
        /// The player's race was cancelled.
        case cancelled
        /// No fleet has locked for the player and there's no race to rejoin: none since she signed in.
        case noRace
    }

    public let name = "RaceSessionService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any RaceSessionService) async throws {
        try await handOff(makeService(.fleetLocked))
        try await rejoin(makeService(.inProgress))
        try await closedRace(makeService(.closed))
        try await cancelledRace(makeService(.cancelled))
        try await noRace(makeService(.noRace))
    }

    /// The token joins the seat, and is the same race however often it's asked for.
    private func handOff(_ service: any RaceSessionService) async throws {
        let handOff = try await service.handOff()
        try await require(!handOff.raceID.rawValue.isEmpty, "the hand-off names no race")
        try await require(!handOff.token.bytes.isEmpty, "the hand-off token is empty")
        try await require(handOff.token.joinRace.token == handOff.token.bytes, "the join message doesn't carry the token unread")
        try await require(try await service.handOff().raceID == handOff.raceID, "a second hand-off is for another race")
        try await requireThrows(RaceSessionError.noRace, "rejoin() with no race in progress") { try await service.rejoin() }
    }

    /// A rejoin offers a token for her seat and a race clock that makes sense.
    private func rejoin(_ service: any RaceSessionService) async throws {
        let offer = try await service.rejoin()
        try await require(!offer.handOff.token.bytes.isEmpty, "the rejoin token is empty")
        try await require(offer.seat >= 0, "the rejoin seat is \(offer.seat)")
        if let close = offer.clock.expectedCloseTick {
            try await require(close > offer.clock.tick, "the race is expected to close at tick \(close), before its clock's \(offer.clock.tick)")
        }
        try await require(try await service.rejoin().handOff.raceID == offer.handOff.raceID, "a second rejoin is for another race")
    }

    /// The results fill in as boats finish and end closed; her incidents involve her; the rating comes with
    /// the close; the race is her last.
    private func closedRace(_ service: any RaceSessionService) async throws {
        let (updates, closed) = await StreamReader.read(service.results()) { update in
            if case .report(let report) = update { report.isClosed } else { true }
        }
        try await require(closed, "the results stream ended before the race closed; it read \(updates.count) updates")
        var reports: [RaceReport] = []
        for update in updates {
            guard case .report(let report) = update else { try fail("a closed race's results stream says \(update)") }
            reports.append(report)
        }
        let final = reports[reports.count - 1]
        for (index, report) in reports.enumerated() {
            try await checkLive(report, isFinal: index == reports.count - 1)
            try await require(report.raceID == final.raceID && report.seat == final.seat, "the results stream switched race or seat")
            if index > 0 {
                try await require(report.results.rows.count >= reports[index - 1].results.rows.count, "a finished boat dropped out of the results")
            }
        }
        try await checkClosed(final)

        // The rating change belongs to this race, and says what the results did.
        guard let change = await StreamReader.first(of: service.ratingChanges()) else { try fail("no rating change was pushed for a closed race") }
        try await require(change.raceID == final.raceID, "the rating change is for another race")
        switch change.outcome {
        case .rated(let before, let after):
            try await require(final.results.rated, "a race the results call unrated moved the rating")
            try await require(before.value > 0 && after.value > 0, "a rating of \(before.value) -> \(after.value)")
        case .unrated:
            try await require(!final.results.rated, "a rated race left the rating unchanged")
        }

        guard let last = try await service.lastRace() else { try fail("lastRace() is nil after a closed race") }
        try await require(last.report == final, "lastRace() isn't the final report of the results stream")
        try await require(last.rating == nil || last.rating == change, "lastRace() has another rating change than the pushed one")
    }

    /// What holds of a report at any point: each seat is sailing or has a result; her incidents involve her.
    private func checkLive(_ report: RaceReport, isFinal: Bool) async throws {
        let seats = report.results.order + report.sailing
        try await require(Set(seats).count == seats.count, "a seat is both sailing and scored, or scored twice: \(seats)")
        try await require(seats.allSatisfy { report.roster.indices.contains($0) }, "a seat isn't in the roster of \(report.roster.count)")
        try await require(report.roster.indices.contains(report.seat), "her seat \(report.seat) isn't in the roster")
        try await require(report.results.rows.allSatisfy { $0.place >= 1 }, "a place below 1")
        try await require(zip(report.results.rows, report.results.rows.dropFirst()).allSatisfy { $0.place <= $1.place }, "the rows aren't in place order")
        try await require(report.incidents.map(\.seat) == report.incidents.map(\.seat).sorted(), "incidents aren't in seat order")
        for entry in report.incidents {
            try await require(entry.incidents.allSatisfy { $0.parties.contains(entry.seat) }, "seat \(entry.seat) lists an incident she isn't in")
            try await require(entry.incidents.map(\.id) == entry.incidents.map(\.id).sorted(), "seat \(entry.seat)'s incidents aren't in id order")
            try await require(entry.markTouches.allSatisfy { $0.seat == entry.seat }, "seat \(entry.seat) lists another boat's mark touch")
            try await require(entry.protests.allSatisfy { $0.protester == entry.seat }, "seat \(entry.seat) lists another boat's protest")
            try await require(entry.markTouches.map(\.tick) == entry.markTouches.map(\.tick).sorted(), "seat \(entry.seat)'s mark touches aren't in tick order")
            try await require(entry.protests.map(\.tick) == entry.protests.map(\.tick).sorted(), "seat \(entry.seat)'s protests aren't in tick order")
            try await require(entry.turnsServed >= 0, "seat \(entry.seat) served \(entry.turnsServed) turns")
        }
        try await require(report.flaggedSeats == report.flaggedSeats.sorted() && Set(report.flaggedSeats).count == report.flaggedSeats.count,
                          "the flagged seats \(report.flaggedSeats) aren't ascending and distinct")
        try await require(report.flaggedSeats.allSatisfy { report.roster.indices.contains($0) }, "a flagged seat isn't in the roster")
        try await require(report.isClosed == isFinal, "the report's closed flag is \(report.isClosed), but it's \(isFinal ? "the last" : "not the last") one")
    }

    /// At the close every seat has exactly one result and nobody is left sailing.
    private func checkClosed(_ report: RaceReport) async throws {
        try await require(report.sailing.isEmpty, "seats \(report.sailing) are still sailing in a closed race")
        try await require(report.results.rows.count == report.roster.count, "\(report.results.rows.count) results for \(report.roster.count) seats")
    }

    /// A cancelled race says so, and counts for nothing.
    private func cancelledRace(_ service: any RaceSessionService) async throws {
        let (updates, cancelled) = await StreamReader.read(service.results()) { update in
            if case .cancelled = update { true } else { false }
        }
        try await require(cancelled, "a cancelled race's results stream never said so; it read \(updates.count) updates")
        for update in updates.dropLast() {
            guard case .report(let report) = update, !report.isClosed else { try fail("\(update) before a cancellation") }
        }
        try await require(try await service.lastRace() == nil, "a cancelled race is the last race")
    }

    /// With no race, there's nothing to hand off, rejoin or show.
    private func noRace(_ service: any RaceSessionService) async throws {
        try await requireThrows(RaceSessionError.noRace, "handOff() with no fleet locked") { try await service.handOff() }
        try await requireThrows(RaceSessionError.noRace, "rejoin() with no race in progress") { try await service.rejoin() }
        try await require(try await service.lastRace() == nil, "lastRace() is set before any race")
    }
}
