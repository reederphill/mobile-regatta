import Foundation
import RaceHost
import RegattaCore
@testable import RegattaServerKit
import Testing

extension RaceSims {
    /// #148, ADR 0002: a closed race's stored log replays to its stored digest, in this process and in a new one
    /// (`regatta-replay`, as on the Linux server); a log from another simulation version is refused, not "fixed".
    @Suite(.timeLimit(.minutes(2))) struct ReplayStoredLogTests {
        /// A race every human left, closed through the lifecycle into the archive.
        private func storedRace() async throws -> ClosedRaceRecordView {
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let race = try await rig.race(["T:0", "T:1"], seats: 6)
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1], to: 90, seq: &seq)
            await race.leave(seat: 0, transport: transports[0])
            await rig.sail(race, [1], to: 200, seq: &seq)
            await race.leave(seat: 1, transport: transports[1])
            await rig.runUntilEnded(race, limit: 600)
            await rig.end(race)
            let stored = try #require(try await rig.archive.closedRace(race.id))
            return ClosedRaceRecordView(log: stored.log, digest: stored.digest)
        }

        struct ClosedRaceRecordView {
            let log: Data
            let digest: UInt64
        }

        @Test func storedLogReplaysToStoredDigestInNewProcess() async throws {
            let stored = try await storedRace()
            let log = try RaceLog(jsonData: stored.log)
            #expect(log.allGoneClose != nil)
            #expect(try Replayer.digest(of: log) == stored.digest)

            #if os(macOS) || os(Linux)
            let (status, printed) = try replay(stored.log)
            #expect(status == 0)
            #expect(printed == hex64(stored.digest))
            #endif
        }

        @Test func aLogFromAnotherSimulationVersionIsRefused() async throws {
            let stored = try await storedRace()
            let text = String(decoding: stored.log, as: UTF8.self)
            let other = text.replacingOccurrences(of: "\"\(RegattaCore.simulationVersion)\"", with: "\"0/old\"")
            #expect(other != text)
            #expect(throws: (any Error).self) { try Replayer.digest(of: RaceLog(jsonData: Data(other.utf8))) }

            #if os(macOS) || os(Linux)
            let (status, printed) = try replay(Data(other.utf8))
            #expect(status == 1)
            #expect(printed.isEmpty)
            #endif
        }

        #if os(macOS) || os(Linux)
        /// Runs `regatta-replay` on `log` in its own process: its exit status and what it printed.
        private func replay(_ log: Data) throws -> (Int32, String) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stored-log-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("race-log.json")
            try log.write(to: file)
            let executable = try #require(Self.replayExecutable(), "regatta-replay not found next to the test bundle")
            let process = Process()
            process.executableURL = executable
            process.arguments = [file.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, printed.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private final class BundleMarker {}

        /// SwiftPM builds `regatta-replay` into the same products directory as the test bundle.
        private static func replayExecutable() -> URL? {
            var directories: [URL] = []
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                directories.append(bundle.bundleURL.deletingLastPathComponent())
            }
            let marker = Bundle(for: BundleMarker.self).bundleURL
            directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
            directories.append(Bundle.main.bundleURL)
            directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
            return directories.lazy
                .map { $0.appendingPathComponent("regatta-replay") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        #endif
    }
}
