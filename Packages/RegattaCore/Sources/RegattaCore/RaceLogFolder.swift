import Foundation

public enum RaceLogFolderError: Error, Equatable, CustomStringConvertible {
    /// The log names a tuned copy whose bytes weren't given (writing) or aren't beside it (reading).
    case missingTunedFile(FileRef)

    public var description: String {
        switch self {
        case .missingTunedFile(let ref): "no bytes for the tuned copy \(ref)"
        }
    }
}

/// A race log saved as a folder, with the tuned copies (#229) its setup names saved beside it, byte for byte:
/// a tuned log replays only with its generated files (ADR 0004). The log is `race.racelog.json`; each tuned
/// copy is `<kind folder>/<id>@<version>+tune<n>.json`, the kind folder being its kind's `bundleDirectory`.
/// Bundled files aren't copied: the build that replays the log has them.
///
///     race.racelog.json
///     conditions/classic-oscillating@3+tune2.json
///     boat-classes/skiff@1+tune5.json
public enum RaceLogFolder {
    public static let logFileName = "race.racelog.json"

    /// Where the tuned copy `ref` sits in a folder, from the folder. Nil for a bundled file's ref.
    public static func path<Content: DataFileContent>(of ref: FileRef, kind: Content.Type) -> String? {
        guard let tune = ref.tune else { return nil }
        return "\(Content.bundleDirectory)/\(ref.id)@\(ref.version)+tune\(tune).json"
    }

    /// Writes `log` into `folder` (made if missing) with the bytes of each tuned copy its setup names, taken
    /// from `tunedFiles`. Throws `missingTunedFile` if one isn't there, and `DataFileError.refMismatch` if its
    /// bytes aren't the ones the ref names: a folder never holds a file its log can't replay with.
    public static func write(_ log: RaceLog, tunedFiles: [FileRef: Data], to folder: URL) throws {
        let setup = log.header.setup
        // Paths and bytes, in the setup's order.
        var writes: [(String, Data)] = []
        func add<Content: DataFileContent>(_ ref: FileRef, _ kind: Content.Type) throws {
            guard let path = path(of: ref, kind: kind) else { return }
            guard let data = tunedFiles[ref] else { throw RaceLogFolderError.missingTunedFile(ref) }
            let hash = ContentHash(of: data)
            guard hash == ref.hash else { throw DataFileError.refMismatch(expected: ref, foundHash: hash) }
            writes.append((path, data))
        }
        try add(setup.boatClass, BoatClass.self)
        try add(setup.venue, Venue.self)
        try add(setup.conditions, Conditions.self)
        try add(setup.rulesConfiguration, RulesConfig.self)

        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in writes {
            let url = folder.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        // The log last: a folder with its log in it has every file the log needs.
        try log.jsonData().write(to: folder.appendingPathComponent(logFileName), options: .atomic)
    }

    /// Reads a folder `write` made: the log, and a catalog holding each tuned copy its setup names, loaded
    /// through every check a data file goes through and checked against its ref. Replay the log with
    /// `Replayer.replay(_:catalog:)`. Throws `missingTunedFile` if a tuned copy isn't beside the log.
    public static func read(_ folder: URL) throws -> (log: RaceLog, catalog: RaceFileCatalog) {
        let log = try RaceLog(jsonData: Data(contentsOf: folder.appendingPathComponent(logFileName)))
        let setup = log.header.setup
        var catalog = RaceFileCatalog()
        func load<Content: DataFileContent>(_ ref: FileRef, into files: inout DataFileCatalog<Content>) throws {
            guard let path = path(of: ref, kind: Content.self) else { return }
            let url = folder.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RaceLogFolderError.missingTunedFile(ref) }
            try files.add(DataFile<Content>(data: Data(contentsOf: url), expecting: ref))
        }
        try load(setup.boatClass, into: &catalog.boatClasses)
        try load(setup.venue, into: &catalog.venues)
        try load(setup.conditions, into: &catalog.conditions)
        try load(setup.rulesConfiguration, into: &catalog.rulesConfigurations)
        return (log, catalog)
    }
}
