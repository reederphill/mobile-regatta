/// The menus' and lobby's music (#22, #126): it plays from launch and fades back in on returning home from a race;
/// the briefing fades it out as it starts (#130), and an online or practice race entered without one fades it too
/// (`AppModel.startRaceSequence`). Races have ambience only.
protocol MenuMusic: AnyObject {
    /// Starts or fades the music back in, if Settings' Music is on.
    func play()
    /// Fades the menu music out, if it's playing. Calling it again while it's fading or silent does nothing.
    func fadeOut()
}

extension MenuMusic {
    func play() {}
}

/// No menu music: tests' and render fixtures'.
final class SilentMenuMusic: MenuMusic {
    func fadeOut() {}
}

/// What plays the music: the device's player (`SystemMusicOutput`), nothing, or a recorder in tests. Told only when
/// it should start or stop.
protocol MusicOutput: AnyObject {
    func fadeIn()
    func fadeOut()
}

/// No music.
final class SilentMusicOutput: MusicOutput {
    func fadeIn() {}
    func fadeOut() {}
}

/// The app's menu music, gated by Settings' Music (#110): `isOn` follows the setting, set once per change by
/// `AppModel`. Off fades it out and keeps it off; back on in the menus fades it in again.
final class GatedMenuMusic: MenuMusic {
    private let output: any MusicOutput
    var isOn: Bool {
        didSet { apply() }
    }
    /// The app is in the menus or lobby: between `play()` and `fadeOut()`.
    private(set) var isWanted = false
    /// What the output was last told: playing or not.
    private(set) var isPlaying = false

    init(output: any MusicOutput = SilentMusicOutput(), isOn: Bool = true) {
        self.output = output
        self.isOn = isOn
    }

    func play() {
        isWanted = true
        apply()
    }

    func fadeOut() {
        isWanted = false
        apply()
    }

    private func apply() {
        let plays = isOn && isWanted
        guard plays != isPlaying else { return }
        isPlaying = plays
        if plays { output.fadeIn() } else { output.fadeOut() }
    }
}
