import Foundation
import NIOHTTP1
import RaceHost
import RegattaCore
import RegattaDevAPI
import RegattaProtocol

/// The server's plain HTTP routes (the race WebSocket is `/race`, taken at the upgrade). Pure: which route
/// a request is, given the environment. Outside `ENV=dev` the dev routes don't exist: 404, as for any
/// unknown path, so nothing tells a caller they are there.
public enum Route: Hashable, Sendable {
    case health
    case instantRace
    /// `/race` without a WebSocket upgrade.
    case upgradeRequired
    case methodNotAllowed
    case notFound

    public static func resolve(method: HTTPMethod, path: String, environment: ServerEnvironment) -> Route {
        switch path {
        case ServerPath.health:
            return method == .GET || method == .HEAD ? .health : .methodNotAllowed
        case ServerPath.instantRace where environment.servesDevEndpoints:
            return method == .POST ? .instantRace : .methodNotAllowed
        case ServerPath.race:
            return .upgradeRequired
        default:
            return .notFound
        }
    }
}

/// An HTTP answer: status and JSON body.
public struct HTTPReply: Sendable {
    public var status: HTTPResponseStatus
    public var body: [UInt8]

    init(_ status: HTTPResponseStatus, json: some Encodable) {
        self.status = status
        body = (try? Array(JSONEncoder.sorted.encode(json))) ?? []
    }

    init(_ status: HTTPResponseStatus, error: String) {
        self.init(status, json: ["error": error])
    }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// Answers the plain HTTP routes: the health check and the dev instant race.
public struct RequestHandler: Sendable {
    public let config: ServerConfig
    public let registry: RaceRegistry
    /// Unix seconds now, for token expiry.
    let now: @Sendable () -> Int64

    public init(config: ServerConfig, registry: RaceRegistry,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.config = config
        self.registry = registry
        self.now = now
    }

    public func respond(method: HTTPMethod, uri: String) async -> HTTPReply {
        let (path, query) = Self.split(uri)
        switch Route.resolve(method: method, path: path, environment: config.environment) {
        case .health:
            return HTTPReply(.ok, json: HealthStatus(status: "ok", environment: config.environment.name,
                                                     serverBuild: config.serverBuild,
                                                     simulationVersion: RegattaCore.simulationVersion,
                                                     protocolVersion: Int(wireProtocolVersion),
                                                     races: await registry.count))
        case .instantRace:
            return await instantRace(query: query)
        case .upgradeRequired:
            return HTTPReply(.upgradeRequired, error: "\(ServerPath.race) is a WebSocket")
        case .methodNotAllowed:
            return HTTPReply(.methodNotAllowed, error: "method not allowed")
        case .notFound:
            return HTTPReply(.notFound, error: "not found")
        }
    }

    /// Creates the race, starts it, and signs a token for each client's seat.
    private func instantRace(query: String) async -> HTTPReply {
        let request: InstantRaceRequest
        do {
            request = try InstantRaceRequest(query: query)
        } catch {
            return HTTPReply(.badRequest, error: error.message)
        }
        let session: RaceSession
        do {
            session = try RaceSession.instant(request)
        } catch {
            return HTTPReply(.badRequest, error: "\(error)")
        }
        do {
            try await registry.start(session)
        } catch {
            return HTTPReply(.serviceUnavailable, error: "too many races")
        }
        let expiry = now() + Int64(config.tokenLifetime)
        let seats = session.humanSeats.sorted()
        let tokens = seats.map {
            Data(RaceToken(raceID: session.id, seat: $0, expiresAt: expiry).signed(with: config.tokenKey)).base64EncodedString()
        }
        return HTTPReply(.created, json: InstantRaceResponse(
            raceID: session.id.uuidString, fleetSize: session.setup.fleetSize, bots: session.setup.fleetSize - seats.count,
            seats: seats, tokens: tokens, startSeconds: session.setup.startSequenceTicks / Race.tickRate,
            raceSeconds: request.raceSeconds, tokensExpireAt: expiry))
    }

    static func split(_ uri: String) -> (path: String, query: String) {
        guard let mark = uri.firstIndex(of: "?") else { return (uri, "") }
        return (String(uri[..<mark]), String(uri[uri.index(after: mark)...]))
    }
}
