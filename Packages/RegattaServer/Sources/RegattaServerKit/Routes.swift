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
    /// `POST /dev/situation`, dev only (#145).
    case devSituation
    /// `/race` or `/service` without a WebSocket upgrade.
    case upgradeRequired
    case methodNotAllowed
    case notFound

    public static func resolve(method: HTTPMethod, path: String, environment: ServerEnvironment) -> Route {
        switch path {
        case ServerPath.health:
            return method == .GET || method == .HEAD ? .health : .methodNotAllowed
        case ServerPath.instantRace where environment.servesDevEndpoints:
            return method == .POST ? .instantRace : .methodNotAllowed
        case ServerPath.devSituation where environment.servesDevEndpoints:
            return method == .POST ? .devSituation : .methodNotAllowed
        case ServerPath.race, ServerPath.service:
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
    /// The service endpoint (#145), when the server has one.
    public let services: ServiceEndpoint?
    /// Unix seconds now, for token expiry.
    let now: @Sendable () -> Int64

    public init(config: ServerConfig, registry: RaceRegistry, services: ServiceEndpoint? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.config = config
        self.registry = registry
        self.services = services
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
        case .devSituation:
            guard let services else { return HTTPReply(.notFound, error: "not found") }
            guard let request = DevSituationRequest(query: query) else {
                return HTTPReply(.badRequest, error: "service, situation, teamPlayerID and gamePlayerID are required")
            }
            return await services.arrange(request)
        case .upgradeRequired:
            return HTTPReply(.upgradeRequired, error: "\(path) is a WebSocket")
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
        let expiry = now() + Int64(config.tokenLifetime)
        let seats = session.humanSeats.sorted()
        var tokens: [String] = []
        for seat in seats {
            guard let token = RaceToken(raceID: session.id, seat: seat, expiresAt: expiry).signed(with: config.tokenKey) else {
                return HTTPReply(.internalServerError, error: "seat \(seat) doesn't fit a race token")
            }
            tokens.append(Data(token).base64EncodedString())
        }
        do {
            try await registry.start(session)
        } catch {
            return HTTPReply(.serviceUnavailable, error: "too many races")
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
