import Crypto
import Foundation

/// The deployment the server runs in: the `ENV` variable. Only `dev` exists for now (#67): the server has
/// dev auth and nothing else, so it refuses to start anywhere else, and the dev endpoints (the instant
/// race) exist only here. One pure check for both, so tests can assert each refusal.
public enum ServerEnvironment: Hashable, Sendable {
    case dev
    /// Any other value of `ENV`, or nil if it's unset.
    case other(String?)

    public init(env value: String?) {
        self = value == "dev" ? .dev : .other(value)
    }

    public var isDev: Bool { self == .dev }

    /// Whether dev-only endpoints (`POST /dev/instant-race`) exist. Outside dev they are absent: 404.
    public var servesDevEndpoints: Bool { isDev }

    public var name: String {
        switch self {
        case .dev: "dev"
        case .other(let value): value ?? "(unset)"
        }
    }
}

/// How the server decides a connection may sail. Only dev auth exists (#67): any client that passes the
/// handshake's version checks may join the seat its race token names, with no account and no App Attest
/// (#158). It is allowed only in `ENV=dev`: that is the startup refusal.
public enum SeatAuthPolicy: Hashable, Sendable {
    case dev

    /// The policy for `environment`, or the refusal to start.
    public static func `for`(_ environment: ServerEnvironment) throws(ServerConfigError) -> SeatAuthPolicy {
        guard environment.isDev else { throw .devAuthOutsideDev(environment.name) }
        return .dev
    }
}

public enum ServerConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Dev auth is all there is, and `ENV` isn't `dev`.
    case devAuthOutsideDev(String)
    case invalid(variable: String, value: String, expected: String)

    public var description: String {
        switch self {
        case .devAuthOutsideDev(let env):
            "RegattaServer has dev auth only and refuses to start unless ENV=dev (ENV is \(env))."
        case .invalid(let variable, let value, let expected):
            "\(variable)=\(value) is invalid: expected \(expected)."
        }
    }
}

/// Everything the server is started with, from the process environment.
///
/// | variable | default | |
/// |---|---|---|
/// | `ENV` | none | must be `dev` |
/// | `HOST` | `127.0.0.1` | address to bind; the container sets `0.0.0.0` |
/// | `PORT` | `8080` | 0 picks a free port |
/// | `RACE_TOKEN_SECRET` | random per process | HMAC key for race tokens |
/// | `RACE_TOKEN_TTL` | `600` | seconds a race token joins for |
/// | `SERVER_BUILD` | `dev` | reported in `HelloAck` and `/health` |
/// | `MAX_RACES` | `64` | races at once |
public struct ServerConfig: Sendable {
    public var environment: ServerEnvironment
    public var auth: SeatAuthPolicy
    public var host: String
    public var port: Int
    public var tokenKey: SymmetricKey
    public var tokenLifetime: TimeInterval
    public var serverBuild: String
    public var maxRaces: Int
    /// How long a race connection has to send `Hello` and `JoinRace` before it's closed (policy violation).
    public var handshakeTimeout: Duration = .seconds(10)

    /// A dev config: dev auth, the given port (0 for a free one), a random token key.
    public static func dev(host: String = "127.0.0.1", port: Int = 0) -> ServerConfig {
        ServerConfig(environment: .dev, auth: .dev, host: host, port: port, tokenKey: SymmetricKey(size: .bits256),
                     tokenLifetime: 600, serverBuild: "dev", maxRaces: 64)
    }

    /// The config the environment describes, or why the server must not start.
    public static func load(from env: [String: String]) throws(ServerConfigError) -> ServerConfig {
        let environment = ServerEnvironment(env: env["ENV"])
        let auth = try SeatAuthPolicy.for(environment)
        func int(_ name: String, default value: Int, in range: ClosedRange<Int>) throws(ServerConfigError) -> Int {
            guard let text = env[name] else { return value }
            guard let parsed = Int(text), range.contains(parsed) else {
                throw .invalid(variable: name, value: text, expected: "an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return parsed
        }
        let port = try int("PORT", default: 8080, in: 0...65535)
        let lifetime = try int("RACE_TOKEN_TTL", default: 600, in: 1...86_400)
        let maxRaces = try int("MAX_RACES", default: 64, in: 1...10_000)
        let key: SymmetricKey
        if let secret = env["RACE_TOKEN_SECRET"] {
            guard secret.utf8.count >= 16 else {
                throw .invalid(variable: "RACE_TOKEN_SECRET", value: "(hidden)", expected: "at least 16 bytes")
            }
            key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        } else {
            key = SymmetricKey(size: .bits256)
        }
        return ServerConfig(environment: environment, auth: auth, host: env["HOST"] ?? "127.0.0.1", port: port,
                            tokenKey: key, tokenLifetime: TimeInterval(lifetime),
                            serverBuild: env["SERVER_BUILD"] ?? "dev", maxRaces: maxRaces)
    }

    public init(environment: ServerEnvironment, auth: SeatAuthPolicy, host: String, port: Int, tokenKey: SymmetricKey,
                tokenLifetime: TimeInterval, serverBuild: String, maxRaces: Int) {
        self.environment = environment
        self.auth = auth
        self.host = host
        self.port = port
        self.tokenKey = tokenKey
        self.tokenLifetime = tokenLifetime
        self.serverBuild = serverBuild
        self.maxRaces = maxRaces
    }
}
