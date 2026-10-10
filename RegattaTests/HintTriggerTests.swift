import CoreGraphics
import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// The hint catalogue (#23, #129): its rows, and each trigger on hand-built snapshots and real practice frames.
@MainActor @Suite struct HintTriggerTests {
    private let t = HintTuning.standard

    private func fires(_ id: HintID, _ s: HintSnapshot) -> HintFiring? {
        HintCatalogue.hint(id).trigger(s, t)
    }

    private func racing(_ edit: (inout HintSnapshot) -> Void = { _ in }) -> HintSnapshot {
        var s = HintSnapshot()
        s.status = .racing
        s.raceTime = 30
        edit(&s)
        return s
    }

    // MARK: Catalogue

    @Test func theCatalogueHasFifteenRowsWithUniqueIds() {
        #expect(HintCatalogue.all.count == 15)
        #expect(Set(HintCatalogue.all.map(\.id)) == Set(HintID.allCases))
        #expect(HintCatalogue.all.map(\.id).count == HintID.allCases.count)
        // OCS and the first rule call are the presenter's notices (ruling 1); the engine's thirteen are #171's lines
        // (the centred-rudder hint, #436, in letting go's place when the class's autohelm doesn't hold).
        #expect(HintCatalogue.all.filter { $0.delivery == .presenter }.map(\.id) == [.ocs, .ruleCall])
        #expect(HintCatalogue.engine.count == 13)
        #expect(HintCatalogue.engine.first?.id == .raceStart)
    }

    @Test func everyLineIsPlaceholderCopyShortAndNumberFree() {
        for hint in HintCatalogue.engine {
            #expect(hint.isPlaceholderCopy, "\(hint.id) TODO-COPY (#171)")
            for steering in DeviceSettings.Steering.allCases {
                let text = hint.text.text(for: steering)
                #expect(!text.isEmpty && text.count <= 56, "\(hint.id): \(text)")
                #expect(text.rangeOfCharacter(from: .decimalDigits) == nil, "\(hint.id): \(text)")
            }
        }
        // The first hint is the scheme's own and mentions the other one in Settings.
        let start = HintCatalogue.hint(.raceStart).text
        #expect(start.halves != start.tiller)
        #expect(start.halves.contains("Tiller is in Settings") && start.tiller.contains("Settings"))
        #expect(HintCatalogue.hint(.lettingGo).text.halves == "Let go and she holds her angle to the wind")
        #expect(HintCatalogue.hint(.centredRudder).text.halves == "A centred rudder sails straight on.")
    }

    @Test func progressKeysAreUnderTheHintPrefixApartFromPlainWords() {
        let plain = [RuleSeenStore.rulesKey, RuleSeenStore.rulesAgainstKey, RuleSeenStore.autohelmKey]
        for id in HintID.allCases {
            for key in [HintProgressStore.shownKey(id), HintProgressStore.learnedKey(id)] {
                #expect(key.hasPrefix(DeviceSettings.hintKeyPrefix))
                #expect(!plain.contains(key))
            }
        }
    }

    // MARK: Triggers

    @Test func raceStartFiresAtOnceAndStartSequenceBeforeTheLastSeconds() {
        var pre = HintSnapshot()
        pre.raceTime = -50
        #expect(fires(.raceStart, pre) != nil)
        #expect(fires(.startSequence, pre) != nil)
        pre.raceTime = -5
        #expect(fires(.startSequence, pre) == nil)
        #expect(fires(.startSequence, racing()) == nil)
    }

    @Test func noGoWaitsItsDwellAndNotWhileTacking() {
        #expect(fires(.noGo, racing { $0.noGoSeconds = 1 }) == nil)
        #expect(fires(.noGo, racing { $0.noGoSeconds = 2 })?.leader == .vane)
        #expect(fires(.noGo, racing { $0.noGoSeconds = 2; $0.inManoeuvre = true }) == nil)
        #expect(fires(.noGo, racing { $0.noGoSeconds = 2; $0.steeringSeconds = 0.5 }) == nil, "a turn in progress")
    }

