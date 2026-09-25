// swift-tools-version: 6.0
import PackageDescription

// The race server (#65): `RaceHost`, an actor owning one authoritative `Race`, stepped at 30 Hz on an
// injectable clock, talking to each seat over an injectable transport (no sockets). Builds on Linux.
// `regatta-bench` (#69) measures the host's per-tick work against the server budget (#27).
let package = Package(
    name: "RegattaServer",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RaceHost", targets: ["RaceHost"]),
        .executable(name: "regatta-bench", targets: ["regatta-bench"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaProtocol"),
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
    ]
)
