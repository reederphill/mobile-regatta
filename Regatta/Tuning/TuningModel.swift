#if DEBUG
import Foundation
import Observation
import os
import RegattaCore

/// The debug tuning panel (#232): real-vs-fun thresholds as sliders, in Debug builds only.
///
/// The simulation's values are data, never overrides (ADR 0004, #229): at each practice race start the panel
/// writes a tuned copy of each file it changes (the bundled file's bytes with the new numbers at their JSON
/// Pointers, keeping its id and version and taking a `tune` number), and the race resolves them from its catalog.
/// Bots sail the same files (#19); online races never see them (the wire refuses a tuned ref). The render values
/// (water, camera, boat) are app-side and never logged, and reach the race's scene live.
///
/// Values persist until reset (`TuningStore`), and the race's log is saved with its tuned copies beside it, so it
/// replays.
@Observable
final class TuningModel {
    /// The values, as the panel shows them. Change them through the methods below, which keep them to values
    /// that differ from the files and save them.
    private(set) var tuning: Tuning
    /// Why a slot's values don't make a file this build loads (a wobble past the amplitude, say): the race
    /// sails that slot's bundled file until they do.
    private(set) var problems: [TuningSlot: String] = [:]
    /// Where each polar column's upwind groove lands with the tuned values, degrees.
    private(set) var grooves: [Int: Double] = [:]
    /// The saved tunings on the device, by name.
    private(set) var savedTunings: [Tuning] = []
    /// The saved tuned races, newest first.
    private(set) var races: [URL] = []

    @ObservationIgnored let store: TuningStore
    /// Tune numbers given out by a store with no root.
    @ObservationIgnored private var memoryTunes: [Data: Int] = [:]
    @ObservationIgnored private var baseCache: [String: Data] = [:]
    @ObservationIgnored private var optionsCache: [TuningSlot: [DataFileKey]] = [:]
    /// File values by slider and base file, and the groups by boat class: the page reads them every time it draws.
    @ObservationIgnored private var fileValueCache: [String: Double?] = [:]
    @ObservationIgnored private var groupsCache: (boatClass: DataFileKey, groups: [TuningGroup])?
    @ObservationIgnored private var venuesCache: [VenueFile]?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The live practice race, whose scene the render values reach as they change, and whether it sails tuned
    /// copies (its badge shows while either differs).
    @ObservationIgnored private weak var liveSession: GameSession?
    @ObservationIgnored private var liveSessionSailsTunedFiles = false
    /// The live race keeps the pressure overlay off whatever the panel says: a reference race (#367).
    @ObservationIgnored private var liveSessionHidesPressure = false
    @ObservationIgnored private weak var lastArchived: GameSession?
    @ObservationIgnored private let logger = Logger(subsystem: "com.phillreeder.regatta", category: "tuning")

    init(store: TuningStore) {
        self.store = store
        store.removeStagedCopies()
        tuning = store.loadCurrent() ?? Tuning()
        savedTunings = store.savedTunings()
        races = store.races()
        validate()
    }

    // MARK: - Files

    /// The bundled files the panel can tune in `slot`: the ones this build loads, and for conditions, the ones
    /// some bundled venue can host.
    func options(_ slot: TuningSlot) -> [DataFileKey] {
        if let options = optionsCache[slot] { return options }
        let options: [DataFileKey]
        switch slot {
        case .boatClass:
            options = BoatClassFile.bundledKeys().filter { baseData(.boatClass, $0).flatMap { try? BoatClassFile(data: $0) } != nil }
        case .conditions:
            options = ConditionsFile.bundledKeys().filter { venue(for: $0) != nil }
        case .rulesConfiguration:
            options = RulesConfigFile.bundledKeys()
        }
        optionsCache[slot] = options
        return options
    }

    /// Every bundled venue, loaded once: which can host each conditions file.
    private var venues: [VenueFile] {
        if let venuesCache { return venuesCache }
        let venues = VenueFile.bundledKeys().compactMap { try? VenueFile.bundled(id: $0.id, version: $0.version) }
        venuesCache = venues
        return venues
    }

    /// The venue a race on `conditions` sails at: the default venue if it can host them, else the newest version of
    /// the default venue that can (so the panel keeps to the default race's water, #83), else the newest bundled
    /// venue that can.
    func venue(for conditions: DataFileKey) -> FileRef? {
        let defaultVenue = RaceFiles.defaults.venue
        if defaultVenue.content.pairing(for: conditions) != nil { return defaultVenue.ref }
        let hosts = venues.filter { $0.content.pairing(for: conditions) != nil }
        return (hosts.last { $0.ref.id == defaultVenue.ref.id } ?? hosts.last)?.ref
    }

