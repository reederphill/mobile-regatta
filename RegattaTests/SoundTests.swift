import AVFoundation
import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// Records what reaches it.
final class RecordingSound: SoundOutput {
    var played: [SoundCue] = []
    var ambience: [AmbienceGains] = []
    func play(_ cue: SoundCue) { played.append(cue) }
    func setAmbience(_ gains: AmbienceGains) { ambience.append(gains) }
}

/// Records what the music was told.
final class RecordingMusic: MusicOutput {
    var calls: [String] = []
    func fadeIn() { calls.append("in") }
    func fadeOut() { calls.append("out") }
}

/// The committee's start sequence on the race clock (#126, #22).
@MainActor @Suite struct SoundScheduleTests {
    private static let tick = 1.0 / Double(Race.tickRate)

    /// A 60 s sequence stepped tick by tick on a mock clock: exactly #22's list, each at its second.
    @Test func sixtySecondSequenceGivesTheCueList() {
        var schedule = SoundSchedule(sequenceSeconds: 60)
        var heard: [(time: Double, cue: SoundCue)] = []
        for tick in -1800...60 {
            let time = Double(tick) * Self.tick
            heard += schedule.cues(at: time).map { (time, $0) }
        }
        let expected: [(Double, SoundCue)] = [(-60, .sequenceHorn), (-30, .sequenceHorn), (-5, .beep), (-4, .beep),
                                              (-3, .beep), (-2, .beep), (-1, .beep), (0, .gun)]
        #expect(heard.map(\.cue) == expected.map(\.1))
        for (got, want) in zip(heard, expected) { #expect(abs(got.time - want.0) < 1e-9, "\(got.cue) at \(got.time)") }
    }

    /// The same list through a practice race's session, stepped by its own driver, with the gun's event ignored
    /// (the clock sounds it) and nothing else in the start.
    @Test func aPracticeRaceSoundsTheSequenceOnItsClock() {
        let config = RaceConfig(opponents: 1, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let recorder = RecordingSound()
        let session = GameSession(config: config, sound: recorder)
        while session.driver.currentFrame.time < 0.5 {
            session.driver.tick(Self.tick)
            session.consume(session.driver.drainEvents())
        }
        // Nobody steers your boat here, so she may be over at the gun too: that's her OCS horn, not the clock's.
        #expect(recorder.played.filter { $0.visual == .hudClock }
                == [.sequenceHorn, .sequenceHorn, .beep, .beep, .beep, .beep, .beep, .gun])
        #expect(recorder.played.allSatisfy { $0.visual == .hudClock || $0 == .ocsHorn })
    }

    /// A late joiner hears only what's still to come; a start exactly on a mark hears it; a clock set back or
    /// standing still (paused) fires nothing again.
    @Test func lateJoinAndPauseNeverReplay() {
        var late = SoundSchedule()
        #expect(late.cues(at: -45).isEmpty, "the 60 s horn is long gone")
        #expect(late.cues(at: -30) == [.sequenceHorn])
        #expect(late.cues(at: -31).isEmpty, "an online correction back")
        #expect(late.cues(at: -30).isEmpty, "no replay")
        #expect(late.cues(at: -30).isEmpty, "a paused clock")

        var onTheMark = SoundSchedule()
        #expect(onTheMark.cues(at: -60) == [.sequenceHorn])

        // A pause is no calls: the clock picks up where it stopped.
        var paused = SoundSchedule()
        #expect(paused.cues(at: -62).isEmpty)
        #expect(paused.cues(at: -40) == [.sequenceHorn])

        // A 30 s sequence has no 60 s horn.
        #expect(SoundSchedule(sequenceSeconds: 30).marks.first == .init(time: -30, cue: .sequenceHorn))
    }
}

/// Every sound has something on screen (#22), and the presenter's cues choose their sounds (#126).
@MainActor @Suite struct SoundCueTests {
    private static let me = 0

    private static func event(_ kind: RaceEvent.Kind) -> RaceEvent { RaceEvent(tick: 0, kind: kind) }

