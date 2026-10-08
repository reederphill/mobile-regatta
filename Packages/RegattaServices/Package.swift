// swift-tools-version: 6.0
import PackageDescription

// The client's service contracts (#109, #241): protocols and value types for identity, terms, the queue, the race
// session (#109), the lobby, the profile, the store, analytics, connectivity and data deletion (#241), a scripted
// fake of each, and a contract suite per service. The suites are written against the
// protocols and take any conforming implementation, so the same suite runs against the fakes, the remote
// runner (#143) and the real services. No UIKit: it builds and tests on Linux. The app links `RegattaServices`
// and runs on its fakes (`FakeServiceScenario`, #242) until the real services arrive.
let package = Package(
    name: "RegattaServices",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RegattaServices", targets: ["RegattaServices"]),
        // Apart from the services so the app doesn't link the suites; #143's runner and #241's suites do.
        .library(name: "RegattaServiceContracts", targets: ["RegattaServiceContracts"]),
        // #143: the client adapters over the service messages, the in-process loopback server, and the remote
        // contract runner. Transport-free like the rest: a link is the caller's.
        .library(name: "RegattaServiceClient", targets: ["RegattaServiceClient"]),
        .library(name: "RegattaServiceLoopback", targets: ["RegattaServiceLoopback"]),
        .library(name: "RegattaContractRunner", targets: ["RegattaContractRunner"]),
    ],
    dependencies: [
        .package(path: "../RegattaCore"),
        .package(path: "../RegattaProtocol"),
    ],
    targets: [
        .target(
            name: "RegattaServices",
            dependencies: [
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        .target(
            name: "RegattaServiceContracts",
            dependencies: [
                "RegattaServices",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        .target(
            name: "RegattaServiceClient",
            dependencies: [
                "RegattaServices",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        .target(
            name: "RegattaServiceLoopback",
            dependencies: [
                "RegattaServices",
                "RegattaServiceClient",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
        .target(
            name: "RegattaContractRunner",
            dependencies: ["RegattaServices", "RegattaServiceContracts", "RegattaServiceClient"]
        ),
        .testTarget(
            name: "RegattaServicesTests",
            dependencies: [
                "RegattaServices",
                "RegattaServiceContracts",
                "RegattaServiceClient",
                "RegattaServiceLoopback",
                "RegattaContractRunner",
                .product(name: "RegattaCore", package: "RegattaCore"),
                .product(name: "RegattaProtocol", package: "RegattaProtocol"),
            ]
        ),
    ]
)