    func baseData(_ slot: TuningSlot, _ key: DataFileKey? = nil) -> Data? {
        let key = key ?? tuning[base: slot]
        let cacheKey = "\(slot.rawValue)/\(key)"
        if let data = baseCache[cacheKey] { return data }
        let data: Data?
        switch slot {
        case .boatClass: data = try? BoatClassFile.bundledData(id: key.id, version: key.version)
        case .conditions: data = try? ConditionsFile.bundledData(id: key.id, version: key.version)
        case .rulesConfiguration: data = try? RulesConfigFile.bundledData(id: key.id, version: key.version)
        }
        baseCache[cacheKey] = data
        return data
    }

    /// Tunes another bundled file in `slot`, dropping the values tuned into the last one.
    func setBase(_ slot: TuningSlot, _ key: DataFileKey) {
        guard tuning[base: slot] != key else { return }
        tuning[base: slot] = key
        tuning[values: slot] = [:]
        changed()
    }

    // MARK: - Sliders

    /// The boat class's driving polar columns and their wind speeds: the groove sliders.
    var grooveColumns: [(column: Int, knots: Double)] {
        guard let data = baseData(.boatClass) else { return [] }
        var columns: [(Int, Double)] = []
        var c = 0
        while let knots = TunedCopy.number(at: "/polar/columns/\(c)/twsKnots", in: data) {
            if knots > 0 { columns.append((c, knots)) }
            c += 1
        }
        return columns
    }

    /// The index of the boat class's last turn-rate curve point, from whose speed she turns at the top rate: the
    /// full-steering slider. Nil if the curve has no points.
    var fullSteeragePoint: Int? {
        guard let data = baseData(.boatClass) else { return nil }
        var point = 0
        while TunedCopy.number(at: "/steering/turnRateCurve/\(point)/speedKnots", in: data) != nil { point += 1 }
        return point > 0 ? point - 1 : nil
    }

    var groups: [TuningGroup] {
        if let groupsCache, groupsCache.boatClass == tuning.boatClass { return groupsCache.groups }
        let groups = TuningCatalog.groups(grooveColumns: grooveColumns, fullSteeragePoint: fullSteeragePoint)
        groupsCache = (tuning.boatClass, groups)
        return groups
    }

    /// The slider's value in its file, or the standard render value: nil if its file has no such value.
    func fileValue(_ slider: TuningSlider) -> Double? {
        let key = "\(slider.id)@\(slider.slot.map { tuning[base: $0].description } ?? "")"
        if let cached = fileValueCache[key] { return cached }
        let value = readFileValue(slider)
        fileValueCache[key] = value
        return value
    }

    private func readFileValue(_ slider: TuningSlider) -> Double? {
        switch slider.target {
        case .file(let slot, let pointer):
            guard let data = baseData(slot) else { return nil }
            if let flag = TuningCatalog.fileFlags.first(where: { $0.slot == slot && $0.pointer == pointer }) {
                return TunedCopy.flag(at: pointer, in: data) ?? flag.absent
            }
            return TunedCopy.number(at: pointer, in: data)
        case .groove(let column):
            guard let data = baseData(.boatClass), let rows = TunedCopy.numbers(at: "/polar/twaDegrees", in: data),
                  let speeds = TunedCopy.numbers(at: "/polar/columns/\(column)/speedKnots", in: data) else { return nil }
            return TunedCopy.bestUpwindAngle(twaDegrees: rows, speedKnots: speeds)
        case .water(let path): return WaterStyle.standard[keyPath: path]
        case .camera(let path): return CameraStyle.standard[keyPath: path]
        case .boat(let path): return BoatStyle.standard[keyPath: path]
        case .hint(let path): return HintTuning.standard[keyPath: path]
        case .ease(let path): return EaseGestureTuning.standard[keyPath: path]
        }
    }

    /// The slider's value: tuned, or its file's.
    func value(_ slider: TuningSlider) -> Double? {
        switch slider.target {
        case .water(let path): return tuning.water[keyPath: path]
        case .camera(let path): return tuning.camera[keyPath: path]
        case .boat(let path): return tuning.boat[keyPath: path]
        case .hint(let path): return tuning.hint[keyPath: path]
        case .ease(let path): return tuning.ease[keyPath: path]
        case .file, .groove:
            guard let slot = slider.slot, let key = slider.valueKey else { return nil }
            return tuning[values: slot][key] ?? fileValue(slider)
        }
    }

