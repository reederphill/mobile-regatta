public enum RaceFilesError: Error, Equatable, Sendable {
    /// The venue has no pairing for the conditions (#77), so the race's wind can't be laid out there.
    case noPairing(venue: FileRef, conditions: FileRef)
    /// A race was given a file other than the one its setup names.
    case notTheSetupFile(expected: FileRef, found: FileRef)
}

/// Data files loaded outside this build's bundle (a server's store, a download), looked up by ref before
/// the bundled files are. Holds arrays, never sets, so nothing depends on hash order (ADR 0002).
public struct RaceFileCatalog: Sendable {
    public var boatClasses = DataFileCatalog<BoatClass>()
    public var venues = DataFileCatalog<Venue>()
    public var conditions = DataFileCatalog<Conditions>()
    public var rulesConfigurations = DataFileCatalog<RulesConfig>()

    public init() {}
}

/// The data files a race is sailed with (ADR 0004): its boat class, venue, conditions and rules
/// configuration, each exactly the file its `RaceSetup` names by id, version and hash, and the venue's
/// pairing for the conditions (#77). Everything derived from them (the course, the race area, the wind
/// setup) is computed at load, never stored in them.
public struct RaceFiles: Sendable {
    public let boatClass: BoatClassFile
    public let venue: VenueFile
    public let conditions: ConditionsFile
    public let rulesConfiguration: RulesConfigFile
    /// The venue's pairing for the conditions: the race's wind and course are laid out around it.
    public let pairing: Venue.Pairing

    /// Throws `noPairing` if `venue` has no pairing for `conditions`.
    public init(boatClass: BoatClassFile, venue: VenueFile, conditions: ConditionsFile,
                rulesConfiguration: RulesConfigFile) throws {
        guard let pairing = venue.content.pairing(for: conditions.ref.key) else {
            throw RaceFilesError.noPairing(venue: venue.ref, conditions: conditions.ref)
        }
        self.boatClass = boatClass
        self.venue = venue
        self.conditions = conditions
        self.rulesConfiguration = rulesConfiguration
        self.pairing = pairing
    }

    /// Resolves each file `setup` names: from `catalog` if it holds that exact ref (a tuned copy is found
    /// only this way, #229) or an untuned file with that id and version, else from this build's bundled
    /// files. Throws `DataFileError.refMismatch` if the file found there has other bytes than the ref's
    /// hash (checked before anything is parsed), `DataFileError.notBundled` if neither has it, and
    /// `noPairing` if the venue can't host the conditions.
    public init(resolving setup: RaceSetup, from catalog: RaceFileCatalog = RaceFileCatalog()) throws {
        let defaults = RaceFiles.defaults
        try self.init(
            boatClass: Self.resolve(setup.boatClass, in: catalog.boatClasses, bundledDefault: defaults.boatClass),
            venue: Self.resolve(setup.venue, in: catalog.venues, bundledDefault: defaults.venue),
            conditions: Self.resolve(setup.conditions, in: catalog.conditions, bundledDefault: defaults.conditions),
            rulesConfiguration: Self.resolve(
                setup.rulesConfiguration, in: catalog.rulesConfigurations, bundledDefault: defaults.rulesConfiguration)
        )
    }

    /// The bundled files a `RaceSetup` names unless told otherwise: skiff@7 (v1.0's class, planing with an
    /// automatic spinnaker, #248, turning a penalty turn in about 10 s, #89, with #263's momentum, shadow cost, tack
    /// cost and roll tack, #298's backwind astern on her windward quarter; in skiff@5 the backwind's stern edge is steep, it grows with her speed and it is off while running; in skiff@6, #377, the shadow is a ribbon wake and the backwind a header off a working sail; in skiff@7, #437, the autohelm is off a centred rudder, so every boat steers by hand), dev-venue@2 (whose pairings name the schema-2 conditions),
    /// classic-oscillating@2 and fleet-rules@5 (schema 5: the start row's spacing floor, #85, sequential
    /// penalty deadlines, #89, the escape simulation's "changes course" rate, #92, and rule 17's limits, #345).
    public static let defaults: RaceFiles = {
        do {
            return try RaceFiles(
                boatClass: .bundled(id: "skiff", version: 7),
                venue: .bundled(id: "dev-venue", version: 2),
                conditions: .bundled(id: "classic-oscillating", version: 2),
                rulesConfiguration: .bundled(id: "fleet-rules", version: 5)
            )
        } catch {
            preconditionFailure("the bundled default race files failed to load: \(error)")
        }
    }()

    /// Throws `notTheSetupFile` unless these are exactly the files `setup` names.
    public func check(against setup: RaceSetup) throws {
        let pairs = [(setup.boatClass, boatClass.ref), (setup.venue, venue.ref), (setup.conditions, conditions.ref),
                     (setup.rulesConfiguration, rulesConfiguration.ref)]
        for (expected, found) in pairs where expected != found {
            throw RaceFilesError.notTheSetupFile(expected: expected, found: found)
        }
    }

    private static func resolve<Content>(
        _ ref: FileRef, in catalog: DataFileCatalog<Content>, bundledDefault: DataFile<Content>
    ) throws -> DataFile<Content> {
        // By id, version and hash in one lookup: a tuned copy (#229) shares its base file's id and
        // version, so only the whole ref finds it, and it never stands in for the bundled file.
        if let file = catalog.file(ref) { return file }
        // An untuned file the catalog holds under this id and version replaces the bundled one, so a
        // ref naming other bytes is refused rather than resolved from the bundle.
        if let file = catalog.file(id: ref.id, version: ref.version) {
            throw DataFileError.refMismatch(expected: ref, foundHash: file.ref.hash)
        }
        // The defaults are already loaded: most races sail them.
        if bundledDefault.ref == ref { return bundledDefault }
        guard let data = try DataFile<Content>.bundledData(id: ref.id, version: ref.version) else {
            throw DataFileError.notBundled(kind: Content.kind, id: ref.id, version: ref.version)
        }
        return try DataFile<Content>(data: data, expecting: ref)
    }
}
