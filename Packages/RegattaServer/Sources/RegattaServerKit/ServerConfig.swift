import Crypto
import Foundation
import Persistence
import RaceHost
import RegattaCore
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
/// | `QUEUE_LOCK_SECONDS` | `60` | seconds from the oldest queued player's join to fleet lock (#146); short for the contract runner |
/// | `CATCH_FINISHERS` | on | `off`: no hold on the lock for a running race's finishers (G2, #147); the contract runner's server |
/// | `CATCH_FINISHERS_OFFSET_SECONDS` | `15` | a held lock comes this long after the running race's expected close (G2) |
/// | `CATCH_FINISHERS_MAX_HOLD_SECONDS` | `180` | the oldest queued player's longest wait, join to lock, for a hold (G2) |
/// | `SIMULTANEOUS_LOSS_POLICY` | `cancel` | a mass drop (G3): `cancel` (no results, no rating) or `ret` (RET in leave order, rated per #30) (#148) |
/// | `CLIENT_ADDRESS_HEADER` | none | the header a trusted reverse proxy sets to the client's address (`Fly-Client-IP`, `X-Forwarded-For`); the per-address connection caps count it instead of the socket's address. Unset: no header is trusted (#469) |
/// | `CLIENT_ADDRESS_TRUSTED_HOPS` | `1` | with `CLIENT_ADDRESS_HEADER`: which entry of a list header, from the right, is the client's (one per trusted proxy in the chain) (#469) |
/// | `RATING_WEIGHT_EXPONENT` | `0.5` | a rated race with m opponents weighs each of its games m^-x (ADR 0012): 0.5 is 1/√m; 0…1 (#151) |
/// | `COVERED_FINISH_GRACE_SECONDS` | `60` | a finish the cautious bot sails for a dropped player counts for her rating if she dropped less than this before it, else she is rated as retired; 0…3600 (#150) |
/// | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PEM`, `GC_LEADERBOARD_ID` | none | the App Store Connect team key (id, issuer, a PEM file of its P-256 private key) and the Game Center leaderboard's id: all four, or none (no leaderboard mirror) (#151, #55) |
/// | `GC_LEADERBOARD_RESOURCE_ID` | none | the leaderboard's App Store Connect resource id: with the four above, a deleted player's scores are blocked (#160); without it, deletions wait to be blocked |
/// | `LEADERBOARD_SWEEP_SECONDS` | `300` | how often unsent leaderboard scores are tried again (#151) |
/// | `OPENAI_MODERATION_API_KEY` | none | the lobby's toxicity classifier (#152): asked for each free-text post that passes the word list; required outside `ENV=dev`. Without it the word list alone filters |
/// | `CHAT_EXTRA_BLOCKED_PHRASES` | none | dev only: comma-separated phrases the lobby's filter blocks besides the word list |
/// | `REGATTA_ADMIN_TOKENS` | none | the admin tool (#154): comma-separated `id:token` pairs, each token 32 characters or more; the admin's id is recorded with each action. Unset: no `/admin/` routes |
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
    /// How often the server pings a seated race connection to time its round trip (#157, #31).
    public var roundTripPingInterval: Duration = .seconds(2)
    /// Identity, sessions and the Terms of Use (#145).
    public var identity = IdentitySettings()
    /// Connections held at once on `/service` and `/race`, per address and in all (#146).
    public var connectionLimits = ConnectionLimits()
    /// Whose address a connection is counted under: the socket's, or a trusted proxy's header (#469).
    public var clientAddress = ClientAddressRule()
    /// The queue and the races it locks (#146).
    public var queue = QueueSettings()
    /// Races from fleet lock to the close (#148): the all-gone rules and the mass-drop policy.
    public var lifecycle = RaceLifecycleSettings()
    /// The Game Center leaderboard mirror (#151); nil: off.
    public var leaderboard: AppStoreConnectConfig?
    public var leaderboardMirror = LeaderboardMirrorSettings()
    /// The lobby (#152): its limits, the classifier's key and a dev server's extra blocked phrases.
    public var chat = ChatSettings()
    /// Usage analytics (#156): ingest limits, segments, the roll-up and the 90-day purge.
    public var analytics = AnalyticsSettings()
    /// The admin tool (#154): who may use it.
    public var admin = AdminSettings()

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
        config.queue.lockAfter = TimeInterval(try int("QUEUE_LOCK_SECONDS", default: 60, in: 1...600))
        switch env["CATCH_FINISHERS"] {
        case nil, "on": config.queue.catchFinishers = CatchFinishers(
            offset: TimeInterval(try int("CATCH_FINISHERS_OFFSET_SECONDS", default: 15, in: 0...300)),
            maxHold: TimeInterval(try int("CATCH_FINISHERS_MAX_HOLD_SECONDS", default: 180, in: 0...1800)))
        case "off": config.queue.catchFinishers = nil
        case let value?: throw .invalid(variable: "CATCH_FINISHERS", value: value, expected: "on or off")
        }
        if let policy = env["SIMULTANEOUS_LOSS_POLICY"] {
            guard let value = SimultaneousLossPolicy(rawValue: policy) else {
                throw .invalid(variable: "SIMULTANEOUS_LOSS_POLICY", value: policy,
                               expected: SimultaneousLossPolicy.allCases.map(\.rawValue).joined(separator: " or "))
            }
            config.lifecycle.allGone.simultaneousLossPolicy = value
        }
        if let header = env["CLIENT_ADDRESS_HEADER"] {
            let token = header.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
            guard !header.isEmpty, token else {
                throw .invalid(variable: "CLIENT_ADDRESS_HEADER", value: header, expected: "a header name, such as Fly-Client-IP or X-Forwarded-For")
            }
            config.clientAddress = ClientAddressRule(header: header, trustedHops: try int("CLIENT_ADDRESS_TRUSTED_HOPS", default: 1, in: 1...16))
        } else if let hops = env["CLIENT_ADDRESS_TRUSTED_HOPS"] {
            throw .invalid(variable: "CLIENT_ADDRESS_TRUSTED_HOPS", value: hops, expected: "CLIENT_ADDRESS_HEADER to be set with it")
        }
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
        if let text = env["COVERED_FINISH_GRACE_SECONDS"] {
            guard let seconds = Int(text), (0...3600).contains(seconds) else {
                throw .invalid(variable: "COVERED_FINISH_GRACE_SECONDS", value: text, expected: "whole seconds in 0...3600")
            }
            config.lifecycle.coveredFinishGraceTicks = seconds * Race.tickRate
        }
        if let text = env["RATING_WEIGHT_EXPONENT"] {
            guard let exponent = Double(text), (0...1).contains(exponent) else {
                throw .invalid(variable: "RATING_WEIGHT_EXPONENT", value: text, expected: "a number in 0...1")
            }
            config.lifecycle.rating.weightExponent = exponent
        }
        let mirror = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PEM", "GC_LEADERBOARD_ID"]
        let given = mirror.filter { !(env[$0] ?? "").isEmpty }
        if given.count == mirror.count {
            let path = env["ASC_PRIVATE_KEY_PEM"] ?? ""
            guard let pem = try? String(contentsOfFile: path, encoding: .utf8), (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else {
                throw .invalid(variable: "ASC_PRIVATE_KEY_PEM", value: path, expected: "a readable PEM file of a P-256 private key")
            }
            config.leaderboard = AppStoreConnectConfig(keyID: env["ASC_KEY_ID"] ?? "", issuerID: env["ASC_ISSUER_ID"] ?? "", privateKeyPEM: pem,
                                                       leaderboardID: env["GC_LEADERBOARD_ID"] ?? "", bundleID: config.identity.bundleID,
                                                       leaderboardResourceID: env["GC_LEADERBOARD_RESOURCE_ID"].flatMap { $0.isEmpty ? nil : $0 })
        } else if !given.isEmpty, let missing = mirror.first(where: { !given.contains($0) }) {
            throw .invalid(variable: missing, value: "(unset)", expected: "all of \(mirror.joined(separator: ", ")), or none")
        }
        config.leaderboardMirror.sweepInterval = .seconds(try int("LEADERBOARD_SWEEP_SECONDS", default: 300, in: 5...86_400))
        if let key = env["OPENAI_MODERATION_API_KEY"], !key.isEmpty {
            config.chat.moderationKey = key
        } else if !environment.isDev {
            throw .invalid(variable: "OPENAI_MODERATION_API_KEY", value: "(unset)", expected: "the moderation key outside ENV=dev")
        }
        if environment.isDev, let phrases = env["CHAT_EXTRA_BLOCKED_PHRASES"] {
            config.chat.extraBlockedPhrases = phrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let text = env["REGATTA_ADMIN_TOKENS"], !text.isEmpty {
            guard let tokens = AdminSettings.parse(text) else {
                throw .invalid(variable: "REGATTA_ADMIN_TOKENS", value: "(hidden)",
                               expected: "comma-separated id:token pairs, each id once and each token \(AdminSettings.minTokenLength) characters or more")
            }
            config.admin.tokens = tokens
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

/// The lobby's chat (#152).
public struct ChatSettings: Sendable {
    public var lobby = LobbySettings()
    /// `OPENAI_MODERATION_API_KEY` (#51): the toxicity classifier is asked only when it is set. Without it (dev only)
    /// free text is filtered by the word list alone.
    public var moderationKey: String?
    /// `CHAT_EXTRA_BLOCKED_PHRASES` (dev only, comma-separated): phrases the filter blocks besides the word list, so
    /// the contract runner has one that is safe to print. Ignored outside `ENV=dev`.
    public var extraBlockedPhrases: [String] = []

    public init() {}
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
