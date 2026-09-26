// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RegattaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaCore", targets: ["RegattaCore"]),
        .library(name: "RegattaBots", targets: ["RegattaBots"]),
        .executable(name: "regatta-replay", targets: ["regatta-replay"]),
        .executable(name: "regatta-botsuite", targets: ["regatta-botsuite"]),
    ],
    dependencies: [
        // SHA-256 of data files on Linux (the race server); Apple platforms use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "RegattaCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            // Copied byte for byte: a data file's hash is taken over its exact bytes (ADR 0004).
            resources: [
                .copy("Resources/boat-classes"),
                .copy("Resources/conditions"),
                .copy("Resources/rules"),
                .copy("Resources/venues"),
            ]
        ),
        // Bots sail seats through RegattaCore's public input API only (#60), on the server and the device.
        .target(name: "RegattaBots", dependencies: ["RegattaCore"]),
        .executableTarget(name: "regatta-replay", dependencies: ["RegattaCore"]),
        // regatta-replay is a dependency so `swift test` builds it: the golden test runs it as its own process.
        .testTarget(
            name: "RegattaCoreTests",
            dependencies: ["RegattaCore", "regatta-replay"],
            // Fixture data files, byte for byte, loaded with `DataFile.bundled(id:version:in: .module)`.
            resources: [.copy("Resources/venues")]
        ),
        .testTarget(name: "RegattaBotsTests", dependencies: ["RegattaBots", "RegattaCore"]),
        // The headless bot-race suite (#97): the harness, the matrix, per-seat metrics, the gate and the
        // JSON report. Apart from RegattaBots: it reads the wall clock for tick times, which bots never do.
        .target(
            name: "BotSuite",
            dependencies: ["RegattaCore", "RegattaBots"],
            // The full matrix and the per-tier limits are data (#19: "The exact limits are set at build time").
            resources: [.copy("matrix.json"), .copy("thresholds.json")]
        ),
        // A thin command line over BotSuite.
        .executableTarget(name: "regatta-botsuite", dependencies: ["BotSuite"]),
        // regatta-botsuite is a dependency so `swift test` builds it: the gate tests run it as its own process.
        .testTarget(name: "BotSuiteTests", dependencies: ["BotSuite", "regatta-botsuite", "RegattaCore", "RegattaBots"]),
    ]
)
