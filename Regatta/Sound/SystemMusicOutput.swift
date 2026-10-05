import AVFoundation

/// The menu music on the device (#126): an `AVAudioPlayer` looping the music's file (#54's is a 3 min AAC, streamed,
/// not decoded to a buffer), faded in and out. It stays silent while another app's audio plays
/// (`secondaryAudioShouldBeSilencedHint`) and fades in once that stops, if it's still wanted.
final class SystemMusicOutput: MusicOutput {
    private let player = MusicPlayer()

    func fadeIn() { player.setWanted(true) }
    func fadeOut() { player.setWanted(false) }
}

/// The player behind `SystemMusicOutput`, confined to its queue.
nonisolated final class MusicPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.phillreeder.regatta.music", qos: .utility)
    private let library: SoundLibrary
    private var player: AVAudioPlayer?
    private var isWanted = false
    private var observer: NSObjectProtocol?
    /// Bumped on every change, so a pause scheduled after a fade-out is called off by a fade-in.
    private var generation = 0
    static let volume: Float = 0.5
    static let fadeSeconds: TimeInterval = 1.5

    init(library: SoundLibrary = SoundLibrary()) {
        self.library = library
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.apply() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setWanted(_ wanted: Bool) {
        queue.async { [self] in
            isWanted = wanted
            apply()
        }
    }

    private func apply() {
        generation += 1
        let plays = isWanted && !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        if plays {
            guard let player = loadedPlayer() else { return }
            if !player.isPlaying {
                player.volume = 0
                player.play()
            }
            player.setVolume(Self.volume, fadeDuration: Self.fadeSeconds)
        } else if let player, player.isPlaying {
            player.setVolume(0, fadeDuration: Self.fadeSeconds)
            let scheduled = generation
            queue.asyncAfter(deadline: .now() + Self.fadeSeconds) { [self] in
                guard generation == scheduled else { return }
                self.player?.pause()
            }
        }
    }

    private func loadedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard let url = library.musicURL() else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            self.player = player
            return player
        } catch {
            SoundSession.log.error("Menu music: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
