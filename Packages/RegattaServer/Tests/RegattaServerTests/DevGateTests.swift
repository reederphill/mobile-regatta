import Foundation
import NIOHTTP1
import RegattaDevAPI
@testable import RegattaServerKit
import Testing

/// #67: the server has dev auth only, so it refuses to start unless `ENV=dev`, and the instant race
/// exists only in dev.
struct DevGateTests {
    // MARK: Dev auth refuses to start without ENV=dev

    @Test func devAuthRefusesToStartWithoutEnvDev() async throws {
        #expect(throws: ServerConfigError.devAuthOutsideDev("(unset)")) { try ServerConfig.load(from: [:]) }
        for value in ["prod", "production", "staging", "DEV", "dev ", ""] {
            #expect(throws: ServerConfigError.devAuthOutsideDev(value)) { try ServerConfig.load(from: ["ENV": value]) }
            #expect(throws: ServerConfigError.self) { try SeatAuthPolicy.for(ServerEnvironment(env: value)) }
        }
        #expect(try SeatAuthPolicy.for(ServerEnvironment(env: "dev")) == .dev)
        let config = try ServerConfig.load(from: ["ENV": "dev", "PORT": "0"])
        #expect(config.environment == .dev)
        #expect(config.port == 0)

        // Even a config built by hand can't start a server outside dev.
        var production = ServerConfig.dev()
        production.environment = .other("prod")
        await #expect(throws: ServerConfigError.devAuthOutsideDev("prod")) {
            _ = try await RegattaHTTPServer.start(config: production)
        }
    }

    @Test func configRejectsBadValues() {
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "PORT": "http"]) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "PORT": "70000"]) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "RACE_TOKEN_SECRET": "short"]) }
    }

    #if os(macOS) || os(Linux)
    /// The real executable, in its own process: exit status 78 and the reason, and it never listens.
    @Test func serverExecutableRefusesToStartWithoutEnvDev() throws {
        let executable = try #require(productExecutable("RegattaServer"), "RegattaServer not found next to the test bundle")
        for env in [nil, "prod"] as [String?] {
            let process = Process()
            process.executableURL = executable
            var environment = ProcessInfo.processInfo.environment
            environment["ENV"] = env
            environment["PORT"] = "0"
            process.environment = environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            let printed = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 78)
            #expect(printed.contains("refuses to start unless ENV=dev"))
        }
    }
    #endif

    // MARK: Instant-race endpoint refused when ENV != dev

    @Test func instantRaceEndpointRefusedWhenEnvIsNotDev() async throws {
        for env in [ServerEnvironment.other(nil), .other("prod"), .other("staging")] {
            #expect(Route.resolve(method: .POST, path: ServerPath.instantRace, environment: env) == .notFound)
            #expect(Route.resolve(method: .GET, path: ServerPath.instantRace, environment: env) == .notFound)
            // The rest of the server is the same.
            #expect(Route.resolve(method: .GET, path: ServerPath.health, environment: env) == .health)

            var config = ServerConfig.dev()
            config.environment = env
            let registry = RaceRegistry()
            let handler = RequestHandler(config: config, registry: registry)
            let reply = await handler.respond(method: .POST, uri: "\(ServerPath.instantRace)?clients=2")
            #expect(reply.status == .notFound)
            #expect(await registry.count == 0)
        }

        // In dev it's there.
        #expect(Route.resolve(method: .POST, path: ServerPath.instantRace, environment: .dev) == .instantRace)
        #expect(Route.resolve(method: .GET, path: ServerPath.instantRace, environment: .dev) == .methodNotAllowed)
        let registry = RaceRegistry()
        let reply = await RequestHandler(config: .dev(), registry: registry)
            .respond(method: .POST, uri: "\(ServerPath.instantRace)?clients=2&raceSeconds=1&startSeconds=1")
        #expect(reply.status == .created)
        #expect(await registry.count == 1)
        await registry.closeAll()
    }
}

#if os(macOS) || os(Linux)
private final class BundleMarker {}

/// SwiftPM builds the package's executables into the same products directory as the test bundle.
func productExecutable(_ name: String) -> URL? {
    var directories: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        directories.append(bundle.bundleURL.deletingLastPathComponent())
    }
    let marker = Bundle(for: BundleMarker.self).bundleURL
    directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
    directories.append(Bundle.main.bundleURL)
    directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    return directories.lazy
        .map { $0.appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
#endif
