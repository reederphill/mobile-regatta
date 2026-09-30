import Foundation
import Testing

/// The services package is I/O-free and UI-free (#109): protocols, value types and scripted fakes, so it builds
/// on Linux and the fakes replay exactly. Time only comes in through what a service reports, never a clock.
@Suite struct SourceTests {
    static func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        return try ["RegattaServices", "RegattaServiceContracts"].flatMap { target in
            let dir = root.appendingPathComponent(target)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
            return try names.map { ("\(target)/\($0)", try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
        }
    }

    @Test func importsOnlyThePackagesItBuildsOn() throws {
        let files = try Self.sources()
        #expect(files.count >= 9)
        let imports = try Regex(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:\w+\s+)?(\w+)"#)
        let allowed: Set<String> = ["RegattaCore", "RegattaProtocol", "RegattaServices", "Synchronization"]
        var foreign: [String] = []
        for file in files {
            for line in file.text.split(separator: "\n") {
                if let match = String(line).firstMatch(of: imports), let module = match.output[1].substring,
                   !allowed.contains(String(module)) {
                    foreign.append("\(file.name): \(module)")
                }
            }
        }
        #expect(foreign == [])
    }

    /// Word boundaries are the simple kind, as in the other packages' scans.
    static func violations(_ pattern: String, in files: [(name: String, text: String)]) throws -> [String] {
        let regex = try Regex(pattern).wordBoundaryKind(.simple)
        return files.flatMap { file in
            file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.element.contains(regex) }
                .map { "\(file.name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        }
    }

    @Test func noTransportOrUITypes() throws {
        #expect(try Self.violations(#"WebSocket|URLSession|NWConnection|NWListener|Socket\b|NIO|UIKit|SwiftUI|SpriteKit|GameKit"#, in: Self.sources()) == [])
    }

    @Test func noRandomnessOrWallClock() throws {
        let random = #"\.random\(|randomElement\(|shuffled\(|\.shuffle\(\)|RandomNumberGenerator|arc4random|drand48"#
        let wallClock = #"\bDate\(|Date\.now|timeIntervalSince|CFAbsoluteTime|DispatchTime|ContinuousClock|SuspendingClock|Task\.sleep|clock_gettime|gettimeofday|ProcessInfo"#
        #expect(try Self.violations(random + "|" + wallClock, in: Self.sources()) == [])
    }
}
