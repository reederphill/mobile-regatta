import Foundation
import RegattaCore

/// Development and test launch arguments, for `xcodebuild test`, UI tests and Instruments. Players never pass them.
///
/// - `-autostart` skips the menu and starts a race.
/// - `-demo` starts a race with a bot sailing your boat too.
/// - `-perf` starts a 16-boat demo race to profile against the signposts.
/// - `-seed <n>` sails every race on race seed `n` instead of a random one, with the wind seed pinned
///   to it by `RaceConfig.windSeed(pinnedTo:)`, so the whole race reproduces.
/// - `-fixture <name>` names a render fixture to replay (#62).
/// - `-timescale <n>` runs the simulation at `n`× real time.
/// - `-uitesting` marks a UI test run.
/// - `-scheme halves|tiller` overrides the device's steering scheme (#112).
/// - `-camera course|boat` overrides the device's camera (#113).
/// - `-online` starts an online race on the dev server's instant race at launch (#68, Debug builds).
/// - `-onlineHost <host:port>` is the dev race server, instead of the Settings page's field (Debug builds).
/// - `-raceSeconds <n>` closes an online dev race `n` seconds after the gun (the server's e2e override).
/// - `-startSeconds <n>` gives an online dev race an `n`-second start sequence, 1…60.
/// - `-appearance light|dark` overrides the system appearance, for UI tests of the menus in both (#108).
struct LaunchOptions: Equatable {
    enum SteeringScheme: String, CaseIterable {
        case halves, tiller
    }

    enum CameraMode: String, CaseIterable {
        case course, boat
    }

    enum Appearance: String, CaseIterable {
        case light, dark
    }

    /// Boats in the `-perf` race, the largest fleet.
    static let perfFleetSize = 16

    var autostart = false
    var demo = false
    var perf = false
    var uiTesting = false
    var seed: UInt64?
    var fixture: String?
    var timescale = 1.0
    var steeringScheme: SteeringScheme?
    var camera: CameraMode?
    var online = false
    var onlineHost: String?
    var raceSeconds: Int?
    var startSeconds: Int?
    var appearance: Appearance?
    /// Recognised arguments with a missing or bad value; each is ignored.
    var problems: [String] = []

    /// The options this process was launched with.
    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init() {}

    /// Parses `arguments`, including the executable path first, as `ProcessInfo.arguments` has it.
    /// Unknown arguments are skipped, since Xcode and the system pass their own.
    init(arguments: [String]) {
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "-autostart": autostart = true
            case "-demo": demo = true
            case "-perf": perf = true
            case "-uitesting": uiTesting = true
            case "-online": online = true
            case "-seed", "-fixture", "-timescale", "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-appearance":
                guard let value = rest.first, !Self.flags.contains(value) else {
                    problems.append("\(argument) needs a value")
                    continue
                }
                rest.removeFirst()
                apply(argument, value)
            default:
                continue
            }
        }
    }

    private static let flags: Set = ["-autostart", "-demo", "-perf", "-uitesting", "-online", "-seed", "-fixture", "-timescale",
                                     "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-appearance"]

    private mutating func apply(_ argument: String, _ value: String) {
        switch argument {
        case "-seed":
            if let n = UInt64(value) { seed = n } else { reject(argument, value, "a whole number ≥ 0") }
        case "-fixture":
            fixture = value
        case "-timescale":
            if let n = Double(value), n.isFinite, n > 0 { timescale = n } else { reject(argument, value, "a number > 0") }
        case "-scheme":
            if let scheme = SteeringScheme(rawValue: value) { steeringScheme = scheme } else { reject(argument, value, "halves or tiller") }
        case "-camera":
            if let mode = CameraMode(rawValue: value) { camera = mode } else { reject(argument, value, "course or boat") }
        case "-onlineHost":
            if !value.contains("/"), URL(string: "ws://\(value)/")?.host != nil { onlineHost = value } else { reject(argument, value, "host:port") }
        case "-raceSeconds":
            if let n = Int(value), (1...3600).contains(n) { raceSeconds = n } else { reject(argument, value, "a whole number of seconds, 1…3600") }
        case "-startSeconds":
            if let n = Int(value), (1...60).contains(n) { startSeconds = n } else { reject(argument, value, "a whole number of seconds, 1…60") }
        case "-appearance":
            if let style = Appearance(rawValue: value) { appearance = style } else { reject(argument, value, "light or dark") }
        default:
            break
        }
    }

    private mutating func reject(_ argument: String, _ value: String, _ expected: String) {
        problems.append("\(argument) \(value): expected \(expected)")
    }

    /// Whether the Debug FPS, node and draw-count overlay shows. UI tests and render fixtures hide it,
    /// so their screenshots are deterministic.
    var showsDebugStats: Bool { !uiTesting && fixture == nil }

    /// Whether launch skips the menu and starts a race.
    var startsRace: Bool { autostart || demo || perf }

    /// A race started from the menu or restarted: the player's settings, on the pinned seed if there is one.
    func raceConfig(from settings: RaceSettings) -> RaceConfig {
        var config = settings.config
        if let seed {
            config.seed = seed
            config.windSeed = RaceConfig.windSeed(pinnedTo: seed)
        }
        return config
    }

    /// The race started at launch, or nil to show the menu.
    func launchRaceConfig(from settings: RaceSettings) -> RaceConfig? {
        guard startsRace else { return nil }
        var config = raceConfig(from: settings)
        config.botSailsYourBoat = demo || perf
        if perf { config.opponents = Self.perfFleetSize - 1 }
        return config
    }
}
