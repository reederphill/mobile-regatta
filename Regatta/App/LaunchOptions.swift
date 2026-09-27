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
/// - `-vision deut|prot|trit|grey|sun|none` puts a colour-vision filter over a live race's whole view, scene, HUD
///   and letterbox alike (#111, Debug builds). `VisionFilter`'s own names (`deuteranopia`, …, `washout`) work too.
/// - `-tuning` opens the debug tuning panel at launch (#232). Debug builds only: other builds don't know it.
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
    var vision: VisionFilter?
    #if DEBUG
    var tuning = false
    #endif
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
            #if DEBUG
            case "-tuning": tuning = true
            #endif
            case "-seed", "-fixture", "-timescale", "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-appearance",
                 "-vision":
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

    private static let flags: Set<String> = {
        var flags: Set = ["-autostart", "-demo", "-perf", "-uitesting", "-online", "-seed", "-fixture", "-timescale",
                          "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-appearance", "-vision"]
        #if DEBUG
        flags.insert("-tuning")
        #endif
        return flags
    }()

    /// `-vision`'s short names (#111). Each filter's raw value is accepted as well.
    static let visionShortNames: [String: VisionFilter] = [
        "deut": .deuteranopia, "prot": .protanopia, "trit": .tritanopia, "grey": .greyscale, "sun": .washout,
    ]

    /// What `-vision` takes, for its rejection: the short names, then every filter's own.
    static let visionNames = "deut, prot, trit, grey, sun, none, deuteranopia, protanopia, tritanopia, "
        + "greyscale or washout"

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
        case "-vision":
            if let filter = Self.visionShortNames[value] ?? VisionFilter(rawValue: value) {
                vision = filter
            } else {
                reject(argument, value, Self.visionNames)
            }
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

    /// The colour-vision filter over a live race: `-vision`'s, in Debug builds only (#111). A render fixture
    /// names its own.
    var raceVision: VisionFilter {
        #if DEBUG
        vision ?? .none
        #else
        .none
        #endif
    }

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