    private static func call(offender: Int, victim: Int, incident: Int) -> RaceEvent {
        event(.ruleCall(RuleCall(incidentId: incident, tick: incident, rule: .portStarboard, offender: offender,
                                 victim: victim, leg: 0, turnsOwed: 1, startDeadlineTick: nil,
                                 completeDeadlineTick: nil)))
    }

    /// Every audio cue has a paired visual event: the table, every cue and layer in it, and every manifest sound but
    /// the menus' music is a race sound with one.
    @Test func everyAudioCueHasAPairedVisual() {
        let cues: [SoundCue: VisualCounterpart] = [
            .sequenceHorn: .hudClock, .beep: .hudClock, .gun: .hudClock, .ocsHorn: .ocsNotice,
            .whistle: .ruleCallLine, .bell: .activeMarkAdvances, .finishHorn: .finishedPlace,
        ]
        #expect(Set(SoundCue.allCases) == Set(cues.keys))
        for cue in SoundCue.allCases { #expect(cue.visual == cues[cue], "\(cue)") }
        let layers: [AmbienceLayer: VisualCounterpart] = [
            .windLight: .windReadout, .windMedium: .windReadout, .windStrong: .windReadout, .waterSlow: .wake,
            .waterFast: .wake, .sailFlog: .sailFlutter,
        ]
        #expect(Set(AmbienceLayer.allCases) == Set(layers.keys))
        for layer in AmbienceLayer.allCases { #expect(layer.visual == layers[layer], "\(layer)") }

        let used = Set(SoundCue.allCases.map(\.asset) + AmbienceLayer.allCases.map(\.asset))
        #expect(used == Set(SoundAsset.allCases).subtracting([.menuMusic]))
        // The manifest's names (#53).
        #expect(SoundAsset.allCases.map(\.rawValue) == [
            "horn", "gun", "beep", "whistle", "bell", "wind-light", "wind-medium", "wind-strong", "water-slow",
            "water-fast", "sail-flog", "menu-music",
        ])
        for asset in SoundAsset.allCases {
            #expect(asset.fileExtension == (asset == .menuMusic ? "m4a" : "caf"))
            #expect(SoundLibrary().isPlaceholder(asset), "no bundled audio until #169")
        }
    }

    /// The presenter's cues into sounds: the event-driven ones come from the presenter's own events for you, and the
    /// sequence's ticks and the gun are the clock's, not the events'.
    @Test func raceCuesChooseTheirSounds() {
        let expected: [RaceCue: SoundCue] = [.ocs: .ocsHorn, .callAgainstMe: .whistle, .callForMe: .whistle,
                                             .rounding: .bell, .finish: .finishHorn]
        for cue in RaceCue.allCases { #expect(SoundCue(cue) == expected[cue], "\(cue)") }

        let me = Self.me
        let events: [SoundCue: RaceEvent] = [
            .ocsHorn: Self.event(.ocsNotice(recipient: me)), .bell: Self.event(.rounded(seat: me, mark: "windward mark")),
            .finishHorn: Self.event(.finished(seat: me, place: 1)), .whistle: Self.call(offender: me, victim: 1, incident: 1),
        ]
        for (sound, event) in events {
            var presenter = RaceEventPresenter(me: me)
            #expect(presenter.present([event]).cues.compactMap(SoundCue.init) == [sound], "\(sound)")
        }
        // A call between other boats, and a mark touch (rule 31), are silent.
        var presenter = RaceEventPresenter(me: me)
        #expect(presenter.present([Self.call(offender: 1, victim: 2, incident: 2)]).cues.compactMap(SoundCue.init).isEmpty)
        #expect(presenter.present([Self.event(.markTouch(seat: me, mark: "pin"))]).cues.compactMap(SoundCue.init).isEmpty)
    }

    /// Two calls on you in one tick blow one whistle; the next batch's call blows another.
    @Test func oneWhistlePerBatch() {
        let recorder = RecordingSound()
        var sound = RaceSound(output: recorder)
        sound.play(cues: [.callAgainstMe, .contact, .callForMe], raceTime: 100)
        #expect(recorder.played == [.whistle])
        sound.play(cues: [.callForMe], raceTime: 100.1)
        #expect(recorder.played == [.whistle, .whistle])
    }
}

/// The audio session (#126, #22): ambient, so the silent switch silences the game.
@MainActor @Suite struct SoundSessionTests {
    @Test func sessionCategoryIsAmbient() {
        SoundSession.configure()
        #expect(AVAudioSession.sharedInstance().category == .ambient)
        #expect(SoundSession.category == .ambient)
    }

