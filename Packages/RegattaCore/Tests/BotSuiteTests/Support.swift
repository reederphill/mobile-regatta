import BotSuite
import Foundation
import Testing

/// Thresholds nothing can miss: every tier gated, every limit out of reach, the tick limit too.
func unmissableThresholds() -> BotThresholds {
    let limits = TierLimits(minFinishShare: 0, maxMeanIronsSeconds: .greatestFiniteMagnitude,
                            maxMeanMarkContacts: .greatestFiniteMagnitude, maxContactsToFoulsShare: 1,
                            maxMeanEdgeSeconds: .greatestFiniteMagnitude)
    return BotThresholds(tiers: Dictionary(uniqueKeysWithValues: BotTier.allCases.map { ($0.rawValue, limits) }),
                         maxP99TickMs: .greatestFiniteMagnitude)
}

/// Thresholds nothing can meet: every tier must finish more than all its boats.
func impossibleThresholds() -> BotThresholds {
    var thresholds = unmissableThresholds()
    for tier in BotTier.allCases { thresholds.tiers[tier.rawValue]?.minFinishShare = 1.01 }
    return thresholds
}

/// Writes `value` as JSON to a fresh temporary file and returns its path.
func fixture(_ value: some Encodable, named name: String) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("botsuite-\(name)-\(UUID().uuidString).json")
    try JSONEncoder().encode(value).write(to: file)
    return file.path
}

/// `report` as JSON with every `timings` object dropped: the only numbers that differ between two runs.
func jsonWithoutTimings(_ report: BotSuiteReport) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    object["timings"] = nil
    let races = try #require(object["races"] as? [[String: Any]])
    object["races"] = races.map { race in
        var race = race
        race["timings"] = nil
        return race
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
}

#if os(macOS) || os(Linux)
private final class BundleMarker {}

/// Runs the built `regatta-botsuite` with `arguments` in its own process.
func botsuite(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
    let executable = try #require(botsuiteExecutable(), "regatta-botsuite not found next to the test bundle")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, printed)
}

/// SwiftPM builds `regatta-botsuite` into the same products directory as the test bundle.
private func botsuiteExecutable() -> URL? {
    var directories: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        directories.append(bundle.bundleURL.deletingLastPathComponent())
    }
    let marker = Bundle(for: BundleMarker.self).bundleURL
    directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
    directories.append(Bundle.main.bundleURL)
    directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    return directories.lazy
        .map { $0.appendingPathComponent("regatta-botsuite") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
#endif