    func isChanged(_ slider: TuningSlider) -> Bool {
        guard let value = value(slider), let file = fileValue(slider) else { return false }
        return value != file
    }

    /// Sets a slider, to its step. A value equal to its file's is dropped: only differences are kept.
    func set(_ slider: TuningSlider, to raw: Double) {
        let value = (raw / slider.step).rounded() * slider.step
        let file = fileValue(slider)
        let same = file.map { abs($0 - value) < slider.step / 2 } ?? false
        switch slider.target {
        case .water(let path): tuning.water[keyPath: path] = same ? file ?? value : value
        case .camera(let path): tuning.camera[keyPath: path] = same ? file ?? value : value
        case .boat(let path): tuning.boat[keyPath: path] = same ? file ?? value : value
        case .hint(let path): tuning.hint[keyPath: path] = same ? file ?? value : value
        case .ease(let path): tuning.ease[keyPath: path] = same ? file ?? value : value
        case .file, .groove:
            guard let slot = slider.slot, let key = slider.valueKey, file != nil else { return }
            tuning[values: slot][key] = same ? nil : value
        }
        changed()
    }

    /// Puts every slider in `group` back to its file's value.
    func reset(_ group: TuningGroup) {
        for slider in group.sliders {
            switch slider.target {
            case .water(let path): tuning.water[keyPath: path] = WaterStyle.standard[keyPath: path]
            case .camera(let path): tuning.camera[keyPath: path] = CameraStyle.standard[keyPath: path]
            case .boat(let path): tuning.boat[keyPath: path] = BoatStyle.standard[keyPath: path]
            case .hint(let path): tuning.hint[keyPath: path] = HintTuning.standard[keyPath: path]
            case .ease(let path): tuning.ease[keyPath: path] = EaseGestureTuning.standard[keyPath: path]
            case .file, .groove:
                if let slot = slider.slot, let key = slider.valueKey { tuning[values: slot][key] = nil }
            }
        }
        changed()
    }

    func reset(_ slider: TuningSlider) {
        if let file = fileValue(slider) { set(slider, to: file) }
    }

    func isChanged(_ group: TuningGroup) -> Bool { group.sliders.contains(where: isChanged) }

    /// The water's pressure overlay (#289): the pressure drawn stronger, its lanes' centrelines and its side
    /// marked, live on the practice race.
    var showsPressure: Bool {
        get { tuning.showsPressure }
        set {
            tuning.showsPressure = newValue
            changed()
        }
    }

    /// Back to the bundled defaults and the standard look.
    func resetAll() {
        tuning = Tuning()
        changed()
    }

    // MARK: - Races

    /// The files the next practice race sails (#232): a tuned copy of each file whose values differ from it,
    /// numbered and kept in the store, in the race's catalog. A slot whose values don't load sails its bundled
    /// file; if even that fails, the race sails the defaults.
    func practiceFiles() -> PracticeFiles {
        do {
            let boatClass = try assemble(BoatClass.self, .boatClass)
            let conditions = try assemble(Conditions.self, .conditions)
            let rules = try assemble(RulesConfig.self, .rulesConfiguration)
            guard let venue = venue(for: tuning.conditions) else {
                throw RaceFilesError.noPairing(venue: RaceFiles.defaults.venue.ref, conditions: conditions.ref)
            }
            var files = PracticeFiles(boatClass: boatClass.ref, venue: venue, conditions: conditions.ref,
                                      rulesConfiguration: rules.ref)
            if boatClass.isTuned {
                try files.catalog.boatClasses.add(boatClass.file)
                files.tunedFiles[boatClass.ref] = boatClass.data
            }
            if conditions.isTuned {
                try files.catalog.conditions.add(conditions.file)
                files.tunedFiles[conditions.ref] = conditions.data
            }
            if rules.isTuned {
                try files.catalog.rulesConfigurations.add(rules.file)
                files.tunedFiles[rules.ref] = rules.data
            }
            // Resolved here, so a race never starts on files it can't load.
            let setup = try RaceSetup(raceSeed: RaceSeed(0), seats: [.human, .bot], boatClass: files.boatClass,
                                      venue: files.venue, conditions: files.conditions,
                                      rulesConfiguration: files.rulesConfiguration)
            _ = try RaceFiles(resolving: setup, from: files.catalog)
            return files
        } catch {
            logger.error("Tuned files failed, sailing the defaults: \(String(describing: error), privacy: .public)")
            return .defaults
        }
    }