    /// Tests, UI tests and render fixtures never touch the audio engine.
    @Test func onlyTheRealAppPlays() {
        let app = LaunchOptions(arguments: ["/path/to/Regatta"])
        #expect(AppAudio.isLive(app, environment: [:]))
        #expect(!AppAudio.isLive(app, environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(!AppAudio.isLive(LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting"]), environment: [:]))
        #expect(!AppAudio.isLive(LaunchOptions(arguments: ["/path/to/Regatta", "-fixture", "prestart"]), environment: [:]))
    }
}

/// Settings' Effects and Music (#110, #126): one gate each, like Haptics.
@MainActor @Suite struct GatedSoundTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    @Test func effectsOffMakesNoOutputCalls() {
        let recorder = RecordingSound()
        let sound = GatedSound(output: recorder, isOn: false)
        sound.play(.gun)
        sound.setAmbience(AmbienceMix.gains(for: .init(windKnots: 10, boatKnots: 4, isEasing: false)))
        #expect(recorder.played.isEmpty && recorder.ambience.isEmpty)
        // On takes effect at once.
        sound.isOn = true
        sound.play(.bell)
        #expect(recorder.played == [.bell])
        // Off mid-race silences the ambience at once.
        sound.isOn = false
        #expect(recorder.ambience.last == .silent)

        // A race's sounds all go through the gate.
        let silent = RecordingSound()
        let ocs = RaceEvent(tick: 0, kind: .ocsNotice(recipient: 0))
        GameSession(config: Self.config, sound: GatedSound(output: silent, isOn: false)).consume([ocs])
        #expect(silent.played.isEmpty)
        let heard = RecordingSound()
        let session = GameSession(config: Self.config, sound: GatedSound(output: heard, isOn: true))
        session.consume([RaceEvent(tick: 0, kind: .ocsNotice(recipient: session.driver.myBoatIndex))])
        #expect(heard.played.contains(.ocsHorn))
    }

    @Test func musicFollowsItsGate() {
        let recorder = RecordingMusic()
        let music = GatedMenuMusic(output: recorder, isOn: true)
        music.play()
        music.play()
        #expect(recorder.calls == ["in"])
        music.isOn = false
        #expect(recorder.calls == ["in", "out"], "Music off fades it")
        music.fadeOut()
        music.play()
        #expect(recorder.calls == ["in", "out"], "and keeps it off")
        music.isOn = true
        #expect(recorder.calls == ["in", "out", "in"], "back on in the menus")
        music.fadeOut()
        music.fadeOut()
        #expect(recorder.calls == ["in", "out", "in", "out"])
    }

    /// The model's gates follow its settings: as stored at launch, then once per change.
    @Test func theModelsGatesFollowItsSettings() throws {
        let name = "GatedSoundTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var stored = DeviceSettings()
        stored.effects = false
        stored.music = false
        stored.save(to: defaults)

        let music = RecordingMusic()
        let model = AppModel(sceneState: SceneState(), defaults: defaults,
                             audio: AppAudio(effects: RecordingSound(), music: music))
        #expect(!model.sound.isOn && !model.music.isOn)
        #expect(music.calls.isEmpty, "no music at launch with Music off")
        model.deviceSettings.effects = true
        model.deviceSettings.music = true
        #expect(model.sound.isOn && model.music.isOn)
        #expect(music.calls == ["in"])
        model.deviceSettings.effects = false
        #expect(!model.sound.isOn)
    }
}

/// The race's ambience (#22): wind by its strength, water by your speed, the sail flogging as you ease.
@MainActor @Suite struct AmbienceMixTests {
    private static func gains(wind: Double, speed: Double = 0, easing: Bool = false) -> AmbienceGains {
        AmbienceMix.gains(for: AmbienceInput(windKnots: wind, boatKnots: speed, isEasing: easing))
    }

