# Postgres for server persistence, with our own migrations

The server keeps players (keyed by Game Center id), sessions, the race registry, race logs and every released version of every data file in Postgres (#4), through the `Persistence` target of the RegattaServer package. It talks to Postgres with `postgres-nio`, pinned to a minor version in `Package.swift` and exactly in the committed `Package.resolved`, like `swift-nio` (ADR 0006). Schema changes are numbered migrations, Swift string constants in `Sources/Persistence/Migrations/`, run by our own `Migrator`: it records each applied version in `schema_migrations`, applies or reverts in one transaction under an advisory lock, and refuses a database that has a version it doesn't know. Race logs are `bytea` in the same database as their registry row.

We did this because the server already sits on SwiftNIO and `postgres-nio` is the NIO-native Postgres client (async/await, a connection pool, Swift 6 concurrency, builds the same on macOS and on the Linux race server), and its added packages are libraries the server stack would take on anyway (logging, metrics, NIO SSL and service lifecycle). A migration runner is a small amount of code against a schema of a handful of tables; owning it keeps the dependency to the client alone. Race logs are small (a few hundred KB) and are written once, next to their registry row: one store, one backup, and a log can't outlive or precede its race.

## Considered options

- **Fluent (Vapor's ORM) and its migrations:** brings Vapor's ORM layer and its own model conventions to a server that has no Vapor; rejected for the same reason as Vapor in ADR 0006.
- **A Swift migration package on top of postgres-nio:** saves little code and adds a dependency that drives our schema.
- **Race logs in an object store (S3 or similar):** cheaper at scale, but a second store and a second credential for v1. `RaceLogStore` sits behind the `RaceLogStoring` protocol so an object store can take over later without its callers changing.
- **SQLite on the server:** simplest locally, but a single file doesn't serve more than one server process and isn't what the hosting plan (#4) provisions.

## Consequences

- Data files are immutable (ADR 0004): `DataFileStore` has no delete or replace, the table's trigger refuses `UPDATE` and `DELETE`, a race's files reference `data_files`, and the same id and version with a different hash is refused. So every version a race log names stays readable (#32).
- `RaceRegistryStore.cancelOrphans()` marks every `running` race cancelled; the server calls it at start, when none of them can still be running (#30, wired up by #145).
- The tests need a real Postgres (`REGATTA_TEST_DATABASE_URL`): without one they're skipped, except in CI, whose `persistence` job runs them against a `postgres:17` service container. Each test runs in a schema of its own.
- Upgrading `postgres-nio` is a deliberate change to `Package.resolved`, reviewed like any other; it changes nothing the simulation computes, so no simulation version bump.
- Hosting, credentials and TLS for production Postgres are open: the server reads only `REGATTA_DATABASE_URL` (`sslmode=disable|prefer|require`).
