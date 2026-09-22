// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RegattaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaCore", targets: ["RegattaCore"]),
    ],
    targets: [
        .target(name: "RegattaCore"),
        .testTarget(name: "RegattaCoreTests", dependencies: ["RegattaCore"]),
    ]
)
