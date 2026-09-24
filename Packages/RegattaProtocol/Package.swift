// swift-tools-version: 6.0
import PackageDescription

// The race wire protocol (#63): messages, framing and a hand-rolled binary codec. No transport:
// the client (#64) and the race host (#65) carry the bytes over whatever they use.
let package = Package(
    name: "RegattaProtocol",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaProtocol", targets: ["RegattaProtocol"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
    ],
    targets: [
        .target(
            name: "RegattaProtocol",
            dependencies: [.product(name: "RegattaCore", package: "RegattaCore")]
        ),
        .testTarget(
            name: "RegattaProtocolTests",
            dependencies: ["RegattaProtocol", .product(name: "RegattaCore", package: "RegattaCore")]
        ),
    ]
)
