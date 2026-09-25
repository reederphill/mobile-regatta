#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import RegattaDevAPI
import RegattaLoadClient

// regatta-loadclient (#67): sails races against a RegattaServer headlessly and reports bytes and RTT.
//
//   regatta-loadclient [--host H] [--port P] [--clients N] [--race-seconds S] [--start-seconds S]
//                      [--seed X] [--frame-rate HZ] [--timeout S] [--token BASE64] [--json] [--check-bandwidth]
//
// Without --token it creates a dev instant race (the server must run with ENV=dev) with N clients and
// sails every seat at once. With --token it sails that one seat. Exit status 0 if every client sailed the
// race to its close (and, with --check-bandwidth, stayed within #27's budget), 1 otherwise, 2 for bad usage.

let usage = """
    usage: regatta-loadclient [--host H] [--port P] [--clients N] [--race-seconds S] [--start-seconds S]
                              [--seed X] [--frame-rate HZ] [--timeout S] [--token BASE64] [--json] [--check-bandwidth]
    """

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("regatta-loadclient: \(message)\n".utf8))
    exit(status)
}

var options = LoadClientOptions()
var request = InstantRaceRequest(clients: 1)
var token: [UInt8]?
var json = false
var checkBandwidth = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
@MainActor func value(_ flag: String) -> String {
    guard let value = arguments.next() else { fail("\(flag) needs a value\n\(usage)", status: 2) }
    return value
}
@MainActor func int(_ flag: String) -> Int {
    guard let parsed = Int(value(flag)) else { fail("\(flag) needs an integer", status: 2) }
    return parsed
}
while let argument = arguments.next() {
    switch argument {
    case "--host": options.host = value(argument)
    case "--port": options.port = int(argument)
    case "--clients": request.clients = int(argument)
    case "--race-seconds": request.raceSeconds = int(argument)
    case "--start-seconds": request.startSeconds = int(argument)
    case "--seed":
        guard let seed = UInt64(value(argument)) else { fail("--seed needs an unsigned integer", status: 2) }
        request.seed = seed
    case "--frame-rate": options.frameRate = int(argument)
    case "--timeout": options.timeout = .seconds(int(argument))
    case "--token":
        guard let data = Data(base64Encoded: value(argument)) else { fail("--token isn't base64", status: 2) }
        token = [UInt8](data)
    case "--json": json = true
    case "--check-bandwidth": checkBandwidth = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default: fail("unknown argument \(argument)\n\(usage)", status: 2)
    }
}

let results: [Result<LoadReport, any Error>]
do {
    if let token {
        do { results = [.success(try await LoadClient.sail(token: token, options: options))] }
        catch { results = [.failure(error)] }
    } else {
        let (race, reports) = try await LoadClient.sailInstantRace(request, options: options)
        if !json {
            print("race \(race.raceID): \(race.seats.count) clients, \(race.bots) bots, "
                  + "start \(race.startSeconds) s, length \(race.raceSeconds.map { "\($0) s" } ?? "full")")
        }
        results = reports
    }
} catch {
    fail("\(error)", status: 1)
}

let budget = BandwidthBudget.issue27
var ok = true
var reports: [LoadReport] = []
for result in results {
    switch result {
    case .success(let report):
        reports.append(report)
        if !report.completed { ok = false }
        if checkBandwidth {
            for violation in budget.violations(report) {
                ok = false
                FileHandle.standardError.write(Data("over budget: \(violation)\n".utf8))
            }
        }
        if !json {
            print(String(format: "seat %2d %@ %7d B down (join %5d) %6d B up %6.1f s %6.0f B/s down; RTT ms min %.1f median %.1f p95 %.1f max %.1f (%d, %.1f median at the client's update); held %d taps %d resyncs %d/%d events %d",
                         report.seat, report.completed ? "closed " : "OPEN   ", report.bytesReceived, report.joinBytes,
                         report.bytesSent, report.seconds, report.downstreamBytesPerSecond,
                         report.roundTrips.min, report.roundTrips.median, report.roundTrips.p95, report.roundTrips.max,
                         report.roundTrips.count, report.clientRoundTrips.median, report.heldSent, report.tapsSent, report.resyncsApplied,
                         report.resyncRequests, report.serverEvents))
        }
    case .failure(let error):
        ok = false
        FileHandle.standardError.write(Data("client failed: \(error)\n".utf8))
    }
}
if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(reports), as: UTF8.self))
} else if !reports.isEmpty {
    let worst = reports.map(\.downstreamBytesPerSecond).max() ?? 0
    let most = reports.map(\.bytesReceived).max() ?? 0
    print("\(reports.filter(\.completed).count)/\(results.count) sailed to the close; worst downstream \(Int(worst)) B/s, most bytes \(most) B")
}
exit(ok ? 0 : 1)
