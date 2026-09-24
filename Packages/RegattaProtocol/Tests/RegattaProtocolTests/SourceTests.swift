import Foundation
import Testing

/// The protocol is transport-free (#63, #18): no WebSocket, networking or UI imports, so the race host
/// (#65), the client package (#64) and the app all use it over whatever transport they have.
@Suite struct SourceTests {
    static func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RegattaProtocol")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func importsOnlyRegattaCore() throws {
        let files = try Self.sources()
        #expect(files.count >= 4)
        let imports = try Regex(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:\w+\s+)?(\w+)"#)
        var imported: [String] = []
        for file in files {
            for line in file.text.split(separator: "\n") {
                if let match = String(line).firstMatch(of: imports), let module = match.output[1].substring {
                    imported.append("\(file.name): \(module)")
                }
            }
        }
        #expect(!imported.isEmpty)
        #expect(imported.filter { !$0.hasSuffix(": RegattaCore") } == [])
    }

    @Test func noTransportTypes() throws {
        let transport = try Regex(#"WebSocket|URLSession|NWConnection|NWListener|Socket\b|NIO"#)
        let hits = try Self.sources().flatMap { file in
            file.text.split(separator: "\n").filter { $0.contains(transport) }.map { "\(file.name): \($0)" }
        }
        #expect(hits == [])
    }
}
