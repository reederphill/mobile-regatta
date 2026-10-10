import Crypto
import Foundation
import Persistence
import RegattaProtocol

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
/// | `TERMS_VERSION` | `1` | the Terms of Use version players must accept (#145); a bump re-asks |
/// | `REGATTA_BUNDLE_ID` | `com.phillreeder.regatta` | the bundle id Game Center signs (README; final in #49) |
/// | `REGATTA_TEAM_ID` | `8S5TQ65X3B` | the Apple Developer team (README; final in #49) |
/// | `REGATTA_APPLE_ROOT_PEM` | none | a PEM file of the certificates Game Center's key must chain to; unset in dev = dev verifier |
/// | `REGATTA_DATABASE_URL` | none | Postgres (ADR 0009); unset in dev = accounts in memory |
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
    /// Identity, sessions and the Terms of Use (#145).
    public var identity = IdentitySettings()
    /// Connections held at once on `/service` and `/race`, per address and in all (#146).
    public var connectionLimits = ConnectionLimits()

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
        var config = ServerConfig(environment: environment, auth: auth, host: env["HOST"] ?? "127.0.0.1", port: port,
                                  tokenKey: key, tokenLifetime: TimeInterval(lifetime),
                                  serverBuild: env["SERVER_BUILD"] ?? "dev", maxRaces: maxRaces)
        config.identity.termsVersion = try int("TERMS_VERSION", default: 1, in: 1...1_000_000)
        if let bundle = env["REGATTA_BUNDLE_ID"], !bundle.isEmpty { config.identity.bundleID = bundle }
        if let team = env["REGATTA_TEAM_ID"], !team.isEmpty { config.identity.teamID = team }
        if let path = env["REGATTA_APPLE_ROOT_PEM"], !path.isEmpty {
            guard let pem = try? String(contentsOfFile: path, encoding: .utf8), pem.contains("BEGIN CERTIFICATE") else {
                throw .invalid(variable: "REGATTA_APPLE_ROOT_PEM", value: path, expected: "a readable PEM file of certificates")
            }
            config.identity.appleRootsPEM = pem
        } else if !environment.isDev {
            throw .invalid(variable: "REGATTA_APPLE_ROOT_PEM", value: "(unset)", expected: "Apple's root outside ENV=dev")
        }
        do {
            config.identity.database = try DatabaseConfiguration.fromEnvironment(env)
        } catch {
            throw .invalid(variable: "REGATTA_DATABASE_URL", value: "(hidden)", expected: "a postgres:// URL")
        }
        return config
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

/// Identity, sessions and the Terms of Use (#145).
public struct IdentitySettings: Sendable {
    public var termsVersion = 1
    /// What Game Center signs with the teamPlayerID. README's value; #49 confirms it, #167 deploys it.
    public var bundleID = "com.phillreeder.regatta"
    /// The Apple Developer team. README's value; #49 confirms it.
    public var teamID = "8S5TQ65X3B"
    /// How far a signature's timestamp may be from now, either side.
    public var signatureFreshness: Duration = .seconds(300)
    /// The certificates Game Center's key must chain to (Apple's root, `REGATTA_APPLE_ROOT_PEM`). Nil in dev: any
    /// well-formed, fresh signature passes (`DevGameCenterVerifier`), so the contract runner reaches the server.
    public var appleRootsPEM: String?
    /// Sessions slide: this long from the last sign-in or resume.
    public var sessionLifetime: TimeInterval = 30 * 86_400
    /// No more than this long from the first sign-in or resume, however often it slides (#146, R11).
    public var absoluteSessionLifetime: TimeInterval = 90 * 86_400
    /// Sessions one player holds at once; a new one past it ends the oldest (#146, R11).
    public var maxSessionsPerPlayer = 5
    /// How often expired sessions are deleted (#146, R11).
    public var sessionSweepInterval: Duration = .seconds(3_600)
    /// A service stream nobody reads for this long is dropped.
    public var streamIdleTimeout: Duration = .seconds(60)
    /// A service connection past `Hello` that hasn't signed in this long after it is closed (#146, R4).
    public var signInDeadline: Duration = .seconds(10)
    /// A service connection with no frame either way for this long is closed (#146, R4).
    public var connectionIdleTimeout: Duration = .seconds(120)
    /// The largest service frame either way.
    public var frameCap = serviceFrameLimit
    /// Postgres, or nil: accounts in memory (dev only).
    public var database: DatabaseConfiguration?

    public init() {}
}
