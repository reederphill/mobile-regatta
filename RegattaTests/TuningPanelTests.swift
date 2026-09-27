import Foundation
import Testing
import RegattaCore
@testable import Regatta

#if DEBUG
/// The debug tuning panel (#232): its sliders write tuned copies (#229) that the next practice race sails and
/// resolves from its catalog, its render values reach the live scene, and a tuned race's log is kept with its
/// tuned copies beside it so it replays.
@MainActor @Suite struct TuningPanelTests {
    /// A model on a store in a fresh temporary folder, and that folder.
    private func model() -> (TuningModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString)", isDirectory: true)
        return (TuningModel(store: TuningStore(root: root)), root)
    }

    private func slider(_ id: String, in model: TuningModel) throws -> TuningSlider {
        try #require(model.groups.flatMap(\.sliders).first { $0.id == id }, "no slider \(id)")
    }

    private static let config = RaceConfig(opponents: 3, prestartSeconds: 30, seed: 232, windSeed: RaceConfig.windSeed(pinnedTo: 232))

    /// Untouched, the panel sails the bundled defaults, with no badge.
    @Test func untunedPanelSailsTheBundledFiles() {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.tuning.isTuned)
        let files = model.practiceFiles()
        #expect(files == .defaults)
        #expect(files.tunedFiles.isEmpty && !files.isTuned)
        #expect(model.problems.isEmpty)
    }

    /// Every data slider names a number in the bundled defaults, so none is a dead slider, and the skiff has a
    /// groove slider per driving polar column (4 to 25 kn).
    @Test func everyDataSliderNamesANumberInItsFile() {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let sliders = model.groups.flatMap(\.sliders)
        for slider in sliders {
            let file = model.fileValue(slider)
            #expect(file != nil, "\(slider.id) names nothing in its file")
            if let file { #expect(slider.range.contains(file), "\(slider.id)'s file value \(file) is off its slider") }
        }
        #expect(model.grooveColumns.map(\.knots) == [4, 6, 8, 10, 12, 14, 16, 20, 25])
        #expect(Set(sliders.map(\.id)).count == sliders.count)
    }

    /// Tuned values become tuned copies at the race start: the practice race resolves them from its catalog and
    /// sails them (bots too), and its log, kept with them beside it as it leaves, replays to its digest.
    @Test func tunedPracticeRaceSailsTunedCopiesAndItsKeptLogReplays() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setBase(.conditions, DataFileKey(id: "classic-oscillating", version: 3))
        model.set(try slider("conditions:/shift/periodSeconds/max", in: model), to: 120)
        model.set(try slider("conditions:/puffs/fanDegrees", in: model), to: 12)
        model.set(try slider("boatClass:/steering/autohelm/upwindSnapDegrees", in: model), to: 5)
        model.set(try slider("groove:5", in: model), to: 41)
        #expect(model.tuning.isTuned && model.problems.isEmpty)

        var config = Self.config
        config.files = model.practiceFiles()
        #expect(config.files.conditions.tune == 1 && config.files.boatClass.tune == 1)
        #expect(config.files.rulesConfiguration == RaceFiles.defaults.rulesConfiguration.ref)
        #expect(config.files.venue.key == DataFileKey(id: "dev-venue", version: 3))
        #expect(config.setup.conditions == config.files.conditions)

        let session = GameSession(config: config)
        model.attach(session, files: config.files)
        #expect(session.isTuned)
        let driver = try #require(session.driver as? PracticeDriver)
        #expect(driver.boatClass.steering.autohelm.upwindSnap == deg2rad(5))
        #expect(abs(rad2deg(driver.boatClass.polar.upwindOptima[5].twa) - 41) <= 2)
        for _ in 0..<(20 * Race.tickRate) { driver.tick(1 / Double(Race.tickRate)) }

        model.archive(session)
        model.archive(session) // once per session
        #expect(model.races.count == 1)
        let (log, catalog) = try RaceLogFolder.read(try #require(model.races.first))
        #expect(log == driver.log)
        #expect(log.header.setup.conditions == config.files.conditions)
        #expect(try Replayer.digest(of: log, catalog: catalog) == driver.digest())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("files/conditions/classic-oscillating@3+tune1.json").path))
    }

    /// The same values give the same tuned copy, under the same tune number, race after race; new values take
    /// the next number, and the old copy stays as it was for the logs that name it.
    @Test func sameValuesKeepTheirTuneNumber() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let wobble = try slider("conditions:/shift/wobbleDegrees", in: model)
        model.set(wobble, to: 2)
        let first = model.practiceFiles().conditions
        #expect(model.practiceFiles().conditions == first)
        model.saveNow()
        #expect(TuningModel(store: model.store).practiceFiles().conditions == first)
        model.set(wobble, to: 3)
        let second = model.practiceFiles().conditions
        #expect(first.tune == 1 && second.tune == 2 && first.hash != second.hash)
        model.set(wobble, to: 2)
        #expect(model.practiceFiles().conditions == first)

        // A copy staged but never moved into place (the app stopped between the two) is cleared at the next
        // launch; the copies in place stay.
        let folder = root.appendingPathComponent("files/\(Conditions.bundleDirectory)", isDirectory: true)
        let name = "\(first.id)@\(first.version)+tune"
        let staged = folder.appendingPathComponent(".\(name)3-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: staged)
        _ = TuningModel(store: model.store)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["\(name)1.json", "\(name)2.json"])
    }

    /// Values persist until reset, and a slider set back to its file's value is dropped.
    @Test func valuesPersistUntilReset() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let fan = try slider("conditions:/puffs/fanDegrees", in: model)
        let edge = try slider("water.edgeTintStrength", in: model)
        model.set(fan, to: 8.3) // to its step: 8.5
        model.set(edge, to: 0.5)
        #expect(model.value(fan) == 8.5 && model.isChanged(fan))
        model.saveNow()
        let reopened = TuningModel(store: model.store)
        #expect(reopened.tuning == model.tuning)
        #expect(reopened.value(edge) == 0.5)

        reopened.set(fan, to: try #require(reopened.fileValue(fan)))
        #expect(reopened.tuning.conditionsValues.isEmpty)
        #expect(reopened.tuning.isTuned) // the water still differs
        let group = try #require(reopened.groups.first { $0.id == "water" })
        reopened.reset(group)
        #expect(!reopened.tuning.isTuned)
        model.set(fan, to: 12)
        model.resetAll()
        #expect(model.tuning == Tuning())
    }

    /// Render values reach the live race's scene as they change: they're not data and never logged.
    @Test func renderValuesReachTheLiveScene() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = GameSession(config: Self.config)
        model.attach(session, files: .defaults)
        #expect(!session.isTuned)
        model.set(try slider("water.fullTonePuffGain", in: model), to: 0.2)
        model.set(try slider("camera.lookAheadSeconds", in: model), to: 3)
        #expect(session.scene.waterStyle.fullTonePuffGain == 0.2)
        #expect(session.scene.cameraStyle.lookAheadSeconds == 3)
        #expect(model.practiceFiles() == .defaults)
    }

    /// Values a file can't hold (a wobble past the amplitude) show why on the panel, and the race sails that
    /// slot's bundled file.
    @Test func valuesAFileRefusesSailTheBundledFile() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.set(try slider("conditions:/shift/wobbleDegrees", in: model), to: 9)
        #expect(model.problems[.conditions]?.contains("wobble") == true)
        #expect(model.practiceFiles().conditions == RaceFiles.defaults.conditions.ref)
    }

    /// Saved tunings load back, and the export writes each tuned file as its next version, ready for Resources,
    /// with the changed values under `placeholders`.
    @Test func savedTuningsLoadAndExportNextVersions() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try slider("boatClass:/steering/autohelm/upwindSnapDegrees", in: model)
        let spread = try slider("rulesConfiguration:/raceFormat/startRow/spreadLineLengths", in: model)
        model.set(snap, to: 4.5)
        model.set(spread, to: 2)
        model.save(as: "wide start")
        model.resetAll()
        let saved = try #require(model.savedTunings.first)
        #expect(saved.name == "wide start" && model.savedTunings.count == 1)
        model.load(saved)
        #expect(model.value(snap) == 4.5 && model.value(spread) == 2)

        let urls = try model.exportFiles(named: "wide start")
        #expect(urls.map(\.lastPathComponent) == ["skiff@3.json", "fleet-rules@4.json", "wide start.tuning.json"])
        let skiff = try BoatClassFile(data: Data(contentsOf: urls[0]))
        #expect(skiff.version == 3 && skiff.content.steering.autohelm.upwindSnap == deg2rad(4.5))
        #expect(skiff.header.placeholders.last == "/steering/autohelm/upwindSnapDegrees")
        let rules = try RulesConfigFile(data: Data(contentsOf: urls[1]))
        #expect(rules.version == 4 && rules.header.placeholders.contains("/raceFormat/startRow/spreadLineLengths"))
        let exported = try JSONDecoder().decode(Tuning.self, from: Data(contentsOf: urls[2]))
        #expect(exported.boatClassValues == ["/steering/autohelm/upwindSnapDegrees": 4.5])
        model.delete(saved)
        #expect(model.savedTunings.isEmpty)
    }
}