    /// The files a practice race set up on `setup`'s venue and conditions sails (#131): the panel's boat class and
    /// rules, at the setup's venue on its conditions, unless the panel's conditions are its own (a tuned copy, or a
    /// base file other than the default chosen in the panel, tuned or not), which the race sails at the setup's venue
    /// if it can host them, else at the venue `practiceFiles()` picks.
    func practiceFiles(over setup: PracticeFiles) -> PracticeFiles {
        var files = practiceFiles()
        let panelPicksConditions = files.conditions.tune != nil || tuning.conditions != Tuning().conditions
        if !panelPicksConditions {
            files.venue = setup.venue
            files.conditions = setup.conditions
        } else if let venue = venues.last(where: { $0.ref == setup.venue }),
                  venue.content.pairing(for: files.conditions.key) != nil {
            files.venue = setup.venue
        }
        return files
    }

    /// A practice session starts on this tuning: its render values, live from now on, and the TUNED badge.
    /// `hidesPressure`, the pressure overlay stays off for it (a reference race, #367).
    func attach(_ session: GameSession, files: PracticeFiles, hidesPressure: Bool = false) {
        liveSession = session
        liveSessionSailsTunedFiles = files.isTuned
        liveSessionHidesPressure = hidesPressure
        showLive()
    }

    /// The render values on the live race's scene, and its badge.
    private func showLive() {
        guard let session = liveSession else { return }
        if session.scene.waterStyle != tuning.water { session.scene.waterStyle = tuning.water }
        if session.scene.cameraStyle != tuning.camera { session.scene.cameraStyle = tuning.camera }
        if session.scene.boatStyle != tuning.boat { session.scene.boatStyle = tuning.boat }
        if session.hintTuning != tuning.hint { session.hintTuning = tuning.hint }
        if session.easeTuning != tuning.ease { session.easeTuning = tuning.ease }
        let showsPressure = tuning.showsPressure && !liveSessionHidesPressure
        if session.scene.showsPressureOverlay != showsPressure { session.scene.showsPressureOverlay = showsPressure }
        session.isTuned = liveSessionSailsTunedFiles || tuning.water != .standard || tuning.camera != .standard
            || tuning.boat != .standard || tuning.hint != .standard || tuning.ease != .standard
    }

