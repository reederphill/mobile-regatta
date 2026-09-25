import Foundation

/// The server's HTTP paths (#67). One port serves all of them; `/race` is the WebSocket.
public enum ServerPath {
    public static let health = "/health"
    /// The race WebSocket: `Hello`, then `JoinRace` with a race token, then the race (#18).
    public static let race = "/race"
    /// `POST`, dev only (`ENV=dev`): a race now, for the clients asking and bots. Absent (404) otherwise.
    public static let instantRace = "/dev/instant-race"
}

/// What `POST /dev/instant-race` takes, as query parameters (`?clients=16&raceSeconds=20`).
public struct InstantRaceRequest: Hashable, Sendable {
    /// Human seats, 1…16. Bots fill the fleet up to `botFillTo` seats; more humans than that sail without bots.
    public var clients: Int
    /// Dev-only race-length override for e2e runs: the race closes this many seconds after the gun,
    /// where it stands, if it hasn't ended by then. Nil: it runs to its natural end.
    public var raceSeconds: Int?
    /// Seconds of start sequence before the gun. Nil: the default, 60 s.
    public var startSeconds: Int?
    /// Race and wind seed, for a reproducible race. Nil: random.
    public var seed: UInt64?

    public static let clientRange = 1...16
    public static let botFillTo = 10
    public static let raceSecondsRange = 1...3600
    public static let startSecondsRange = 1...60

    public init(clients: Int, raceSeconds: Int? = nil, startSeconds: Int? = nil, seed: UInt64? = nil) {
        self.clients = clients
        self.raceSeconds = raceSeconds
        self.startSeconds = startSeconds
        self.seed = seed
    }

    /// The request as a query string, `clients=…&…`.
    public var query: String {
        var items = ["clients=\(clients)"]
        if let raceSeconds { items.append("raceSeconds=\(raceSeconds)") }
        if let startSeconds { items.append("startSeconds=\(startSeconds)") }
        if let seed { items.append("seed=\(seed)") }
        return items.joined(separator: "&")
    }

    /// Parses and validates a query string. Throws a message a person can read.
    public init(query: String) throws(InstantRaceRequestError) {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            values[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        for key in values.keys where !["clients", "raceSeconds", "startSeconds", "seed"].contains(key) {
            throw .invalid("unknown parameter \(key)")
        }
        func int(_ key: String, in range: ClosedRange<Int>) throws(InstantRaceRequestError) -> Int? {
            guard let text = values[key] else { return nil }
            guard let value = Int(text), range.contains(value) else {
                throw .invalid("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return value
        }
        clients = try int("clients", in: Self.clientRange) ?? 1
        raceSeconds = try int("raceSeconds", in: Self.raceSecondsRange)
        startSeconds = try int("startSeconds", in: Self.startSecondsRange)
        if let text = values["seed"] {
            guard let value = UInt64(text) else { throw .invalid("seed must be an unsigned 64-bit integer") }
            seed = value
        } else {
            seed = nil
        }
    }

    /// Seats in the fleet: the clients, and bots up to `botFillTo`.
    public var fleetSize: Int { max(clients, Self.botFillTo) }
}

public enum InstantRaceRequestError: Error, Equatable, Sendable {
    case invalid(String)

    public var message: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// What `POST /dev/instant-race` answers (201): the race, and one race token per human seat. A client
/// opens `/race`, says `Hello`, and sends its token in `JoinRace` (#18).
public struct InstantRaceResponse: Codable, Hashable, Sendable {
    public var raceID: String
    public var fleetSize: Int
    public var bots: Int
    /// The human seats, in the order of `tokens`.
    public var seats: [Int]
    /// Signed race tokens (`RaceToken`), base64: one per seat in `seats`.
    public var tokens: [String]
    public var startSeconds: Int
    public var raceSeconds: Int?
    /// Unix time, in seconds, after which the tokens no longer join.
    public var tokensExpireAt: Int64

    public init(raceID: String, fleetSize: Int, bots: Int, seats: [Int], tokens: [String], startSeconds: Int,
                raceSeconds: Int?, tokensExpireAt: Int64) {
        self.raceID = raceID
        self.fleetSize = fleetSize
        self.bots = bots
        self.seats = seats
        self.tokens = tokens
        self.startSeconds = startSeconds
        self.raceSeconds = raceSeconds
        self.tokensExpireAt = tokensExpireAt
    }
}

/// What `GET /health` answers (200).
public struct HealthStatus: Codable, Hashable, Sendable {
    public var status: String
    public var environment: String
    public var serverBuild: String
    public var simulationVersion: String
    public var protocolVersion: Int
    /// Races running now.
    public var races: Int

    public init(status: String, environment: String, serverBuild: String, simulationVersion: String, protocolVersion: Int, races: Int) {
        self.status = status
        self.environment = environment
        self.serverBuild = serverBuild
        self.simulationVersion = simulationVersion
        self.protocolVersion = protocolVersion
        self.races = races
    }
}
