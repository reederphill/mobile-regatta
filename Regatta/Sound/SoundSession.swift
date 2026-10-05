import AVFoundation
import os

/// The app's audio session (#22): `.ambient`, so the silent switch silences every sound, and other apps' audio
/// mixes with the game's rather than stopping. Configured once at launch (`AppDelegate`). Any failure is logged and
/// the game runs silent.
nonisolated enum SoundSession {
    static let category: AVAudioSession.Category = .ambient

    static let log = Logger(subsystem: "com.phillreeder.regatta", category: "sound")

    static func configure(_ session: AVAudioSession = .sharedInstance()) {
        do {
            try session.setCategory(category, mode: .default)
            try session.setActive(true)
        } catch {
            log.error("Audio session: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The app's sounds: live on a device or simulator, silent in tests, UI tests and render fixtures, which never touch
/// the audio engine.
struct AppAudio {
    let effects: any SoundOutput
    let music: any MusicOutput

    static var silent: AppAudio { AppAudio(effects: SilentSoundOutput(), music: SilentMusicOutput()) }

    /// Whether `options` and the process play sound: not under XCTest (unit tests run in the app as host), UI tests
    /// or a render fixture.
    static func isLive(_ options: LaunchOptions,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !options.uiTesting && options.fixture == nil && environment["XCTestConfigurationFilePath"] == nil
    }

    static func live(for options: LaunchOptions = .current) -> AppAudio {
        guard isLive(options) else { return .silent }
        return AppAudio(effects: SystemSoundOutput(), music: SystemMusicOutput())
    }
}
