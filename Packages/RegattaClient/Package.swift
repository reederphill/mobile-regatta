// swift-tools-version: 6.0
import PackageDescription

// The online race client (#64): clock sync, input stamping under the caps, full-fleet prediction and
// resync, over a transport protocol (no sockets). Shared by the app (#68) and `regatta-loadclient` (#67).
// No UIKit: it builds and tests on Linux.
let package = Package(
    name: "RegattaClient",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaClient", targets: ["RegattaClient"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaProtocol"),
    ],
    targets: [
        .target(
            name: "RegattaClient",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        // The scripted race host the tests sail against lives here, not in the library: the real one is #65's.
        .testTarget(
            name: "RegattaClientTests",
            dependencies: [
                "RegattaClient",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
    ]
)