    /// Saves a practice session's log with its tuned copies beside it, if it sailed any, so it replays
    /// (ADR 0004). Once per session.
    func archive(_ session: GameSession) {
        guard session !== lastArchived, let driver = session.driver as? PracticeDriver, !driver.tunedFiles.isEmpty else { return }
        lastArchived = session
        do {
            try store.saveRace(driver.log, tunedFiles: driver.tunedFiles)
            races = store.races()
        } catch {
            logger.error("Saving the tuned race failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Saved tunings and export

    func save(as name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try store.save(tuning, as: name)
        } catch {
            logger.error("Saving tuning \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        savedTunings = store.savedTunings()
    }

    func load(_ saved: Tuning) {
        var loaded = saved
        loaded.name = nil
        tuning = loaded
        changed()
    }

    func delete(_ saved: Tuning) {
        guard let name = saved.name else { return }
        try? store.deleteSaved(name)
        savedTunings = store.savedTunings()
    }

    /// The export (#232): the next version of each file the tuning changes, ready for RegattaCore's
    /// `Resources`, with the changed values listed under `placeholders`, and the tuning itself, written to a
    /// fresh temporary folder for the share sheet.
    func exportFiles(named name: String = "tuning") throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-export-\(UUID().uuidString)")
        let kinds: [(TuningSlot, String)] = [(.boatClass, BoatClass.bundleDirectory), (.conditions, Conditions.bundleDirectory),
                                             (.rulesConfiguration, RulesConfig.bundleDirectory)]
        var urls: [URL] = []
        for (slot, kindFolder) in kinds where !tuning[values: slot].isEmpty {
            guard let base = baseData(slot).map({ readied(slot, $0) }) else { continue }
            let key = tuning[base: slot]
            let values = try expandedValues(slot, base: base)
            let note = "Version \(key.version + 1) is version \(key.version) with the debug tuning panel's values (#232) at "
                + "\(try TunedCopy.changedPointers(in: base, values: values).joined(separator: ", ")), each listed under "
                + "placeholders until confirmed."
            let data = try TunedCopy.nextVersion(of: base, values: values, note: note)
            let url = folder.appendingPathComponent(kindFolder).appendingPathComponent("\(key.id)@\(key.version + 1).json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            urls.append(url)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = tuning
        document.name = name
        let url = folder.appendingPathComponent(TuningStore.fileName(name).replacingOccurrences(of: ".json", with: ".tuning.json"))
        try document.jsonData().write(to: url)
        return urls + [url]
    }

    func files(ofRace folder: URL) -> [URL] { store.files(ofRace: folder) }

    // MARK: - Generating

    /// The slot's base file readied for each flag the tuning sets (`TuningCatalog.FileFlag`, #436): written as a
    /// number, or added when the file leaves it out. It sails as the file does; untuned, it is the file itself.
    func readied(_ slot: TuningSlot, _ base: Data) -> Data {
        TuningCatalog.fileFlags.reduce(base) { data, flag in
            guard flag.slot == slot, tuning[values: slot][flag.pointer] != nil else { return data }
            return TunedCopy.readyingFlag(at: flag.pointer, in: data, absent: flag.absent, schemaVersion: flag.schemaVersion)
        }
    }

    /// A slot's values as JSON Pointers into its base file: a groove becomes its column's warped speeds.
    func expandedValues(_ slot: TuningSlot, base: Data) throws -> [String: Double] {
        var values: [String: Double] = [:]
        for (key, value) in tuning[values: slot] {
            guard let column = TuningSlider.grooveColumn(key) else {
                values[key] = value
                continue
            }
            guard let rows = TunedCopy.numbers(at: "/polar/twaDegrees", in: base),
                  let speeds = TunedCopy.numbers(at: "/polar/columns/\(column)/speedKnots", in: base) else {
                throw TunedCopyError.notANumber(pointer: "/polar/columns/\(column)/speedKnots")
            }
            let warped = TunedCopy.upwindAngleSpeeds(twaDegrees: rows, speedKnots: speeds, to: value)
            for (r, speed) in warped.enumerated() where speed != speeds[r] {
                values["/polar/columns/\(column)/speedKnots/\(r)"] = speed
            }
        }
        return values
    }

    /// The slot's file with its values in: a tuned copy numbered and kept in the store, or the bundled file
    /// itself when they change nothing or don't load (the problem shows on the panel).
    private func assemble<Content: DataFileContent>(_ kind: Content.Type, _ slot: TuningSlot) throws -> TunedFile<Content> {
        let key = tuning[base: slot]
        guard let base = baseData(slot) else { throw DataFileError.notBundled(kind: Content.kind, id: key.id, version: key.version) }
        let bundled = TunedFile(file: try DataFile<Content>(data: base), data: base)
        do {
            let data = try TunedCopy.patched(readied(slot, base), values: expandedValues(slot, base: base))
            guard data != base else { return bundled }
            // Loaded before it's numbered, so a copy that doesn't load never takes a tune number.
            _ = try DataFile<Content>(data: data)
            let tune = try store.tune(for: data, key: key, kindFolder: Content.bundleDirectory, memory: &memoryTunes)
            return TunedFile(file: try DataFile<Content>(data: data, tune: tune), data: data)
        } catch {
            problems[slot] = String(describing: error)
            logger.error("Tuned \(slot.rawValue, privacy: .public) failed, sailing its file: \(String(describing: error), privacy: .public)")
            return bundled
        }
    }

    /// Loads each slot's tuned copy, without numbering or keeping it, to show what's wrong and where the grooves land.
    private func validate() {
        problems = [:]
        for slot in TuningSlot.allCases {
            guard let base = baseData(slot).map({ readied(slot, $0) }) else {
                problems[slot] = "\(tuning[base: slot]) isn't in this build"
                continue
            }
            do {
                let values = try expandedValues(slot, base: base)
                switch slot {
                case .boatClass:
                    let polar = try TunedCopy.make(BoatClass.self, base: base, values: values, tune: 1).file.content.polar
                    grooves = Dictionary(uniqueKeysWithValues: polar.upwindOptima.enumerated().map { ($0.offset, rad2deg($0.element.twa)) })
                case .conditions: _ = try TunedCopy.make(Conditions.self, base: base, values: values, tune: 1)
                case .rulesConfiguration: _ = try TunedCopy.make(RulesConfig.self, base: base, values: values, tune: 1)
                }
            } catch {
                problems[slot] = String(describing: error)
            }
        }
    }

    /// After any change: check it, show the render values live, and save it (a moment later, so a slider's drag
    /// writes once).
    private func changed() {
        validate()
        showLive()
        saveTask?.cancel()
        let tuning = tuning, store = store
        saveTask = Task { [logger] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try store.saveCurrent(tuning)
            } catch {
                logger.error("Saving the tuning failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Saves now, without waiting for the moment after a change.
    func saveNow() {
        saveTask?.cancel()
        try? store.saveCurrent(tuning)
    }
}
#endif
