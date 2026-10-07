import Foundation
import Logging
import PostgresNIO

/// Where the server's Postgres is and how to reach it (#144, ADR 0009), read from a `postgres://` URL:
/// `REGATTA_DATABASE_URL` for the server, `REGATTA_TEST_DATABASE_URL` for the tests.
///
///     postgres://user[:password]@host[:port][/database][?sslmode=disable|prefer|require]
///
/// `sslmode` defaults to `disable` (the test databases and CI's service container speak plain TCP). Hosting and
/// credentials for production are a later ticket's; this only reads the URL.
public struct DatabaseConfiguration: Sendable, Equatable {
    public enum TLSMode: String, Sendable, Equatable { case disable, prefer, require }

    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String?
    public var tls: TLSMode
    /// Set as the connections' `search_path`: the tests give each run its own schema.
    public var searchPath: String?

    public init(host: String, port: Int = 5432, username: String, password: String? = nil, database: String? = nil,
                tls: TLSMode = .disable, searchPath: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.searchPath = searchPath
    }

    public enum URLError: Error, Equatable, CustomStringConvertible {
        /// Carries nothing of the URL, which may hold a password.
        case malformed
        case unsupportedScheme(String)
        case missingHost
        case missingUser
        case unsupportedSSLMode(String)

        public var description: String {
            switch self {
            case .malformed: "the database URL isn't a URL"
            case .unsupportedScheme(let scheme): "the database URL's scheme is \(scheme), not postgres or postgresql"
            case .missingHost: "the database URL names no host"
            case .missingUser: "the database URL names no user"
            case .unsupportedSSLMode(let mode): "the database URL's sslmode \(mode) isn't disable, prefer or require"
            }
        }
    }

    /// Parses a `postgres://` or `postgresql://` URL. The message of a thrown error never repeats the URL, which
    /// may carry a password.
    public init(url string: String) throws(URLError) {
        guard let components = URLComponents(string: string), let scheme = components.scheme else {
            throw .malformed
        }
        guard scheme == "postgres" || scheme == "postgresql" else { throw .unsupportedScheme(scheme) }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        guard let user = components.user, !user.isEmpty else { throw .missingUser }
        var tls = TLSMode.disable
        if let mode = components.queryItems?.first(where: { $0.name == "sslmode" })?.value {
            guard let parsed = TLSMode(rawValue: mode) else { throw .unsupportedSSLMode(mode) }
            tls = parsed
        }
        let path = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        self.init(host: host, port: components.port ?? 5432, username: user.removingPercentEncoding ?? user,
                  password: components.password.map { $0.removingPercentEncoding ?? $0 },
                  database: path.isEmpty ? nil : path, tls: tls)
    }

    /// The server's database, from `REGATTA_DATABASE_URL`, or nil when it's unset.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                       key: String = "REGATTA_DATABASE_URL") throws(URLError) -> DatabaseConfiguration? {
        guard let url = environment[key], !url.isEmpty else { return nil }
        return try DatabaseConfiguration(url: url)
    }

    var clientConfiguration: PostgresClient.Configuration {
        let clientTLS: PostgresClient.Configuration.TLS = switch tls {
        case .disable: .disable
        case .prefer: .prefer(.makeClientConfiguration())
        case .require: .require(.makeClientConfiguration())
        }
        var configuration = PostgresClient.Configuration(host: host, port: port, username: username,
                                                         password: password, database: database, tls: clientTLS)
        if let searchPath {
            configuration.options.additionalStartupParameters = [("search_path", searchPath)]
        }
        return configuration
    }
}

/// The server's connection pool: PostgresNIO's `PostgresClient`, which runs while `run()` does. `withDatabase`
/// runs it around a closure; a long-lived server runs `run()` in its own task (#145).
public final class Database: Sendable {
    public let client: PostgresClient
    public let logger: Logger

    public init(_ configuration: DatabaseConfiguration, logger: Logger = Logger(label: "regatta.persistence")) {
        self.logger = logger
        client = PostgresClient(configuration: configuration.clientConfiguration, backgroundLogger: logger)
    }

    /// Runs the pool until the calling task is cancelled.
    public func run() async { await client.run() }

    /// Opens a pool, runs `body` with it, then closes the pool.
    public static func withDatabase<T: Sendable>(
        _ configuration: DatabaseConfiguration,
        logger: Logger = Logger(label: "regatta.persistence"),
        _ body: @Sendable (Database) async throws -> T
    ) async throws -> T {
        let database = Database(configuration, logger: logger)
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await database.run() }
            defer { group.cancelAll() }
            return try await body(database)
        }
    }

    /// Runs `body` in one transaction: committed when it returns, rolled back when it throws. A rolled-back
    /// body's own error is rethrown as itself, not wrapped in PostgresNIO's transaction error.
    func transaction<T: Sendable>(_ body: (PostgresConnection) async throws -> T) async throws -> T {
        do {
            return try await client.withTransaction(logger: logger) { connection in try await body(connection) }
        } catch let error as PostgresTransactionError {
            if let closureError = error.closureError, error.rollbackError == nil { throw closureError }
            throw error
        }
    }
}
