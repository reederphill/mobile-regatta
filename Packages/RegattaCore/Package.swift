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
        .executable(name: "regatta-venue-png", targets: ["regatta-venue-png"]),
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
                .copy("Resources/liveries"),
                .copy("Resources/rules"),
                .copy("Resources/venues"),
            ]
        ),
        // Bots sail seats through RegattaCore's public input API only (#60), on the server and the device.
        // The bot-tier file (#102): each tier's skill band and a Mixed fleet's shares, versioned, byte for byte.
        // The reference regatta (#367): pinned races the app and the bot suite build identically.
        .target(name: "RegattaBots", dependencies: ["RegattaCore"], resources: [.copy("bot-tiers@3.json"), .copy("reference-regatta@1.json"), .copy("reference-regatta@2.json")]),
        .executableTarget(name: "regatta-replay", dependencies: ["RegattaCore"]),
        // Offline tooling (#83): an overview PNG per venue × conditions pairing into docs/venues, for review (#84).
        .executableTarget(name: "regatta-venue-png", dependencies: ["RegattaCore"]),
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
        // A thin command line over BotSuite, and the UI tests' seed probe (#404) over RegattaBots.
        .executableTarget(name: "regatta-botsuite", dependencies: ["BotSuite", "RegattaBots", "RegattaCore"]),
        // regatta-botsuite is a dependency so `swift test` builds it: the gate tests run it as its own process.
        .testTarget(name: "BotSuiteTests", dependencies: ["BotSuite", "regatta-botsuite", "RegattaCore", "RegattaBots"]),
    ]
)
