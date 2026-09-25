#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import RegattaServerKit

/// `RegattaServer` (#67): the race server. Configured from the environment (`ServerConfig`); refuses to
/// start, with exit status 78 (EX_CONFIG) and the reason on stderr, unless `ENV=dev`.
@main
enum RegattaServerMain {
    static func main() async {
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
        print("RegattaServer \(config.serverBuild) (ENV=\(config.environment.name)) listening on \(config.host):\(server.port)")
        // Line-buffered either way, so a container's log and a test reading the pipe see it at once.
        fflush(stdout)
        await server.wait()
    }
}
