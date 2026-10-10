import Foundation
import PostgresNIO

/// One numbered schema change: statements that make it (`up`) and statements that undo it (`down`), each run as
/// its own statement in one transaction (PostgresNIO's extended protocol takes one statement per query).
public struct Migration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let up: [String]
    public let down: [String]

    public init(version: Int, name: String, up: [String], down: [String]) {
        self.version = version
        self.name = name
        self.up = up
        self.down = down
    }
}

public extension Migration {
    /// The server's schema, in order (ADR 0009). A released migration never changes: a change is a new one.
    static let all: [Migration] = [.players, .sessions, .dataFiles, .raceRegistry, .raceLogs, .identity, .raceResults]
}

/// Runs the numbered migrations against a database and records each applied one in `schema_migrations`
/// (ADR 0009: PostgresNIO has no migration runner). Each `up()` or `down(to:)` is one transaction, under an
/// advisory lock, so two servers starting at once apply a migration once and a failed one leaves nothing behind.
public struct Migrator: Sendable {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        /// Versions must run 1, 2, 3, … with no gap or repeat.
        case versionOutOfSequence(expected: Int, found: Int)
        case emptyMigration(version: Int)

        public var description: String {
            switch self {
            case .versionOutOfSequence(let expected, let found): "migration \(found) is out of sequence: expected \(expected)"
            case .emptyMigration(let version): "migration \(version) has no up or no down statements"
            }
        }
    }

    public enum MigrationError: Error, Equatable, CustomStringConvertible {
        /// The database has a migration this build doesn't know: a newer server migrated it.
        case unknownAppliedVersion(Int)
        case targetOutOfRange(Int)

        public var description: String {
            switch self {
            case .unknownAppliedVersion(let version): "the database has migration \(version), which this server doesn't know"
            case .targetOutOfRange(let version): "no migration \(version) to go down to"
            }
        }
    }

    public let migrations: [Migration]

    public init(migrations: [Migration] = Migration.all) throws(ValidationError) {
        try Self.validate(migrations)
        self.migrations = migrations
    }

    public static func validate(_ migrations: [Migration]) throws(ValidationError) {
        for (index, migration) in migrations.enumerated() {
            guard migration.version == index + 1 else {
                throw .versionOutOfSequence(expected: index + 1, found: migration.version)
            }
            guard !migration.up.isEmpty, !migration.down.isEmpty else { throw .emptyMigration(version: migration.version) }
        }
    }

    /// The versions to apply, in order, given the applied ones.
    public func pending(applied: Set<Int>) throws(MigrationError) -> [Migration] {
        if let unknown = applied.subtracting(migrations.map(\.version)).min() { throw .unknownAppliedVersion(unknown) }
        return migrations.filter { !applied.contains($0.version) }
    }

    /// The versions to revert, newest first, to leave the database at `target` (0 = empty).
    public func reverting(applied: Set<Int>, to target: Int) throws(MigrationError) -> [Migration] {
        guard (0...migrations.count).contains(target) else { throw .targetOutOfRange(target) }
        if let unknown = applied.subtracting(migrations.map(\.version)).min() { throw .unknownAppliedVersion(unknown) }
        return migrations.filter { $0.version > target && applied.contains($0.version) }.reversed()
    }

    /// Applies every pending migration. Returns the versions applied.
    @discardableResult
    public func up(_ database: Database) async throws -> [Int] {
        try await database.transaction { connection in
            let applied = try await Self.lockAndReadApplied(connection, logger: database.logger)
            var done: [Int] = []
            for migration in try pending(applied: applied) {
                for statement in migration.up {
                    try await connection.query(PostgresQuery(unsafeSQL: statement), logger: database.logger)
                }
                try await connection.query(
                    "INSERT INTO schema_migrations (version, name) VALUES (\(migration.version), \(migration.name))",
                    logger: database.logger)
                done.append(migration.version)
            }
            return done
        }
    }

    /// Reverts applied migrations newer than `target`, newest first; `down(to: 0)` leaves only the empty
    /// `schema_migrations` table. Returns the versions reverted.
    @discardableResult
    public func down(_ database: Database, to target: Int) async throws -> [Int] {
        try await database.transaction { connection in
            let applied = try await Self.lockAndReadApplied(connection, logger: database.logger)
            var done: [Int] = []
            for migration in try reverting(applied: applied, to: target) {
                for statement in migration.down {
                    try await connection.query(PostgresQuery(unsafeSQL: statement), logger: database.logger)
                }
                try await connection.query("DELETE FROM schema_migrations WHERE version = \(migration.version)",
                                           logger: database.logger)
                done.append(migration.version)
            }
            return done
        }
    }

    /// The applied versions, ascending.
    public func applied(_ database: Database) async throws -> [Int] {
        try await database.transaction { connection in
            try await Self.lockAndReadApplied(connection, logger: database.logger).sorted()
        }
    }

    /// Takes the migration lock for this transaction (keyed by the schema, so the tests' schemas don't wait on
    /// each other), makes `schema_migrations` if it's missing and reads it.
    private static func lockAndReadApplied(_ connection: PostgresConnection, logger: Logger) async throws -> Set<Int> {
        try await connection.query("SELECT pg_advisory_xact_lock(hashtext('regatta.migrations.' || current_schema()))",
                                   logger: logger)
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version integer PRIMARY KEY,
                name text NOT NULL,
                applied_at timestamptz NOT NULL DEFAULT now()
            )
            """, logger: logger)
        var applied: Set<Int> = []
        for try await version in try await connection.query("SELECT version FROM schema_migrations", logger: logger)
            .decode(Int.self) {
            applied.insert(version)
        }
        return applied
    }
}