    /// #460: with no Tack button the no-go hint says to steer through the wind, and it never nags a hand tack on its
    /// way through the no-go zone: only a centred rudder, pinched or in irons, fires it.
    @Test func tooCloseToTheWindSaysSteer() throws {
        let hint = HintCatalogue.hint(.noGo)
        for steering in [DeviceSettings.Steering.halves, .tiller] {
            #expect(hint.text.text(for: steering) == "Too close to the wind. Steer through it.")
        }
        #expect(HintID.noGo.rawValue == "no_go", "its progress key is saved on devices")
        for hint in HintCatalogue.all {
            let words = hint.text.halves + " " + hint.text.tiller
            #expect(!words.localizedCaseInsensitiveContains("tap tack") && !words.contains("button"), "\(hint.id)")
        }
        #expect(fires(.noGo, racing { $0.noGoSeconds = 60; $0.steeringSeconds = 60 }) == nil, "however slow the turn")
        #expect(fires(.noGo, racing { $0.noGoSeconds = 60 })?.leader == .vane, "let go in irons")

        // Help's Steering page says the same, under Let go, and has no Buttons section.
        let url = RaceDriverTests.repoRoot.appending(path: "Regatta/UI/Help/HelpTopics.swift")
        let help = try String(contentsOf: url, encoding: .utf8)
        let letGo = try #require(help.range(of: "HelpSection(heading: \"Let go\""))
        let section = help[letGo.lowerBound...].prefix(400)
        #expect(section.contains("\"Steer through the wind to tack or gybe.\""))
        #expect(!help.contains("heading: \"Buttons\"") && !help.contains("Tack: tap"))
    }

    @Test func lettingGoFiresEarlyInTheFirstRace() {
        let five = racing { $0.steeringSeconds = 5.5 }
        #expect(fires(.lettingGo, five) == nil, "not before about 20 s outside the first race")
        #expect(fires(.lettingGo, racing { $0.steeringSeconds = 5.5; $0.isFirstRace = true })?.leader == .vane)
        #expect(fires(.lettingGo, racing { $0.steeringSeconds = 19 }) == nil)
        #expect(fires(.lettingGo, racing { $0.steeringSeconds = 21 }) != nil)
        #expect(fires(.lettingGo, racing { $0.steeringSeconds = 21; $0.hasLetGo = true }) == nil)
        // Only once relevant (owner ruling 2026-10-05): never on racing time alone, without steering.
        #expect(fires(.lettingGo, racing { $0.raceTime = 120; $0.racingSeconds = 120; $0.isFirstRace = true }) == nil)
        #expect(fires(.lettingGo, racing { $0.raceTime = 120; $0.racingSeconds = 120 }) == nil)
        // After the gun, whether or not you've started yet; never before it.
        var behind = HintSnapshot()
        behind.raceTime = 6
        behind.steeringSeconds = 6
        behind.isFirstRace = true
        #expect(fires(.lettingGo, behind) != nil)
        behind.raceTime = -30
        behind.steeringSeconds = 30
        #expect(fires(.lettingGo, behind) == nil)
    }

    /// #436: on a class whose autohelm doesn't hold a centred rudder, the centred-rudder hint takes letting go's
    /// place, on its timing (sooner in the first race, only once you've steered without a break, after the gun);
    /// with the autohelm holding, letting go shows and it never does. It points at the vane, shows once a race and
    /// retires as it shows. A real race's snapshot reads the class's setting.
    @Test func centredRudderHintOnlyWithAutohelmOff() throws {
        func hand(_ edit: (inout HintSnapshot) -> Void) -> HintSnapshot {
            racing { $0.autohelmHolds = false; edit(&$0) }
        }
        #expect(fires(.centredRudder, hand { $0.steeringSeconds = 5.5; $0.isFirstRace = true })?.leader == .vane)
        #expect(fires(.centredRudder, hand { $0.steeringSeconds = 5.5 }) == nil, "not before about 20 s after the first race")
        #expect(fires(.centredRudder, hand { $0.steeringSeconds = 21 }) != nil)
        #expect(fires(.centredRudder, hand { $0.raceTime = 120; $0.racingSeconds = 120; $0.isFirstRace = true }) == nil,
                "never without steering")
        #expect(fires(.centredRudder, hand { $0.raceTime = -30; $0.steeringSeconds = 30; $0.isFirstRace = true }) == nil)
        #expect(fires(.lettingGo, hand { $0.steeringSeconds = 21; $0.isFirstRace = true }) == nil, "letting go is wrong then")
        // The autohelm holding: letting go, never the centred rudder.
        let held = racing { $0.steeringSeconds = 21; $0.isFirstRace = true }
        #expect(fires(.centredRudder, held) == nil && fires(.lettingGo, held) != nil)
        let row = HintCatalogue.hint(.centredRudder)
        #expect(row.learning == .shown && HintEngine.oncePerRace.contains(.centredRudder))

