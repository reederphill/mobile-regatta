// regatta-replay [--any-version] <race-log.json | race folder>
//
// Replays a race log (ADR 0002) and prints the final digest as 0x and 16 hex digits. A log from
// another simulation version is refused unless --any-version is given, which replays it anyway
// and warns: the digest is then this build's reading of the inputs, not the race as it was sailed.
// A folder is a tuned practice race as `RaceLogFolder` saves it (#232): its log, with the tuned
// copies it names beside it, which the replay resolves before the bundled files.
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
    fail("usage: regatta-replay [--any-version] <race-log.json | race folder>", status: 2)
}

do {
    let url = URL(fileURLWithPath: arguments[0])
    var isFolder: ObjCBool = false
    let (log, catalog) = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        ? try RaceLogFolder.read(url)
        : (try RaceLog(jsonData: Data(contentsOf: url)), RaceFileCatalog())
    if log.header.simulationVersion != simulationVersion {
        let mismatch = "log is simulation version \(log.header.simulationVersion), this build is \(simulationVersion)"
        guard anyVersion else { fail("\(mismatch); pass --any-version to replay it anyway", status: 1) }
        FileHandle.standardError.write(Data("regatta-replay: warning: \(mismatch)\n".utf8))
    }
    let digest = try Replayer.digest(of: log, requireMatchingVersion: false, catalog: catalog)
    print(hex64(digest))
} catch {
    fail("\(error)", status: 1)
}
