#if DEBUG
import Foundation
import RegattaCore

/// The tuning panel's values (#232): the bundled files it tunes, the values it writes into tuned copies of them
/// (in each file's own units, by JSON Pointer, or `upwind:<column>` for a polar column's groove), and the render
/// values it draws with. Only values that differ from the files are kept. The current tuning, and each named
/// saved tuning, is one of these as JSON on the device.
struct Tuning: Codable, Equatable {
    /// A saved tuning's name; nil for the current one.
    var name: String?
    var boatClass = RaceFiles.defaults.boatClass.ref.key
    var conditions = RaceFiles.defaults.conditions.ref.key
    var rulesConfiguration = RaceFiles.defaults.rulesConfiguration.ref.key
    var boatClassValues: [String: Double] = [:]
    var conditionsValues: [String: Double] = [:]
    var rulesValues: [String: Double] = [:]
    var water = WaterStyle.standard
    var camera = CameraStyle.standard

    init() {}

    /// The base file a slot tunes.
    subscript(base slot: TuningSlot) -> DataFileKey {
        get {
            switch slot {
            case .boatClass: boatClass
            case .conditions: conditions
            case .rulesConfiguration: rulesConfiguration
            }
        }
        set {
            switch slot {
            case .boatClass: boatClass = newValue
            case .conditions: conditions = newValue
            case .rulesConfiguration: rulesConfiguration = newValue
            }
        }
    }

    /// The values a slot writes into its base file.
    subscript(values slot: TuningSlot) -> [String: Double] {
        get {
            switch slot {
            case .boatClass: boatClassValues
            case .conditions: conditionsValues
            case .rulesConfiguration: rulesValues
            }
        }
        set {
            switch slot {
            case .boatClass: boatClassValues = newValue
            case .conditions: conditionsValues = newValue
            case .rulesConfiguration: rulesValues = newValue
            }
        }
    }

    /// Whether any data file value differs from its file: the race sails tuned copies.
    var tunesFiles: Bool { TuningSlot.allCases.contains { !self[values: $0].isEmpty } }
    /// Whether any value at all differs from the files and the standard look: the TUNED badge.
    var isTuned: Bool { tunesFiles || water != .standard || camera != .standard }

    private enum CodingKeys: String, CodingKey {
        case name, boatClass, conditions, rulesConfiguration, boatClassValues, conditionsValues, rulesValues, water, camera
    }

