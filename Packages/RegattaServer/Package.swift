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
        .library(name: "GameCenterIdentity", targets: ["GameCenterIdentity"]),
        .executable(name: "RegattaServer", targets: ["RegattaServer"]),
        .executable(name: "regatta-loadclient", targets: ["regatta-loadclient"]),
        .executable(name: "regatta-bench", targets: ["regatta-bench"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaProtocol"),
        // The load client sails with the app's online client (#64).
        .package(path: "../RegattaClient"),
        // The service protocols, their wire adapters and the contract runner (#143): the service endpoint answers
        // through the same mapping as the loopback, and the contract runner reaches it through a connector (#145).
        .package(path: "../RegattaServices"),
        // WebSocket and HTTP/1.1, server and client (ADR 0006). Pinned to a minor: Package.resolved has the exact one.
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMinor(from: "2.103.0")),
        // HMAC for race tokens, on Linux and macOS alike. Already in the graph through RegattaCore.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // Postgres for players, sessions, the race registry, race logs and data files (ADR 0009). Pinned to a
        // minor like swift-nio: Package.resolved has the exact one.
        .package(url: "https://github.com/vapor/postgres-nio.git", .upToNextMinor(from: "1.33.1")),
        // Game Center identity verification (#145): X.509 chain building to Apple's root, and the HTTPS fetch of
        // Game Center's certificate. swift-nio-ssl is already in the graph through postgres-nio; swift-certificates
        // is new (Apple's, pure Swift, Linux-buildable). Pinned to a minor: Package.resolved has the exact ones.
        .package(url: "https://github.com/apple/swift-certificates.git", .upToNextMinor(from: "1.21.0")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMinor(from: "2.37.5")),
        .package(url: "https://github.com/apple/swift-asn1.git", .upToNextMinor(from: "1.7.3")),
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
        // Game Center identity verification (#145): the signed payload, the certificate chain to Apple's root and
        // the RSA signature check, over an injectable fetcher and clock. No sockets: the server supplies the fetcher.
        .target(
            name: "GameCenterIdentity",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
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
                // Identity, sessions and the Terms of Use (#145).
                "GameCenterIdentity",
                "Persistence",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                .product(name: "RegattaServices", package: "RegattaServices"),
                .product(name: "RegattaServiceClient", package: "RegattaServices"),
                .product(name: "RegattaServiceLoopback", package: "RegattaServices"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .executableTarget(name: "RegattaServer", dependencies: ["RegattaServerKit", "Persistence"]),
        // The server's Postgres store (#144, ADR 0009): a connection pool, our own migration runner and one store
        // per table. Not wired into RegattaServerKit yet: #145 does that.
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        // The load client (#67): RegattaClient over a NIO WebSocket, scripted inputs, bytes and RTT measured. Also the
        // contract runner's connector to a dev server's service endpoint (#145).
        .target(
            name: "RegattaLoadClient",
            dependencies: [
                "RegattaDevAPI",
                .product(name: "RegattaClient", package: "RegattaClient"),
                .product(name: "RegattaServiceClient", package: "RegattaServices"),
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
        // The verifier against a certificate chain the tests make, and the real payload when #175's fixture is there.
        .testTarget(
            name: "GameCenterIdentityTests",
            dependencies: [
                "GameCenterIdentity",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
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
                // The service endpoint (#145): its clients, the contract runner, and Postgres for its persistence tests.
                "GameCenterIdentity",
                "Persistence",
                .product(name: "RegattaServices", package: "RegattaServices"),
                .product(name: "RegattaServiceClient", package: "RegattaServices"),
                .product(name: "RegattaServiceContracts", package: "RegattaServices"),
                .product(name: "RegattaContractRunner", package: "RegattaServices"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                // Built so a test can replay a stored race log in its own process (#148).
                .product(name: "regatta-replay", package: "RegattaCore"),
            ]
        ),
    ]
)
