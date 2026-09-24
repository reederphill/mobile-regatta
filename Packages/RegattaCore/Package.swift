// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RegattaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaCore", targets: ["RegattaCore"]),
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
            resources: [.copy("Resources/boat-classes")]
        ),
        .testTarget(name: "RegattaCoreTests", dependencies: ["RegattaCore"]),
    ]
)
