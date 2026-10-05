import Foundation

/// What plays the race's sounds (#126): the device's audio engine (`SystemSoundOutput`), nothing
/// (`SilentSoundOutput`, tests, UI tests and render fixtures) or a recorder in tests.
protocol SoundOutput: AnyObject {
    /// Plays `cue` once.
    func play(_ cue: SoundCue)
    /// Sets each ambience layer's gain at once: the caller ramps them (`RaceSound`). `.silent` stops them.
    func setAmbience(_ gains: AmbienceGains)
}

/// No sound.
final class SilentSoundOutput: SoundOutput {
    func play(_ cue: SoundCue) {}
    func setAmbience(_ gains: AmbienceGains) {}
}

/// Sounds gated by Settings' Effects (#110), like `GatedHaptics`, and by the scene: `isOn` follows the setting and
/// `isSceneActive` the scene's phase, each set once per change by `AppModel`. Switching Effects off or leaving the
/// scene active silences the ambience at once, mid-race (online races too); with Effects off nothing reaches the
/// output, so the audio engine never starts. Back on, the ambience last asked for plays again at once.
final class GatedSound: SoundOutput {
    private let output: any SoundOutput
    var isOn: Bool {
        didSet { gateChanged(wasOpen: oldValue && isSceneActive) }
    }
    /// The scene is active (`SceneState.phase == .active`): the ambience is silent while it isn't.
    var isSceneActive = true {
        didSet { gateChanged(wasOpen: isOn && oldValue) }
    }
    /// The ambience last asked for, whether or not it reached the output.
    private var wanted = AmbienceGains.silent
    /// The ambience the output last heard is audible: only then does closing the gate send it a silence.
    private var outputAudible = false

    init(output: any SoundOutput = SilentSoundOutput(), isOn: Bool = true) {
        self.output = output
        self.isOn = isOn
    }

    private var ambienceOpen: Bool { isOn && isSceneActive }

    func play(_ cue: SoundCue) {
        guard isOn else { return }
        output.play(cue)
    }

    func setAmbience(_ gains: AmbienceGains) {
        wanted = gains
        guard ambienceOpen else { return }
        send(gains)
    }

    private func gateChanged(wasOpen: Bool) {
        if wasOpen && !ambienceOpen {
            send(.silent)
        } else if !wasOpen && ambienceOpen && !wanted.isSilent {
            send(wanted)
        }
    }

    private func send(_ gains: AmbienceGains) {
        // A silence the output already has is never sent: with Effects off from launch it's never touched.
        guard !(gains.isSilent && !outputAudible) else { return }
        outputAudible = !gains.isSilent
        output.setAmbience(gains)
    }
}

/// One race's sounds (#126), owned by its `GameSession`: the committee's sequence on the race clock, your boat's
/// moments from the presenter's cues, and the ambience ramped towards its mix.
struct RaceSound {
    let output: any SoundOutput
    private var schedule = SoundSchedule()
    /// The ambience gains the ramp has reached.
    private(set) var ambience = AmbienceGains.silent
    /// The gains last sent to the output: a step sends only when a layer has moved more than `sendEpsilon` from them.
    private var sent = AmbienceGains.silent
    /// The smallest gain change worth sending (about −46 dB of full scale).
    static let sendEpsilon = 0.005
    /// The wall-clock time of the last ambience step, nil after a silence (the next step starts the ramp afresh).
    private var lastStep: Date?
    /// The longest step a ramp takes at once: after a stall the ambience still ramps in rather than jumping.
    static let maxStepSeconds = 0.1

    init(output: any SoundOutput) {
        self.output = output
    }

    /// One batch of the race at race time `raceTime`: the schedule's marks reached since the last batch, then the
    /// sounds of `cues`, each sound once a batch (two calls on you in one tick blow one whistle).
    /// Returns what it played.
    @discardableResult mutating func play(cues: [RaceCue], raceTime: Double) -> [SoundCue] {
        var sounds: [SoundCue] = []
        for sound in schedule.cues(at: raceTime) + cues.compactMap(SoundCue.init) where !sounds.contains(sound) {
            sounds.append(sound)
        }
        for sound in sounds { output.play(sound) }
        return sounds
    }

    /// Steps the ambience towards `input`'s mix at wall-clock `now`, or towards silence when `input` is nil (you're
    /// done: it fades after your finish horn).
    mutating func stepAmbience(_ input: AmbienceInput?, at now: Date) {
        let seconds = lastStep.map { min(max(0, now.timeIntervalSince($0)), Self.maxStepSeconds) } ?? 0
        lastStep = now
        let target = input.map(AmbienceMix.gains(for:)) ?? .silent
        ambience = AmbienceMix.ramp(ambience, toward: target, over: seconds)
        // Sent only on a change beyond `sendEpsilon` (the output may lag the ramp by less), and silence exactly once.
        // `GatedSound` replays the last gains when Effects or the scene comes back.
        let reachedSilence = ambience.isSilent && !sent.isSilent
        guard reachedSilence || ambience.differs(from: sent, by: Self.sendEpsilon) else { return }
        sent = ambience
        output.setAmbience(ambience)
    }

    /// Silences the ambience at once: the race paused, or left.
    mutating func silence() {
        lastStep = nil
        ambience = .silent
        sent = .silent
        output.setAmbience(.silent)
    }
}
