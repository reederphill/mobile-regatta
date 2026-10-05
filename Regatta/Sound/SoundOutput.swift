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

/// Sounds gated by Settings' Effects (#110), like `GatedHaptics`: `isOn` follows the setting, set once per change by
/// `AppModel`. Switching Effects off silences the ambience at once, mid-race, and plays nothing until it's back on.
final class GatedSound: SoundOutput {
    private let output: any SoundOutput
    var isOn: Bool {
        didSet {
            if oldValue && !isOn { output.setAmbience(.silent) }
        }
    }

    init(output: any SoundOutput = SilentSoundOutput(), isOn: Bool = true) {
        self.output = output
        self.isOn = isOn
    }

    func play(_ cue: SoundCue) {
        guard isOn else { return }
        output.play(cue)
    }

    func setAmbience(_ gains: AmbienceGains) {
        guard isOn else { return }
        output.setAmbience(gains)
    }
}

/// One race's sounds (#126), owned by its `GameSession`: the committee's sequence on the race clock, your boat's
/// moments from the presenter's cues, and the ambience ramped towards its mix.
struct RaceSound {
    let output: any SoundOutput
    private var schedule = SoundSchedule()
    /// The ambience gains last sent.
    private(set) var ambience = AmbienceGains.silent
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
        let next = AmbienceMix.ramp(ambience, toward: target, over: seconds)
        // Sent every step while audible, so Effects switched back on mid-race (`GatedSound`) hears it again at once.
        defer { ambience = next }
        guard !(next.isSilent && ambience.isSilent) else { return }
        output.setAmbience(next)
    }

    /// Silences the ambience at once: the race paused, or left.
    mutating func silence() {
        lastStep = nil
        ambience = .silent
        output.setAmbience(.silent)
    }
}
