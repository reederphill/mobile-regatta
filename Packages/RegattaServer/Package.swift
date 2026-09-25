// swift-tools-version: 6.0
import PackageDescription

// The race server (#65): `RaceHost`, an actor owning one authoritative `Race`, stepped at 30 Hz on an
// injectable clock, talking to each seat over an injectable transport (no sockets). Builds on Linux.
let package = Package(
    name: "RegattaServer",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RaceHost", targets: ["RaceHost"]),
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
        .testTarget(
            name: "RaceHostTests",
            dependencies: [
                "RaceHost",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
                // Built so a test can replay the host's log with it in its own process (#59).
                .product(name: "regatta-replay", package: "RegattaCore"),
            ]
        ),
    ]
)
