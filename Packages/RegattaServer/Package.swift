// swift-tools-version: 6.0
import PackageDescription

// The race server. `RaceHost` (#65): an actor owning one authoritative `Race`, stepped at 30 Hz on an
// injectable clock, talking to each seat over an injectable transport (no sockets). `RegattaServer` (#67):
// the executable that puts races behind a WebSocket endpoint (SwiftNIO, ADR 0006), and
// `regatta-loadclient`, the headless client that sails races against it over the same stack.
// `regatta-bench` (#69) measures the host's per-tick work against the server budget (#27). `Persistence` (#144):
// the server's Postgres tables (players, sessions, the race registry, race logs, data files) and their migrations
// (ADR 0009). Builds on Linux.
let package = Package(
    name: "RegattaServer",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RaceHost", targets: ["RaceHost"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "RegattaServer", targets: ["RegattaServer"]),
        .executable(name: "regatta-loadclient", targets: ["regatta-loadclient"]),
        .executable(name: "regatta-bench", targets: ["regatta-bench"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaProtocol"),
        // The load client sails with the app's online client (#64).
        .package(path: "../RegattaClient"),
        // WebSocket and HTTP/1.1, server and client (ADR 0006). Pinned to a minor: Package.resolved has the exact one.
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMinor(from: "2.103.0")),
        // HMAC for race tokens, on Linux and macOS alike. Already in the graph through RegattaCore.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // Postgres for players, sessions, the race registry, race logs and data files (ADR 0009). Pinned to a
        // minor like swift-nio: Package.resolved has the exact one.
        .package(url: "https://github.com/vapor/postgres-nio.git", .upToNextMinor(from: "1.33.1")),
    ],
    targets: [
        .target(
            name: "RaceHost",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
                // The host sails its bot seats through the input API with RegattaBots' controllers (#60).
                .product(name: "RegattaBots", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        // The dev endpoints' JSON (#67), shared by the server and the load client. Foundation only.
        .target(name: "RegattaDevAPI"),
        // Everything the executable does, as a library the tests start in-process: config and the
        // environment gate, race tokens, races and their seats, the HTTP and WebSocket endpoint.
        .target(
            name: "RegattaServerKit",
            dependencies: [
                "RaceHost",
                "RegattaDevAPI",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "RegattaServer", dependencies: ["RegattaServerKit"]),
        // The server's Postgres store (#144, ADR 0009): a connection pool, our own migration runner and one store
        // per table. Not wired into RegattaServerKit yet: #145 does that.
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        // The load client (#67): RegattaClient over a NIO WebSocket, scripted inputs, bytes and RTT measured.
        .target(
            name: "RegattaLoadClient",
            dependencies: [
                "RegattaDevAPI",
                .product(name: "RegattaClient", package: "RegattaClient"),
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "regatta-loadclient", dependencies: ["RegattaLoadClient"]),
        // The tick benchmark (#69): scenarios, the tick loop, stats, the gate and the JSON report.
        .target(
            name: "Bench",
            dependencies: [
                "RaceHost",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaBots", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ],
            // The scenario list is data (#69); #105 adds its scenarios here.
            resources: [.copy("scenarios.json")]
        ),
        // A thin command line over Bench.
        .executableTarget(name: "regatta-bench", dependencies: ["Bench"]),
        // regatta-bench is a dependency so `swift test` builds it: the gate tests run it as its own process.
        .testTarget(
            name: "BenchTests",
            dependencies: ["Bench", "regatta-bench", .product(name: "RegattaCore", package: "RegattaCore")]
        ),
        // The stores against a real Postgres named by REGATTA_TEST_DATABASE_URL; skipped without it, except in CI.
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "RaceHostTests",
            dependencies: [
                "RaceHost",
                .product(name: "RegattaCore", package: "RegattaCore"),
                // The seat tests read which controller sails a seat (#66).
                .product(name: "RegattaBots", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                // Built so a test can replay the host's log with it in its own process (#59).
                .product(name: "regatta-replay", package: "RegattaCore"),
            ]
        ),
        .testTarget(
            name: "RegattaServerTests",
            dependencies: [
                "RegattaServerKit",
                "RegattaLoadClient",
                "RegattaDevAPI",
                "RaceHost",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                .product(name: "RegattaClient", package: "RegattaClient"),
                // Built so a test can start the real executable and see it refuse to start (#67).
                "RegattaServer",
            ]
        ),
    ]
)
