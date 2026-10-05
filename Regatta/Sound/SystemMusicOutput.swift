import AVFoundation
import UIKit

/// The menu music on the device (#126): an `AVAudioPlayer` looping the music's file (#54's is a 3 min AAC, streamed,
/// not decoded to a buffer), faded in and out. It stays silent while another app's audio plays
/// (`secondaryAudioShouldBeSilencedHint`) and fades in once that stops, if it's still wanted. It plays again after an
/// interruption (a call, Siri, an alarm) ends and on returning to the foreground. Nothing is made until the music is
/// first wanted: no queue or observers before, and no `AVAudioPlayer` until it should sound.
final class SystemMusicOutput: MusicOutput {
    private var player: MusicPlayer?

    func fadeIn() {
        let player = player ?? MusicPlayer(foreground: UIApplication.didBecomeActiveNotification)
        self.player = player
        player.setWanted(true)
    }

    func fadeOut() { player?.setWanted(false) }
}

/// What `MusicPlayback` drives: an `AVAudioPlayer` on the device, a fake in tests.
nonisolated protocol MenuMusicTrack: AnyObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    @discardableResult func play() -> Bool
    func pause()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}

nonisolated extension AVAudioPlayer: MenuMusicTrack {}

/// The music's state and decisions, with no threads or notifications of its own: `MusicPlayer` confines it to its
/// queue and feeds it the system's events; tests drive it directly.
nonisolated final class MusicPlayback: @unchecked Sendable {
    private let load: () -> (any MenuMusicTrack)?
    private let isSilencedByOtherAudio: () -> Bool
    private let activateSession: () -> Void
    /// Runs the closure after the delay, on the queue the playback is confined to.
    private let after: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var track: (any MenuMusicTrack)?
    /// The track couldn't load: the music stays silent rather than retrying on every change.
    private var loadFailed = false
    /// The menus want music: between `setWanted(true)` and `setWanted(false)`.
    private(set) var isWanted = false
    /// Bumped on every change, so a pause scheduled after a fade-out is called off by a fade-in.
    private var generation = 0
    static let volume: Float = 0.5
    static let fadeSeconds: TimeInterval = 1.5

    init(load: @escaping () -> (any MenuMusicTrack)?, isSilencedByOtherAudio: @escaping () -> Bool,
         activateSession: @escaping () -> Void,
         after: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void) {
        self.load = load
        self.isSilencedByOtherAudio = isSilencedByOtherAudio
        self.activateSession = activateSession
        self.after = after
    }

    func setWanted(_ wanted: Bool) {
        isWanted = wanted
        apply()
    }

    /// An interruption ended: the system paused the player and deactivated the session. Reactivate it and play on,
    /// if the music is still wanted.
    func interruptionEnded() {
        if isWanted { activateSession() }
        apply()
    }

    /// The app is back in the foreground, or other apps' audio started or stopped: a player the system stopped
    /// meanwhile plays again if it's wanted.
    func refresh() { apply() }

    private func apply() {
        generation += 1
        if isWanted && !isSilencedByOtherAudio() {
            guard let track = loadedTrack() else { return }
            if !track.isPlaying {
                track.volume = 0
                track.play()
            }
            track.setVolume(Self.volume, fadeDuration: Self.fadeSeconds)
        } else if let track, track.isPlaying {
            track.setVolume(0, fadeDuration: Self.fadeSeconds)
            let scheduled = generation
            after(Self.fadeSeconds) { [self] in
                guard generation == scheduled else { return }
                self.track?.pause()
            }
        }
    }

    private func loadedTrack() -> (any MenuMusicTrack)? {
        if let track { return track }
        guard !loadFailed else { return nil }
        track = load()
        loadFailed = track == nil
        return track
    }
}

/// The player behind `SystemMusicOutput`: `MusicPlayback` on its own queue, told of other apps' audio, interruptions
/// and the app's return to the foreground (`foreground`, the app's became-active notification).
nonisolated final class MusicPlayer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let playback: MusicPlayback
    private var observers: [NSObjectProtocol] = []

    init(library: SoundLibrary = SoundLibrary(), foreground: Notification.Name) {
        let queue = DispatchQueue(label: "com.phillreeder.regatta.music", qos: .utility)
        let playback = MusicPlayback(
            load: { Self.loadPlayer(library) },
            isSilencedByOtherAudio: { AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint },
            activateSession: {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    SoundSession.log.error("Menu music session: \(String(describing: error), privacy: .public)")
                }
            },
            after: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) })
        self.queue = queue
        self.playback = playback
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil,
                                            queue: nil) { _ in queue.async { playback.refresh() } })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { note in
            guard SoundSession.interruptionEnded(note) else { return }
            queue.async { playback.interruptionEnded() }
        })
        observers.append(center.addObserver(forName: foreground, object: nil, queue: nil) { _ in
            queue.async { playback.refresh() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setWanted(_ wanted: Bool) {
        queue.async { [playback] in playback.setWanted(wanted) }
    }

    /// The music's player, or nil (logged here once: `MusicPlayback` doesn't ask again).
    private static func loadPlayer(_ library: SoundLibrary) -> (any MenuMusicTrack)? {
        guard let url = library.musicURL() else {
            SoundSession.log.error("Menu music: no file, so the menus stay silent")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            return player
        } catch {
            SoundSession.log.error("Menu music: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
