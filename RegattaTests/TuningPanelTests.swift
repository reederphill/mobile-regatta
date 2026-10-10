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

    /// A practice race set up on a venue and conditions (#131) keeps them under the panel: untuned conditions leave the
    /// setup's venue and conditions; tuned ones replace the conditions, at the setup's venue when it can host them.
    /// The panel's boat class and rules apply either way.
    @Test func practiceSetupsVenueAndConditionsSurviveThePanel() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        var setup = PracticeSetup()
        setup.conditions = .named("sea-breeze")
        let files = setup.config(seed: 1, windSeed: 1).files
        let untuned = model.practiceFiles(over: files)
        #expect(untuned.venue == files.venue && untuned.conditions == files.conditions)
        #expect(untuned.boatClass == RaceFiles.defaults.boatClass.ref)

        model.setBase(.conditions, DataFileKey(id: "classic-oscillating", version: 7))
        model.set(try slider("conditions:/puffs/fanDegrees", in: model), to: 12)
        model.set(try slider("boatClass:/steering/autohelm/upwindSnapDegrees", in: model), to: 5)
        let tuned = model.practiceFiles(over: files)
        #expect(tuned.conditions.key == DataFileKey(id: "classic-oscillating", version: 7) && tuned.conditions.tune != nil)
        #expect(tuned.venue == files.venue, "Hollin Bay hosts classic-oscillating@7")
        #expect(tuned.boatClass.tune != nil)
        var config = setup.config(seed: 1, windSeed: 1)
        config.files = tuned
        _ = try RaceFiles(resolving: config.setup, from: tuned.catalog)

        var fellmere = files
        fellmere.venue = try #require(PracticeVenue.named("fellmere")).ref
        let atFellmere = model.practiceFiles(over: fellmere)
        #expect(atFellmere.venue == model.practiceFiles().venue, "Fellmere can't host classic-oscillating: the panel's venue")
    }

    /// Conditions picked in the panel but not tuned still sail (#131 review): the panel's base file, not the setup's,
    /// at the setup's venue when it can host them, else at the panel's venue.
    @Test func panelsPickedUntunedConditionsSurviveTheSetup() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        var setup = PracticeSetup()
        setup.conditions = .named("sea-breeze")
        let files = setup.config(seed: 1, windSeed: 1).files
        let picked = DataFileKey(id: "classic-oscillating", version: 7)
        model.setBase(.conditions, picked)
        #expect(!model.tuning.isTuned)

        let atHollin = model.practiceFiles(over: files)
        #expect(atHollin.conditions.key == picked && atHollin.conditions.tune == nil)
        #expect(atHollin.venue == files.venue, "Hollin Bay hosts classic-oscillating@7")
        var config = setup.config(seed: 1, windSeed: 1)
        config.files = atHollin
        _ = try RaceFiles(resolving: config.setup, from: atHollin.catalog)

        var fellmere = files
        fellmere.venue = try #require(PracticeVenue.named("fellmere")).ref
        let atFellmere = model.practiceFiles(over: fellmere)
        #expect(atFellmere.conditions.key == picked)
        #expect(atFellmere.venue == model.practiceFiles().venue, "Fellmere can't host classic-oscillating: the panel's venue")
    }

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

    /// Every data slider names a number in the bundled defaults, so none is a dead slider, the skiff has a
    /// groove slider per driving polar column (4 to 25 kn), and the full-steering slider moves her turn-rate
    /// curve's last point.
    @Test func everyDataSliderNamesANumberInItsFile() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let sliders = model.groups.flatMap(\.sliders)
        // The pressure field's sliders name numbers only in schema-3 to -5 conditions (`pressureFieldIsTunable`).
        // The roll tack's sliders name numbers only in a class with a roll tack (`rollTackIsTunableOnAnOlderClass`).
        for slider in sliders where !Self.isPressureField(slider) && !Self.isRollTack(slider) {
            let file = model.fileValue(slider)
            #expect(file != nil, "\(slider.id) names nothing in its file")
            if let file { #expect(slider.range.contains(file), "\(slider.id)'s file value \(file) is off its slider") }
        }
        #expect(model.grooveColumns.map(\.knots) == [4, 6, 8, 10, 12, 14, 16, 20, 25])
        let point = try #require(model.fullSteeragePoint)
        let data = try #require(model.baseData(.boatClass))
        #expect(TunedCopy.number(at: "/steering/turnRateCurve/\(point + 1)/speedKnots", in: data) == nil, "not the last point")
        #expect(sliders.contains { $0.id == "boatClass:/steering/turnRateCurve/\(point)/speedKnots" })
        #expect(Set(sliders.map(\.id)).count == sliders.count)
    }

    /// #461: the default class, skiff@8, has no roll tack (#458), so the Roll tack group's sliders are "not in this
    /// file" on it; on skiff@7, still bundled and pickable, each names its number.
    @Test func rollTackIsTunableOnAnOlderClass() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let rolls = model.groups.flatMap(\.sliders).filter(Self.isRollTack)
        #expect(rolls.count == 3)
        #expect(rolls.allSatisfy { model.fileValue($0) == nil }, "skiff@8 has no roll tack")
        model.setBase(.boatClass, DataFileKey(id: "skiff", version: 7))
        for slider in rolls {
            let file = try #require(model.fileValue(slider), "\(slider.id) names nothing in skiff@7")
            #expect(slider.range.contains(file), "\(slider.id)'s file value \(file) is off its slider")
        }
    }

    private static func isRollTack(_ slider: TuningSlider) -> Bool { slider.id.hasPrefix("boatClass:/rollTack/") }

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

    /// The wind shadow's ribbons and the backwind's header, fade and floor (#377) are sliders on the class file's
    /// numbers: set, the next practice race's class sails them. The cone's sliders that no longer move the sim (its end
    /// width and loss only seed a class without ribbons; the backwind's loss is the header's lull now) are gone.
    @Test func ribbonAndHeaderSlidersTuneTheClass() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = Set(model.groups.flatMap(\.sliders).map(\.id))
        for gone in ["/windShadow/lossCloseIn", "/windShadow/coneWidthAtEndHullLengths", "/windShadow/backwind/loss"] {
            #expect(!ids.contains("boatClass:" + gone), "\(gone) moves nothing in the default class")
        }
        model.set(try slider("boatClass:/windShadow/ribbons/peakLoss", in: model), to: 0.3)
        model.set(try slider("boatClass:/windShadow/ribbons/buildSeconds", in: model), to: 1.5)
        model.set(try slider("boatClass:/windShadow/header/degrees", in: model), to: 10)
        model.set(try slider("boatClass:/windShadow/header/lagSeconds", in: model), to: 0.5)
        model.set(try slider("boatClass:/windShadow/backwind/fadeSeconds", in: model), to: 1)
        model.set(try slider("boatClass:/windShadow/backwind/floorKnots", in: model), to: 3)
        // The header's upwash zone (#377, the owner's renders review).
        model.set(try slider("boatClass:/windShadow/backwind/mastStationFromBow", in: model), to: 0.3)
        // A wedge from a point at her mast (the owner's renders review 3): its width there is 0 in the file, and the
        // slider reaches down to it.
        let atMast = try slider("boatClass:/windShadow/backwind/upwashWidthAtMastHullLengths", in: model)
        #expect(atMast.range.lowerBound == 0 && model.fileValue(atMast) == 0)
        model.set(atMast, to: 0.5)
        model.set(try slider("boatClass:/windShadow/backwind/upwashWidthAftHullLengths", in: model), to: 2.0)
        model.set(try slider("boatClass:/windShadow/backwind/upwashEndFadeHullLengths", in: model), to: 0.2)
        model.set(try slider("boatClass:/windShadow/backwind/upwashAftHullLengths", in: model), to: 0.5)
        #expect(model.tuning.isTuned && model.problems.isEmpty)

        var config = Self.config
        config.files = model.practiceFiles()
        #expect(config.files.boatClass.tune == 1)
        let session = GameSession(config: config)
        let shadow = try #require(session.driver as? PracticeDriver).boatClass.windShadow
        #expect(abs(shadow.ribbons.peak - 0.3) < 1e-12 && abs(shadow.ribbons.buildSeconds - 1.5) < 1e-12)
        let header = try #require(shadow.header)
        #expect(abs(header.angle - deg2rad(10)) < 1e-12 && abs(header.lagSeconds - 0.5) < 1e-12)
        #expect(abs(shadow.backwindFadeSeconds - 1) < 1e-12)
        #expect(abs((shadow.backwindFloorSpeed ?? 0) - metresPerSecond(knots: 3)) < 1e-12)
        let length = try #require(session.driver as? PracticeDriver).boatClass.hull.length
        let upwash = try #require(shadow.backwindUpwash)
        #expect(abs(upwash.mastFromBow - 0.3 * length) < 1e-12 && abs(upwash.widthAtMast - 0.5 * length) < 1e-12
                && abs(upwash.widthAft - 2.0 * length) < 1e-12
                && abs(upwash.endFade - 0.2 * length) < 1e-12 && abs((upwash.astern ?? 0) - 0.5 * length) < 1e-12)
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

    private static func isPressureField(_ slider: TuningSlider) -> Bool { slider.id.hasPrefix("conditions:/pressureField/") }

    /// #286, #287, #288: each of the pressure field's columns has a slider, which names its number in a version-7
    /// (schema 6) conditions file, and is "not in this file" before the pressure field; set, the tuned copy carries
    /// it, loads, and the practice race sails it at the venue that pairs the version-7 files. So does puff coverage.
    @Test func pressureFieldIsTunable() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressure = model.groups.flatMap(\.sliders).filter(Self.isPressureField)
        #expect(Set(pressure.map(\.id)) == Set([
            "side/strength", "side/persistenceSeconds", "side/bendDegrees", "lanes/count", "lanes/strength/min",
            "lanes/strength/max", "lanes/widthMetres/min", "lanes/widthMetres/max", "lanes/lifetimeSeconds/min",
            "lanes/lifetimeSeconds/max", "lanes/driftMetresPerSecond", "lanes/bendDegrees",
            "side/tendencyScale/min", "side/tendencyScale/max", "lanes/spotShare", "puffChoices",
            "lanes/lengthMetres/min", "lanes/lengthMetres/max", "lanes/alongDriftFraction/min",
            "lanes/alongDriftFraction/max", "lanes/weakShare",
        ].map { "conditions:/pressureField/\($0)" }))
        #expect(model.groups.first { $0.id == "conditions" }?.sliders.contains(where: Self.isPressureField) == true)
        // The default conditions (schema 2) have no pressure field.
        for slider in pressure { #expect(model.fileValue(slider) == nil, "\(slider.id) in a schema-2 file") }

        let key = DataFileKey(id: "classic-oscillating", version: 7)
        #expect(model.options(.conditions).contains(key))
        model.setBase(.conditions, key)
        var tuned: [String: Double] = [:]
        let coverage = try slider("conditions:/puffs/coverage", in: model)
        for slider in pressure + [coverage] {
            let file = try #require(model.fileValue(slider), "\(slider.id) names nothing in \(key)")
            #expect(slider.range.contains(file), "\(slider.id)'s file value \(file) is off its slider")
            // One step up, or down at the top of its range (the maxima up, so ranges stay ordered).
            let value = file + slider.step <= slider.range.upperBound ? file + slider.step : file - slider.step
            model.set(slider, to: value)
            #expect(model.isChanged(slider), "\(slider.id)")
            tuned[try #require(slider.valueKey)] = try #require(model.value(slider))
        }
        #expect(model.problems.isEmpty, "\(model.problems)")

        let files = model.practiceFiles()
        #expect(files.conditions.key == key && files.conditions.tune == 1)
        #expect(files.venue.key == DataFileKey(id: "dev-venue", version: 7))
        let data = try #require(files.tunedFiles[files.conditions])
        // The export writes each value rounded (0.15, not a step sum like 0.15000000000000002).
        func near(_ a: Double?, _ b: Double?) -> Bool { guard let a, let b else { return a == nil && b == nil }; return abs(a - b) < 1e-9 }
        for (pointer, value) in tuned { #expect(near(TunedCopy.number(at: pointer, in: data), value), "\(pointer)") }
        let field = try #require(try ConditionsFile(data: data).content.pressureField)
        #expect(near(field.side.persistence, tuned["/pressureField/side/persistenceSeconds"]))
        #expect(near(field.lanes.count, tuned["/pressureField/lanes/count"]))
        #expect(near(field.side.tendencyScale.lowerBound, tuned["/pressureField/side/tendencyScale/min"]))
        #expect(near(field.lanes.spotShare, tuned["/pressureField/lanes/spotShare"]))
        #expect(near(field.lanes.extent?.weakShare, tuned["/pressureField/lanes/weakShare"]))
        #expect(near(field.lanes.extent?.length.lowerBound, tuned["/pressureField/lanes/lengthMetres/min"]))
        #expect(near(Double(field.puffChoices), tuned["/pressureField/puffChoices"]))
        #expect(near(try ConditionsFile(data: data).content.puffs.coverage, tuned["/puffs/coverage"]))
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], boatClass: files.boatClass, venue: files.venue,
                                  conditions: files.conditions, rulesConfiguration: files.rulesConfiguration)
        let race = try RaceFiles(resolving: setup, from: files.catalog)
        #expect(race.conditions.content.pressureField == field)
    }

    /// Values persist until reset, and a slider set back to its file's value is dropped.
    @Test func valuesPersistUntilReset() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let fan = try slider("conditions:/puffs/fanDegrees", in: model)
        let edge = try slider("water.catspaw", in: model)
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
        // The boat group (#117): heel and flutter feel values.
        model.set(try slider("boat.heelScale", in: model), to: 1.5)
        #expect(session.scene.boatStyle.heelScale == 1.5)
        #expect(session.isTuned)
        #expect(model.practiceFiles() == .defaults)
    }

    /// The pressure overlay (#289) is a Debug-only switch on the panel: it reaches the live scene, persists with
    /// the tuning, and is a look to tune by, not a tuning: no TUNED badge and no tuned files.
    @Test func pressureOverlayReachesTheLiveScene() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = GameSession(config: Self.config)
        model.attach(session, files: .defaults)
        #expect(!session.scene.showsPressureOverlay && !model.showsPressure)
        #expect(model.groups.contains { $0.id == TuningCatalog.pressureOverlayGroup })
        model.showsPressure = true
        #expect(session.scene.showsPressureOverlay)
        #expect(!session.isTuned && !model.tuning.isTuned && model.practiceFiles() == .defaults)
        model.saveNow()
        #expect(TuningModel(store: model.store).showsPressure)
        model.showsPressure = false
        #expect(!session.scene.showsPressureOverlay)
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
        // Each exports as the next version of the bundled default it tunes, whatever that default is now.
        let boatClass = RaceFiles.defaults.boatClass.ref, rulesFile = RaceFiles.defaults.rulesConfiguration.ref
        #expect(urls.map(\.lastPathComponent) == ["\(boatClass.id)@\(boatClass.version + 1).json",
                                                  "\(rulesFile.id)@\(rulesFile.version + 1).json", "wide start.tuning.json"])
        let skiff = try BoatClassFile(data: Data(contentsOf: urls[0]))
        #expect(skiff.version == boatClass.version + 1 && skiff.content.steering.autohelm.upwindSnap == deg2rad(4.5))
        #expect(skiff.header.placeholders.last == "/steering/autohelm/upwindSnapDegrees")
        let rules = try RulesConfigFile(data: Data(contentsOf: urls[1]))
        #expect(rules.version == rulesFile.version + 1 && rules.header.placeholders.contains("/raceFormat/startRow/spreadLineLengths"))
        let exported = try JSONDecoder().decode(Tuning.self, from: Data(contentsOf: urls[2]))
        #expect(exported.boatClassValues == ["/steering/autohelm/upwindSnapDegrees": 4.5])
        model.delete(saved)
        #expect(model.savedTunings.isEmpty)
    }

    /// #436: the Steering group, first, holds the Auto tiller, a 0/1 slider on the class's
    /// `steering.autohelm.holdsWhenCentred` (#434). The default class (skiff@8, #461; skiff@7 before it, #437) sets it false, so it reads 0
    /// (off); 1 sails a tuned copy from the next race whose autohelm holds a centred rudder, every boat's, and exports as
    /// a schema-4 next version; back to 0 is untuned again.
    @Test func autoTillerSliderTargetsClassValue() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = try #require(model.groups.first)
        let tiller = try slider("boatClass:/steering/autohelm/holdsWhenCentred", in: model)
        #expect(group.id == "steering" && group.title == "Steering" && group.applies == .nextRace)
        #expect(group.sliders.map(\.id) == [tiller.id] && tiller.range == 0...1 && tiller.step == 1)
        #expect(model.fileValue(tiller) == 0 && model.value(tiller) == 0 && !model.tuning.isTuned)

        model.set(tiller, to: 1)
        #expect(model.value(tiller) == 1 && model.isChanged(tiller) && model.problems.isEmpty)
        var config = Self.config
        config.files = model.practiceFiles()
        #expect(config.files.boatClass.tune == 1)
        let session = GameSession(config: config)
        #expect(try #require(session.driver as? PracticeDriver).boatClass.steering.autohelm.holdsWhenCentred)

        let urls = try model.exportFiles()
        let skiff = try BoatClassFile(data: Data(contentsOf: urls[0]))
        #expect(skiff.header.schemaVersion == 4 && skiff.content.steering.autohelm.holdsWhenCentred)

        model.set(tiller, to: 0)
        #expect(!model.tuning.isTuned && model.practiceFiles().boatClass.tune == nil)
        // Back at the file's value, the race sails the bundled files byte for byte: no readied copy.
        let untouched = model.practiceFiles()
        #expect(untouched == .defaults && untouched.tunedFiles.isEmpty)
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