    /// The wind layers' summed level at `knots`.
    private static func windLevel(_ knots: Double) -> Double {
        AmbienceMix.windLevel.calm
            + (AmbienceMix.windLevel.strong - AmbienceMix.windLevel.calm) * min(1, knots / AmbienceMix.windStrongKnots)
    }

    /// The crossfades are monotonic and constant-power: light gives way to medium, medium to strong, slow water to
    /// fast (each layer's share of its level), the levels only rise, and each pair's power sums to its level.
    @Test func crossfadesAreMonotonic() {
        var previous = Self.gains(wind: 0, speed: 0)
        var previousLevel = Self.windLevel(0)
        for step in 1...60 {
            let x = Double(step) * 0.5
            let mix = Self.gains(wind: x, speed: x / 3)
            let level = Self.windLevel(x)
            #expect(level >= previousLevel)
            #expect(mix[.windLight] / level <= previous[.windLight] / previousLevel + 1e-9, "\(x)")
            if x <= AmbienceMix.windMediumKnots {
                #expect(mix[.windMedium] / level >= previous[.windMedium] / previousLevel - 1e-9, "\(x)")
            } else {
                #expect(mix[.windMedium] / level <= previous[.windMedium] / previousLevel + 1e-9, "\(x)")
            }
            #expect(mix[.windStrong] >= previous[.windStrong] - 1e-9, "\(x)")
            #expect(mix[.waterFast] >= previous[.waterFast] - 1e-9, "\(x)")
            let wind = [AmbienceLayer.windLight, .windMedium, .windStrong].reduce(0) { $0 + mix[$1] * mix[$1] }
            #expect(abs(wind.squareRoot() - level) < 1e-9, "constant power at \(x)")
            previous = mix
            previousLevel = level
        }
        #expect(Self.gains(wind: 4)[.windLight] > 0 && Self.gains(wind: 4)[.windStrong] == 0)
        #expect(Self.gains(wind: 25)[.windStrong] > 0 && Self.gains(wind: 25)[.windLight] == 0)
        #expect(Self.gains(wind: 10, speed: 0)[.waterSlow] < Self.gains(wind: 10, speed: 2)[.waterSlow])
        #expect(Self.gains(wind: 10)[.sailFlog] == 0)
        #expect(Self.gains(wind: 10, easing: true)[.sailFlog] == AmbienceMix.flogGain)
    }

    /// The gains ramp, never jump: full scale over `rampSeconds`, down to silence as you finish.
    @Test func gainsRampAndFadeAfterTheFinish() {
        let recorder = RecordingSound()
        var sound = RaceSound(output: recorder)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let input = AmbienceInput(windKnots: 14, boatKnots: 5, isEasing: true)
        sound.stepAmbience(input, at: t0)
        #expect(sound.ambience.isSilent, "the first step starts the ramp")
        sound.stepAmbience(input, at: t0.addingTimeInterval(0.05))
        #expect(abs(sound.ambience[.sailFlog] - 0.05 / AmbienceMix.rampSeconds) < 1e-9)
        for i in 2...20 { sound.stepAmbience(input, at: t0.addingTimeInterval(Double(i) * 0.05)) }
        #expect(sound.ambience == AmbienceMix.gains(for: input))
        // A long stall still ramps.
        sound.stepAmbience(nil, at: t0.addingTimeInterval(10))
        #expect(!sound.ambience.isSilent)
        for i in 1...10 { sound.stepAmbience(nil, at: t0.addingTimeInterval(10 + Double(i) * 0.05)) }
        #expect(sound.ambience.isSilent && recorder.ambience.last?.isSilent == true)
    }

    /// A paused race is silent at once; its ambience ramps back in after.
    @Test func pauseSilencesTheAmbience() {
        let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        let recorder = RecordingSound()
        let session = GameSession(config: config, sound: recorder)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        session.now = { clock }
        for _ in 0..<10 {
            clock += 0.1
            session.refreshHUD()
        }
        #expect(recorder.ambience.last.map { !$0.isSilent } == true, "wind at the start")
        session.setPaused(true)
        #expect(recorder.ambience.last == .silent)
    }
}
