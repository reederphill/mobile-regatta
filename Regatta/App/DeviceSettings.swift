import Foundation

/// The settings kept on this device (#110, #25): in `UserDefaults`, never synced. Settings is one page; every value
/// here is a row on it. The steering scheme and camera are per device (#13). Haptics and Hide lobby chat act now; the
/// steering, camera, framing, layline and ladder values are read by the tickets that draw them (#112, #113, #122, #268),
/// which also apply the `-scheme` / `-camera` test overrides on top of them.
nonisolated struct DeviceSettings: Equatable, Sendable {
    enum Steering: String, CaseIterable, Sendable {
        /// Hold the left or right half of the screen to steer (the default).
        case halves
        case tiller
    }

    enum Camera: String, CaseIterable, Sendable {
        /// The course's axis up (the default).
        case courseUp
        case boatUp
    }

    var steering = Steering.halves
    var camera = Camera.courseUp
    /// The camera frames the boats that matter (#113, #224).
    var autoFraming = true
    var laylines = true
    var ladderLines = false
    /// The live leaderboard on the race HUD (#268).
    var liveLeaderboard = true
    var hints = true
    var music = true
    var effects = true
    var haptics = true
    var hidesLobbyChat = false
    /// Share usage data (#28): off, the device sends no analytics events.
    var sharesUsageData = true

    /// The defaults: what a new install starts with.
    init() {}

    /// The settings stored in `defaults`, each missing or unreadable one at its default.
    init(defaults: UserDefaults) {
        func flag(_ key: Key, _ fallback: Bool) -> Bool { defaults.object(forKey: key.rawValue) as? Bool ?? fallback }
        steering = defaults.string(forKey: Key.steering.rawValue).flatMap(Steering.init) ?? steering
        camera = defaults.string(forKey: Key.camera.rawValue).flatMap(Camera.init) ?? camera
        autoFraming = flag(.autoFraming, autoFraming)
        laylines = flag(.laylines, laylines)
        ladderLines = flag(.ladderLines, ladderLines)
        liveLeaderboard = flag(.liveLeaderboard, liveLeaderboard)
        hints = flag(.hints, hints)
        music = flag(.music, music)
        effects = flag(.effects, effects)
        haptics = flag(.haptics, haptics)
        hidesLobbyChat = flag(.hidesLobbyChat, hidesLobbyChat)
        sharesUsageData = flag(.sharesUsageData, sharesUsageData)
    }

    /// Writes every value to `defaults`.
    func save(to defaults: UserDefaults) {
        defaults.set(steering.rawValue, forKey: Key.steering.rawValue)
        defaults.set(camera.rawValue, forKey: Key.camera.rawValue)
        defaults.set(autoFraming, forKey: Key.autoFraming.rawValue)
        defaults.set(laylines, forKey: Key.laylines.rawValue)
        defaults.set(ladderLines, forKey: Key.ladderLines.rawValue)
        defaults.set(liveLeaderboard, forKey: Key.liveLeaderboard.rawValue)
        defaults.set(hints, forKey: Key.hints.rawValue)
        defaults.set(music, forKey: Key.music.rawValue)
        defaults.set(effects, forKey: Key.effects.rawValue)
        defaults.set(haptics, forKey: Key.haptics.rawValue)
        defaults.set(hidesLobbyChat, forKey: Key.hidesLobbyChat.rawValue)
        defaults.set(sharesUsageData, forKey: Key.sharesUsageData.rawValue)
    }

    /// Where each value lives in `UserDefaults`.
    enum Key: String, CaseIterable {
        case steering = "settings.steering"
        case camera = "settings.camera"
        case autoFraming = "settings.autoFraming"
        case laylines = "settings.laylines"
        case ladderLines = "settings.ladderLines"
        case liveLeaderboard = "settings.liveLeaderboard"
        case hints = "settings.hints"
        case music = "settings.music"
        case effects = "settings.effects"
        case haptics = "settings.haptics"
        case hidesLobbyChat = "settings.hidesLobbyChat"
        case sharesUsageData = "settings.sharesUsageData"
    }

    /// The prefix of every key the hints keep their progress under: Reset hints clears them all, so each hint shows
    /// again (#25).
    static let hintKeyPrefix = "hints."

    /// Reset hints: forgets every hint's progress in `defaults`.
    static func resetHints(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(hintKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Settings → About's links (#25, #28, #34). Placeholders until the published pages and the support address exist.
nonisolated enum AboutLinks {
    static let supportEmail = "support@regatta.example"
    static let support = URL(string: "mailto:\(supportEmail)")!
    static let privacyPolicy = URL(string: "https://regatta.example/privacy")!
    static let terms = URL(string: "https://regatta.example/terms")!
}