        func snapshot(_ files: PracticeFiles) -> HintSnapshot {
            var config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
            config.files = files
            return HintSnapshot(world: PracticeDriver(config: config).renderWorld, observations: HintObservations(),
                                showsLaylines: false, isFirstRace: true, lettingGoRetired: false, tuning: t)
        }
        #expect(try snapshot(Self.autohelmOnFiles()).autohelmHolds)
        #expect(!snapshot(.defaults).autohelmHolds, "the default class, skiff@8, steers by hand (#437, #461)")
    }

    /// Practice files whose autohelm doesn't hold a centred rudder: the defaults, since the default class is skiff@8
    /// (#461; skiff@7 from #437; before it, the Auto tiller's tuned copy, #436).
    static func handSteeredFiles() throws -> PracticeFiles { .defaults }

    /// Practice files sailing skiff@6, whose autohelm holds a centred rudder (the default until #437).
    static func autohelmOnFiles() throws -> PracticeFiles {
        var files = PracticeFiles.defaults
        files.boatClass = try BoatClassFile.bundled(id: "skiff", version: 6).ref
        return files
    }

    @Test func grooveTickFollowsLettingGo() {
        let s = racing { $0.vaneShows = true; $0.hasLetGo = true }
        #expect(fires(.grooveTick, s) == nil)
        #expect(fires(.grooveTick, racing { $0.vaneShows = true; $0.hasLetGo = true; $0.lettingGoRetired = true }) != nil)
        #expect(fires(.grooveTick, racing { $0.vaneShows = true; $0.lettingGoRetired = true; $0.racingSeconds = 61 }) != nil)
        #expect(fires(.grooveTick, racing { $0.vaneShows = true; $0.lettingGoRetired = true; $0.racingSeconds = 30 }) == nil)
        // A player who never steers (letting go never learned) still reaches it after a minute's racing.
        #expect(fires(.grooveTick, racing { $0.vaneShows = true; $0.racingSeconds = 61 }) != nil)
        #expect(fires(.grooveTick, racing { $0.racingSeconds = 61 }) == nil, "not without the vane")
    }

    @Test func situationalHintsPointAtTheirThing() {
        let p = Vec2(10, 20)
        #expect(fires(.windShift, racing { $0.shiftDegrees = 4.9 }) == nil)
        #expect(fires(.windShift, racing { $0.shiftDegrees = 5.1 })?.leader == .vane)
        #expect(fires(.puff, racing { $0.nearPuff = p })?.leader == .point(p))
        #expect(fires(.windShadow, racing { $0.shadowSeconds = 1 }) == nil)
        #expect(fires(.windShadow, racing { $0.shadowSeconds = 2; $0.shadowSource = 3 })?.leader == .boat(3))
        #expect(fires(.layline, racing { $0.nearLayline = p })?.leader == .point(p))
        #expect(fires(.redGlow, racing { $0.redGlow = 1 })?.leader == .boat(1))
        #expect(fires(.greenGlow, racing { $0.greenGlow = 4 })?.leader == .boat(4))
        #expect(fires(.markZone, racing { $0.markZone = p })?.leader == .point(p))
        for id in HintID.allCases where id != .raceStart && id != .startSequence {
            #expect(fires(id, HintSnapshot()) == nil, "\(id) on an empty prestart snapshot")
        }
        // Racing unless noted (the brief): the situational hints don't fire before the gun.
        var pre = HintSnapshot()
        pre.raceTime = -30
        pre.nearPuff = p
        pre.shadowSeconds = 5
        pre.redGlow = 1
        pre.greenGlow = 2
        pre.markZone = p
        for id in [HintID.puff, .windShadow, .redGlow, .greenGlow, .markZone] {
            #expect(fires(id, pre) == nil, "\(id) before the gun")
        }
    }

    @Test func snapshotHelpersPickTheNearestAndStrongest() {
        let lines = [(from: Vec2(0, 0), to: Vec2(0, 100))]
        #expect(HintSnapshot.nearestPoint(on: lines, to: Vec2(5, 50), within: 10) == Vec2(0, 50))
        #expect(HintSnapshot.nearestPoint(on: lines, to: Vec2(20, 50), within: 10) == nil)
        let glows: [RightOfWayGlow?] = [nil, RightOfWayGlow(kind: .giveWay, intensity: 0.6),
                                        RightOfWayGlow(kind: .giveWay, intensity: 0.9),
                                        RightOfWayGlow(kind: .hasRight, intensity: 0.4)]
        #expect(HintSnapshot.strongest(.giveWay, in: glows, atLeast: 0.5) == 2)
        #expect(HintSnapshot.strongest(.hasRight, in: glows, atLeast: 0.5) == nil)
        let strong = Puff(center: Vec2(0, 30), radius: 20, strength: 0.3, age: 50, lifetime: 100)
        let faint = Puff(center: Vec2(0, 12), radius: 10, strength: 0.01, age: 50, lifetime: 100)
        #expect(HintSnapshot.nearPuff([faint, strong], to: .zero, within: 15) == Vec2(0, 30))
        #expect(HintSnapshot.nearPuff([faint, strong], to: .zero, within: 5) == nil)
    }

    // MARK: Real frames

    /// Steering a real practice boat both ways is seen, by race time, and letting go after steering counts as let go.
    /// On skiff@6 (#437): letting go is a centred rudder the autohelm holds, which the default, skiff@7, has not.
    @Test func observationsSeeSteeringBothWaysAndLettingGo() throws {
        var config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        config.files = try Self.autohelmOnFiles()
        let driver = PracticeDriver(config: config)
        var o = HintObservations()
        func run(_ rudder: Int8, seconds: Double) {
            driver.submit(BoatInput(rudder: rudder))
            for _ in 0..<Int(seconds * 15) {
                driver.tick(1.0 / 15)
                o.observe(driver.renderWorld, tuning: .standard)
            }
        }
        // The first frame, before the race's first step: no autohelm yet and the rudder centred is not steering.
        o.observe(driver.renderWorld, tuning: .standard)
        #expect(!o.hasSteered)
        run(0, seconds: 2)
        #expect(!o.hasSteered && !o.hasLetGo, "the autohelm engaging on its own isn't letting go")
        run(100, seconds: 1)
        #expect(!o.steeredBothWays(.standard))
        #expect(o.hasSteered)
        #expect(o.steeringSeconds == 0, "steering time counts from the gun")
        run(-100, seconds: 1)
        #expect(o.steeredBothWays(.standard))
        #expect(!o.hasLetGo)
        run(0, seconds: 2)
        #expect(o.hasLetGo)
        #expect(o.steeringSeconds == 0)
        let snapshot = HintSnapshot(world: driver.renderWorld, observations: o, showsLaylines: true, isFirstRace: false,
                                    lettingGoRetired: false, tuning: .standard)
        #expect(snapshot.status == .prestart && snapshot.hasLetGo)
    }

    /// #436: on a hand-steered class a tap's autohelm (the tack and the hand-back) isn't letting go, so the
    /// centred-rudder hint still fires afterwards and letting go is never learned for it. On skiff@7, hand-steered
    /// with a tap the autohelm sails: the default, skiff@8, sails no tap (#458).
    @Test func aTappedTackOnAHandSteeredClassIsNotLettingGo() throws {
        var config = RaceConfig(opponents: 1, prestartSeconds: 1, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        config.files = try Self.handSteeredFiles()
        config.files.boatClass = try BoatClassFile.bundled(id: "skiff", version: 7).ref
        let driver = PracticeDriver(config: config)
        var o = HintObservations()
        func run(_ rudder: Int8, seconds: Double) {
            driver.submit(BoatInput(rudder: rudder))
            for _ in 0..<Int(seconds * 15) {
                driver.tick(1.0 / 15)
                o.observe(driver.renderWorld, tuning: .standard)
            }
        }
        run(0, seconds: 2)
        run(40, seconds: 1)
        #expect(o.hasSteered)
        driver.submit(BoatInput(rudder: Int8(0)))
        #expect(driver.tap(.tackGybe))
        var tapped = 0.0
        for _ in 0..<(10 * 15) {
            driver.tick(1.0 / 15)
            o.observe(driver.renderWorld, tuning: .standard)
            if driver.renderWorld.me.autohelm != nil { tapped += 1.0 / 15 }
        }
        #expect(tapped >= HintTuning.standard.autohelmHoldSeconds, "the tap's autohelm held long enough to count")
        #expect(!o.hasLetGo, "a tap's autohelm isn't letting go")
        run(40, seconds: 6)
        let snapshot = HintSnapshot(world: driver.renderWorld, observations: o, showsLaylines: false, isFirstRace: true,
                                    lettingGoRetired: false, tuning: .standard)
        #expect(!snapshot.hasLetGo && !snapshot.autohelmHolds)
        #expect(fires(.centredRudder, snapshot) != nil)
    }

    // MARK: Tuning

    /// The thresholds are debug sliders (ruling 3): a saved tuning missing a field keeps its standard value, and a
    /// session's are live.
    @Test func tuningDecodesLenientlyAndReachesTheSession() throws {
        let tuning = try JSONDecoder().decode(HintTuning.self, from: Data(#"{"lettingGoSeconds": 30}"#.utf8))
        #expect(tuning.lettingGoSeconds == 30 && tuning.lettingGoFirstRaceSeconds == 5 && tuning.shiftDegrees == 5)
        let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let engine = HintEngine(progress: HintProgressStore())
        let session = GameSession(config: config, hints: engine)
        session.hintTuning = tuning
        #expect(engine.thresholds == tuning)
        #if DEBUG
        let ids = TuningCatalog.groups(grooveColumns: [], fullSteeragePoint: nil).flatMap(\.sliders).map(\.id)
        #expect(ids.contains("hint.lettingGoSeconds") && ids.contains("hint.lettingGoFirstRaceSeconds"))
        #endif
    }

    // MARK: Leader line

    @Test func leaderLineStopsShortOfAVisibleTarget() throws {
        let visible = CGRect(x: 0, y: 100, width: 400, height: 600)
        let anchor = CGPoint(x: 200, y: 750)
        let line = try #require(HintLeader.segment(anchor: anchor, target: CGPoint(x: 200, y: 300), visible: visible))
        #expect(line.from == anchor)
        #expect(abs(line.to.y - (300 + HintLeader.targetGap)) < 1e-9 && line.to.x == 200)
        // Off screen or under the HUD: no line.
        #expect(HintLeader.segment(anchor: anchor, target: CGPoint(x: 200, y: 50), visible: visible) == nil)
        #expect(HintLeader.segment(anchor: anchor, target: CGPoint(x: 200, y: 720), visible: visible) == nil)
        #expect(HintLeader.segment(anchor: anchor, target: CGPoint(x: 500, y: 300), visible: visible) == nil)
        // The path is rebuilt only once an end moves more than half a point.
        #expect(!HintLeaderLayer.moved(CGPoint(x: 10, y: 10), CGPoint(x: 10.3, y: 10.3)))
        #expect(HintLeaderLayer.moved(CGPoint(x: 10, y: 10), CGPoint(x: 10.6, y: 10)))
    }
}
