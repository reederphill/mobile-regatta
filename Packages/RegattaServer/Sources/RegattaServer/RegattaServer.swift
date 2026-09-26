#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Dispatch
import Foundation
import RegattaServerKit

/// `RegattaServer` (#67): the race server. Configured from the environment (`ServerConfig`); refuses to
/// start, with exit status 78 (EX_CONFIG) and the reason on stderr, unless `ENV=dev`.
@main
enum RegattaServerMain {
    /// Synchronous on purpose. RegattaServerTests links this module (to start the real executable), and at
    /// -O each module's async entry gets a specialised thunk named only after `async_Main`, not the module:
    /// the linker keeps one, and when this module links first the test runner's `main` starts the server
    /// instead of the tests (check.sh and CI build tests at -O). A sync `main` has no such thunk.
    static func main() {
        Task { await run() }
        dispatchMain()
    }

    private static func run() async {
        let config: ServerConfig
        do {
            config = try ServerConfig.load(from: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("RegattaServer: \(error)\n".utf8))
            exit(78)
        }
        let server: RegattaHTTPServer
        do {
            server = try await RegattaHTTPServer.start(config: config)
        } catch {
            FileHandle.standardError.write(Data("RegattaServer: can't start: \(error)\n".utf8))
            exit(1)
        }
        // Written unbuffered, so a container's log and a test reading the pipe see it at once. (Not
        // `print` + `fflush(stdout)`: Glibc's `stdout` is a mutable global Swift 6 refuses.)
        FileHandle.standardOutput.write(Data(
            "RegattaServer \(config.serverBuild) (ENV=\(config.environment.name)) listening on \(config.host):\(server.port)\n".utf8))
        // It serves until it's killed: the listener stopping is a failure, whatever the reason.
        do {
            try await server.wait()
            FileHandle.standardError.write(Data("RegattaServer: the listener closed\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("RegattaServer: the listener failed: \(error)\n".utf8))
        }
        exit(1)
    }
}