/// The panel is compiled only under the flag the store build config leaves out (#232, #170): `DEBUG`. The
/// orchestrator's ruling on #232 gates it on `DEBUG` rather than a new `TUNING` flag.
@MainActor @Suite struct TuningBuildConfigTests {
    private static let project = RaceDriverTests.repoRoot.appending(path: "Regatta.xcodeproj")

    /// Every build configuration in the project: its name and its settings' text.
    private func configurations() throws -> [(name: String, settings: String)] {
        let text = try String(contentsOf: Self.project.appending(path: "project.pbxproj"), encoding: .utf8)
        let block = /isa = XCBuildConfiguration;\s*buildSettings = \{(?<settings>.*?)\n\t\t\t\};\s*name = (?<name>\w+);/
            .dotMatchesNewlines()
        return text.matches(of: block).map { (String($0.output.name), String($0.output.settings)) }
    }

    /// The compilation conditions a configuration's settings define: every word of its Swift conditions and
    /// flags and its preprocessor definitions.
    private func conditions(in settings: String) -> Set<String> {
        let setting = /(SWIFT_ACTIVE_COMPILATION_CONDITIONS|OTHER_SWIFT_FLAGS|GCC_PREPROCESSOR_DEFINITIONS)\s*=\s*(?<value>\([^)]*\)|"[^"]*"|[^;]*);/
        return Set(settings.matches(of: setting).flatMap { match in
            match.output.value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
        })
    }

    /// The scheme archives (for TestFlight and the App Store) with Release, whose settings define neither
    /// `DEBUG` nor `TUNING` as a condition, while Debug defines `DEBUG`.
    @Test func storeBuildConfigExcludesTheTuningFlag() throws {
        let scheme = try String(contentsOf: Self.project.appending(path: "xcshareddata/xcschemes/Regatta.xcscheme"), encoding: .utf8)
        let archive = try #require(scheme.firstMatch(of: /<ArchiveAction\s+buildConfiguration = "(\w+)"/))
        #expect(archive.output.1 == "Release")

        let configurations = try configurations()
        #expect(configurations.filter { $0.name == "Release" }.count >= 2, "the project's and the app's Release")
        for (name, settings) in configurations where name == "Release" {
            #expect(conditions(in: settings).isDisjoint(with: ["DEBUG", "TUNING"]), "a Release configuration defines the flag")
        }
        #expect(configurations.contains { $0.name == "Debug" && conditions(in: $0.settings).contains("DEBUG") })
    }

    /// Every file of the panel is wrapped in `#if DEBUG`, and every use of it elsewhere in the app sits inside an
    /// `#if DEBUG` block, so a Release build has no panel, no Home row, no pause-menu button and no `-tuning`.
    @Test func tuningPanelIsCompiledOnlyUnderTheFlag() throws {
        let app = RaceDriverTests.repoRoot.appending(path: "Regatta")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let panel = files.filter { $0.deletingLastPathComponent().lastPathComponent == "Tuning" }
        #expect(panel.count >= 4)
        for file in panel {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(lines.first == "#if DEBUG" && lines.last == "#endif", "\(file.lastPathComponent) isn't wrapped in #if DEBUG")
        }
        let uses = /\b(TuningModel|TuningView|TuningStore|TunedBadge|TuningSlot|TuningSlider|\.tuning\b|"-tuning")/
        for file in files where !panel.contains(file) {
            var debug: [Bool] = [] // one per open #if: whether it's the DEBUG branch
            for (number, raw) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if ") {
                    debug.append(line == "#if DEBUG")
                } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                    if !debug.isEmpty { debug[debug.count - 1] = false }
                } else if line.hasPrefix("#endif") {
                    _ = debug.popLast()
                } else if !line.hasPrefix("//"), !line.hasPrefix("///"), line.firstMatch(of: uses) != nil {
                    #expect(debug.contains(true), "\(file.lastPathComponent):\(number + 1) uses the tuning panel outside #if DEBUG")
                }
            }
        }
    }
}
#endif