    /// Lenient: a value this build no longer has, or a render style saved before it gained a field, falls back
    /// to the default rather than losing the whole tuning.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        boatClass = (try? c.decode(DataFileKey.self, forKey: .boatClass)) ?? boatClass
        conditions = (try? c.decode(DataFileKey.self, forKey: .conditions)) ?? conditions
        rulesConfiguration = (try? c.decode(DataFileKey.self, forKey: .rulesConfiguration)) ?? rulesConfiguration
        boatClassValues = (try? c.decode([String: Double].self, forKey: .boatClassValues)) ?? [:]
        conditionsValues = (try? c.decode([String: Double].self, forKey: .conditionsValues)) ?? [:]
        rulesValues = (try? c.decode([String: Double].self, forKey: .rulesValues)) ?? [:]
        water = (try? c.decode(WaterStyle.self, forKey: .water)) ?? .standard
        camera = (try? c.decode(CameraStyle.self, forKey: .camera)) ?? .standard
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Where the tuning panel keeps things on the device (#232), under Application Support/Tuning:
///
/// - `current.json`: the current tuning, kept until reset.
/// - `saved/<name>.json`: the named saved tunings.
/// - `files/<kind folder>/<id>@<version>+tune<n>.json`: every tuned copy a race has sailed, never changed once
///   written, so a tune number always names the same bytes on this device.
/// - `races/<date>-<race seed>/`: each tuned practice race's log with its tuned copies beside it
///   (`RaceLogFolder`), which `regatta-replay <folder>` or `RaceLogFolder.read` replays. The newest
///   `keptRaces` are kept.
///
/// With no root (UI tests) nothing is read or written: tuned copies are numbered in memory and no race is kept.
struct TuningStore {
    let root: URL?
    static let keptRaces = 20

    /// Application Support/Tuning.
    static var standard: TuningStore {
        TuningStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tuning", isDirectory: true))
    }

    static let inMemory = TuningStore(root: nil)

    private var manager: FileManager { .default }

    // MARK: Tunings

    func loadCurrent() -> Tuning? {
        guard let url = root?.appendingPathComponent("current.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Tuning.self, from: data)
    }

    func saveCurrent(_ tuning: Tuning) throws {
        guard let root else { return }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try tuning.jsonData().write(to: root.appendingPathComponent("current.json"), options: .atomic)
    }

    /// The saved tunings, by name.
    func savedTunings() -> [Tuning] {
        guard let folder = root?.appendingPathComponent("saved", isDirectory: true),
              let urls = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Tuning.self, from: Data(contentsOf: $0)) }
            .filter { $0.name != nil }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }

    func save(_ tuning: Tuning, as name: String) throws {
        guard let root else { return }
        var saved = tuning
        saved.name = name
        let folder = root.appendingPathComponent("saved", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try saved.jsonData().write(to: folder.appendingPathComponent(Self.fileName(name)), options: .atomic)
    }

    func deleteSaved(_ name: String) throws {
        guard let url = root?.appendingPathComponent("saved", isDirectory: true).appendingPathComponent(Self.fileName(name)),
              manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    /// A name as a file name: anything but letters, digits, spaces, hyphens and underscores becomes a hyphen.
    static func fileName(_ name: String) -> String {
        let safe = String(name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" ? Character($0) : "-"
        })
        return (safe.isEmpty ? "tuning" : safe) + ".json"
    }

    // MARK: Tuned copies

    /// The tune number of the tuned copy of `key` with exactly `data`: the one it was written under before, or
    /// the next free one, writing it. `memory` numbers them for a store with no root.
    func tune(for data: Data, key: DataFileKey, kindFolder: String, memory: inout [Data: Int]) throws -> Int {
        guard let root else {
            if let tune = memory[data] { return tune }
            let tune = memory.count + 1
            memory[data] = tune
            return tune
        }
        let folder = root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(kindFolder, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "\(key.id)@\(key.version)+tune"
        var highest = 0
        for url in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let tune = Int(name.dropFirst(prefix.count)) else { continue }
            if (try? Data(contentsOf: url)) == data { return tune }
            highest = max(highest, tune)
        }
        let tune = highest + 1
        // Written whole beside it, then moved into place: a move never replaces a file that's there, so a tuned
        // copy, once written, is never rewritten. An app stopped between the two leaves the staged file hidden;
        // `removeStagedCopies` clears it at the next launch.
        let staged = folder.appendingPathComponent(".\(prefix)\(tune)-\(UUID().uuidString).json")
        try data.write(to: staged, options: .atomic)
        defer { try? manager.removeItem(at: staged) }
        try manager.moveItem(at: staged, to: folder.appendingPathComponent("\(prefix)\(tune).json"))
        return tune
    }

    /// Removes the hidden staged copies `tune(for:)` left in `files/<kind folder>/` when the app stopped between
    /// writing one and moving it into place. Run before any tuned copy is written (the panel's model does at
    /// launch): a staged copy is only ever in flight inside `tune(for:)`.
    func removeStagedCopies() {
        guard let files = root?.appendingPathComponent("files", isDirectory: true),
              let kinds = try? manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil) else { return }
        for kind in kinds {
            for url in (try? manager.contentsOfDirectory(at: kind, includingPropertiesForKeys: nil)) ?? [] {
                let name = url.lastPathComponent
                guard name.hasPrefix("."), name.contains("+tune"), url.pathExtension == "json" else { continue }
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: Races

    /// Saves a tuned practice race's log with its tuned copies beside it, and keeps only the newest `keptRaces`.
    @discardableResult
    func saveRace(_ log: RaceLog, tunedFiles: [FileRef: Data], at date: Date = .now) throws -> URL? {
        guard let root else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: date))-\(String(log.header.raceSeed.value, radix: 16))"
        let folder = root.appendingPathComponent("races", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try RaceLogFolder.write(log, tunedFiles: tunedFiles, to: folder)
        for old in races().dropFirst(Self.keptRaces) { try? manager.removeItem(at: old) }
        return folder
    }

    /// The saved tuned races, newest first.
    func races() -> [URL] {
        guard let folder = root?.appendingPathComponent("races", isDirectory: true),
              let urls = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { manager.fileExists(atPath: $0.appendingPathComponent(RaceLogFolder.logFileName).path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Every file in a saved race's folder, the log first: what its share sheet sends.
    func files(ofRace folder: URL) -> [URL] {
        let log = folder.appendingPathComponent(RaceLogFolder.logFileName)
        let others = (manager.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != RaceLogFolder.logFileName }
            .sorted { $0.path < $1.path }
        return [log] + others
    }
}
#endif
