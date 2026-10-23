import Foundation
import NIOHTTP1
import AppAttest
import RegattaDevAPI
@testable import RegattaServerKit
import Testing

/// #67, #158: the server starts only with `ENV` exactly dev, staging or production; outside dev it needs Apple's root,
/// the moderation key and Postgres, and refuses the App Attest bypass. The instant race exists only in dev.
struct DevGateTests {
    /// What a staging or production server must be given, but `ENV`.
    static func required() throws -> [String: String] {
        let pem = FileManager.default.temporaryDirectory.appendingPathComponent("regatta-devgate-root-\(UUID()).pem")
        try AppleAppAttestRoot.pem.write(to: pem, atomically: true, encoding: .utf8)
        return ["REGATTA_APPLE_ROOT_PEM": pem.path, "OPENAI_MODERATION_API_KEY": "sk-test",
                "REGATTA_DATABASE_URL": "postgres://regatta@localhost:5432/regatta"]
    }

    // MARK: Unknown environments refuse to start

    @Test func unknownEnvironmentsRefuseToStart() async throws {
        #expect(throws: ServerConfigError.unknownEnvironment("(unset)")) { try ServerConfig.load(from: [:]) }
        for value in ["prod", "Production", "STAGING", "DEV", "dev ", ""] {
            #expect(throws: ServerConfigError.unknownEnvironment(value)) { try ServerConfig.load(from: ["ENV": value]) }
            #expect(throws: ServerConfigError.self) { try SeatAuthPolicy.for(ServerEnvironment(env: value)) }
        }
        #expect(try SeatAuthPolicy.for(ServerEnvironment(env: "dev")) == .dev)
        #expect(try SeatAuthPolicy.for(ServerEnvironment(env: "staging")) == .raceToken)
        #expect(try SeatAuthPolicy.for(ServerEnvironment(env: "production")) == .raceToken)
        let config = try ServerConfig.load(from: ["ENV": "dev", "PORT": "0"])
        #expect(config.environment == .dev)
        #expect(config.port == 0)
        // Loopback unless told otherwise: the container sets HOST=0.0.0.0.
        #expect(config.host == "127.0.0.1")
        #expect(try ServerConfig.load(from: ["ENV": "dev", "HOST": "0.0.0.0"]).host == "0.0.0.0")

        // Even a config built by hand can't start a server in an unknown environment.
        var unknown = ServerConfig.dev()
        unknown.environment = .other("prod")
        await #expect(throws: ServerConfigError.unknownEnvironment("prod")) {
            _ = try await RegattaHTTPServer.start(config: unknown)
        }
    }

    // MARK: Staging and production (#158)

    @Test func stagingAndProductionLoadWithWhatTheyNeed() throws {
        let required = try Self.required()
        let staging = try ServerConfig.load(from: required.merging(["ENV": "staging"]) { $1 })
        #expect(staging.environment == .staging && staging.auth == .raceToken)
        // Staging takes both: TestFlight builds attest as production.
        #expect(!staging.appAttest.bypass && staging.appAttest.environments == [.development, .production])
        #expect(staging.identity.database != nil)
        let production = try ServerConfig.load(from: required.merging(["ENV": "production"]) { $1 })
        #expect(production.environment == .production && production.auth == .raceToken)
        #expect(!production.appAttest.bypass && production.appAttest.environments == [.production])
        // `off` is accepted outside dev, and staging may be narrowed to development keys.
        #expect(try !ServerConfig.load(from: required.merging(["ENV": "production", "APP_ATTEST_BYPASS": "off"]) { $1 }).appAttest.bypass)
        #expect(try ServerConfig.load(from: required.merging(["ENV": "staging", "APP_ATTEST_ENVIRONMENT": "development"]) { $1 })
            .appAttest.environments == [.development])
        // Dev: the bypass on and both environments, unless told otherwise.
        let dev = try ServerConfig.load(from: ["ENV": "dev"])
        #expect(dev.appAttest.bypass && dev.appAttest.environments == [.development, .production] && dev.auth == .dev)
        #expect(try !ServerConfig.load(from: ["ENV": "dev", "APP_ATTEST_BYPASS": "off"]).appAttest.bypass)
        #expect(try ServerConfig.load(from: ["ENV": "dev", "APP_ATTEST_ENVIRONMENT": "production"]).appAttest.environments == [.production])
    }

    /// The ticket's acceptance: a production config rejects the bypass. Five refusals.
    @Test func productionConfigRejectsBypass() throws {
        let required = try Self.required()
        // 1, 2: the bypass on, in production and in staging.
        for env in ["production", "staging"] {
            #expect(throws: ServerConfigError.invalid(variable: "APP_ATTEST_BYPASS", value: "on", expected: "off or unset outside ENV=dev")) {
                try ServerConfig.load(from: required.merging(["ENV": env, "APP_ATTEST_BYPASS": "on"]) { $1 })
            }
        }
        // 3: production with development keys (or both).
        for value in ["development", "both"] {
            #expect(throws: ServerConfigError.invalid(variable: "APP_ATTEST_ENVIRONMENT", value: value, expected: "production in ENV=production")) {
                try ServerConfig.load(from: required.merging(["ENV": "production", "APP_ATTEST_ENVIRONMENT": value]) { $1 })
            }
        }
        // 4: production without Postgres: keys in memory would be forgotten at a restart.
        var noDatabase = required.merging(["ENV": "production"]) { $1 }
        noDatabase["REGATTA_DATABASE_URL"] = nil
        #expect(throws: ServerConfigError.invalid(variable: "REGATTA_DATABASE_URL", value: "(unset)", expected: "Postgres outside ENV=dev")) {
            try ServerConfig.load(from: noDatabase)
        }
        // 5: values that aren't the variables' own, anywhere.
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: required.merging(["ENV": "production", "APP_ATTEST_BYPASS": "yes"]) { $1 }) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "APP_ATTEST_BYPASS": "true"]) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "APP_ATTEST_ENVIRONMENT": "sandbox"]) }
    }

    @Test func configRejectsBadValues() {
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "PORT": "http"]) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "PORT": "70000"]) }
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "RACE_TOKEN_SECRET": "short"]) }
    }

    #if os(macOS) || os(Linux)
    /// The real executable, in its own process: exit status 78 and the reason, and it never listens. For an unknown
    /// environment, and for production with the bypass on (everything else it needs given).
    @Test func serverExecutableRefusesToStart() throws {
        let executable = try #require(productExecutable("RegattaServer"), "RegattaServer not found next to the test bundle")
        var production: [String: String?] = try Self.required().mapValues { $0 }
        production["ENV"] = "production"
        production["APP_ATTEST_BYPASS"] = "on"
        let cases: [([String: String?], String)] = [
            (["ENV": nil], "refuses to start unless ENV is dev, staging or production"),
            (["ENV": "prod"], "refuses to start unless ENV is dev, staging or production"),
            (production, "APP_ATTEST_BYPASS=on is invalid"),
        ]
        for (variables, reason) in cases {
            let process = Process()
            process.executableURL = executable
            var environment = ProcessInfo.processInfo.environment
            for (name, value) in variables { environment[name] = value }
            environment["PORT"] = "0"
            process.environment = environment
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            // A watchdog: if it started after all, it would never exit, so fail rather than hang.
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            let started = process.isRunning
            if started { process.terminate() }
            process.waitUntilExit()
            let printed = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(!started, "RegattaServer was still running after 10 s with \(variables)")
            #expect(process.terminationStatus == 78)
            #expect(printed.contains(reason), "\(printed)")
        }
    }
    #endif

    // MARK: Instant-race endpoint refused when ENV != dev

    @Test func instantRaceEndpointRefusedWhenEnvIsNotDev() async throws {
        for env in [ServerEnvironment.other(nil), .other("prod"), .staging, .production] {
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
