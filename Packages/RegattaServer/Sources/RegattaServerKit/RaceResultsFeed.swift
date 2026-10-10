import Foundation
import RaceHost
import RegattaCore
import RegattaProtocol
import RegattaServices

// The results a player sees (#24, #148): her `RaceReport`, built from the host's results so far while the race runs and
// from the stored results once it has closed. Pure: no clock, no randomness, seats and incidents in the order the
// `RaceSessionServiceContract` asks (seat order; incidents by id, touches and protests by tick).

/// A closed race's results as stored (`race_results.results`): what the results stream's last report and the last
/// race are both built from, so they are the same report. Canonical JSON (sorted keys).
public struct RaceSummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var colorIndex: Int
    }

    public struct Row: Codable, Sendable, Equatable {
        public var seat: Int
        public var place: Int
        /// `ResultCode`'s raw value.
        public var code: String
        public var finishTick: Int?
    }

    /// The venue's display name, for the winner line.
    public var venue: String
    public var roster: [Entry]
    public var rows: [Row]
    public var rated: Bool
    /// Penalty turns each seat completed, by seat.
    public var turnsServed: [Int]

    public init(venue: String, roster: [RosterEntry], results: RaceResults, turnsServed: [Int]) {
        self.venue = venue
        self.roster = roster.map { Entry(name: $0.name, colorIndex: $0.colorIndex) }
        rows = results.rows.map { Row(seat: $0.seat, place: $0.place, code: $0.code.rawValue, finishTick: $0.finishTick) }
        rated = results.rated
        self.turnsServed = turnsServed
    }

    public var rosterEntries: [RosterEntry] { roster.map { RosterEntry(name: $0.name, colorIndex: $0.colorIndex) } }

    public var results: RaceResults {
        RaceResults(rows: rows.map { SeatResult(seat: $0.seat, place: $0.place, code: ResultCode(rawValue: $0.code) ?? .ret,
                                                finishTick: $0.finishTick) },
                    rated: rated)
    }

    /// The lobby's line at the close (#36, owner 2026-10-09: one "X won" line): the first row's sailor, unless nobody
    /// sailed it to the end (a RET at the top).
    public var winnerLine: SystemLine? {
        guard let first = rows.first, first.code != ResultCode.ret.rawValue, roster.indices.contains(first.seat) else { return nil }
        return .winner(venue: venue, nickname: roster[first.seat].name)
    }

    public func encoded() throws -> Data { try RaceResultsFeed.encoder.encode(self) }

    public init(decoding data: Data) throws { self = try JSONDecoder().decode(RaceSummary.self, from: data) }
}

public enum RaceResultsFeed {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// The incident index's stored bytes (`race_results.incidents`).
    public static func encode(_ incidents: IncidentIndex) throws -> Data { try encoder.encode(incidents) }

    public static func decodeIncidents(_ data: Data) throws -> IncidentIndex { try JSONDecoder().decode(IncidentIndex.self, from: data) }

    /// The service's name for a race: its id, lower case (as the hand-off's).
    public static func raceID(_ id: UUID) -> RaceID { RaceID(id.uuidString.lowercased()) }

    /// The report at `seat` while the race runs: the finishers so far, everyone else sailing (a disqualified boat
    /// shows at the close), her own incidents. Unrated until the close says otherwise.
    public static func live(_ race: UUID, seat: Int, roster: [RosterEntry], results live: LiveResults) -> RaceReport {
        if let results = live.results {
            return report(race, seat: seat, roster: roster, results: results, sailing: [], incidents: live.incidents,
                          turnsServed: live.turnsServed, isClosed: false)
        }
        return report(race, seat: seat, roster: roster, results: RaceResults(rows: live.finishers, rated: false), sailing: live.sailing,
                      incidents: live.incidents, turnsServed: live.turnsServed, isClosed: false)
    }

    /// The closed race's report at `seat`, from what was stored.
    public static func closed(_ race: UUID, seat: Int, summary: RaceSummary, incidents: IncidentIndex) -> RaceReport {
        report(race, seat: seat, roster: summary.rosterEntries, results: summary.results, sailing: [], incidents: incidents,
               turnsServed: summary.turnsServed, isClosed: true)
    }

    private static func report(_ race: UUID, seat: Int, roster: [RosterEntry], results: RaceResults, sailing: [Int], incidents: IncidentIndex,
                               turnsServed: [Int], isClosed: Bool) -> RaceReport {
        let own = SeatIncidents(seat: seat, incidents: incidents.incidents(involving: seat),
                                markTouches: incidents.markTouches.filter { $0.seat == seat }.sorted { $0.tick < $1.tick },
                                protests: incidents.protests(by: seat).sorted { $0.tick < $1.tick },
                                turnsServed: turnsServed.indices.contains(seat) ? turnsServed[seat] : 0)
        return RaceReport(raceID: raceID(race), seat: seat, roster: roster, results: results, sailing: sailing, incidents: [own],
                          isClosed: isClosed, flaggedSeats: flaggedSeats(incidents))
    }

    /// Every seat a foul has been called against (#24's flag), ascending. Rule 31 mark touches aren't calls.
    static func flaggedSeats(_ incidents: IncidentIndex) -> [Int] {
        Array(Set(incidents.incidents.compactMap { incident -> Int? in
            if case .called(let call) = incident.outcome { call.offender } else { nil }
        })).sorted()
    }
}
