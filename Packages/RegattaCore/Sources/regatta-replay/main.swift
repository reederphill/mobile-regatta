// regatta-replay [--any-version] <race-log.json>
//
// Replays a race log (ADR 0002) and prints the final digest as 0x and 16 hex digits. A log from
// another simulation version is refused unless --any-version is given, which replays it anyway
// and warns: the digest is then this build's reading of the inputs, not the race as it was sailed.
import Foundation
import RegattaCore

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("regatta-replay: \(message)\n".utf8))
    exit(status)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let anyVersion = arguments.contains("--any-version")
arguments.removeAll { $0 == "--any-version" }
guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
    fail("usage: regatta-replay [--any-version] <race-log.json>", status: 2)
}

do {
    let log = try RaceLog(jsonData: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
    if log.header.simulationVersion != simulationVersion {
        let mismatch = "log is simulation version \(log.header.simulationVersion), this build is \(simulationVersion)"
        guard anyVersion else { fail("\(mismatch); pass --any-version to replay it anyway", status: 1) }
        FileHandle.standardError.write(Data("regatta-replay: warning: \(mismatch)\n".utf8))
    }
    let digest = try Replayer.digest(of: log, requireMatchingVersion: false)
    print(hex64(digest))
} catch {
    fail("\(error)", status: 1)
}
