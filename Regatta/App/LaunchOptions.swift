import Foundation
import RegattaCore
import RegattaServices

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
/// - `-resetSettings` (with `-uitesting`) clears the device's settings at launch, so a UI test that changes them starts
///   and ends on the defaults even if an earlier run stopped before switching them back (#131).
/// - `-scheme halves|tiller` overrides the device's steering scheme (#112).
/// - `-camera course|boat` overrides the device's camera as course-up or boat-up (#113).
/// - `-online` starts an online race on the dev server's instant race at launch (#68, Debug builds).
/// - `-onlineHost <host:port>` is the dev race server, instead of the Settings page's field (Debug builds).
/// - `-raceSeconds <n>` closes an online dev race `n` seconds after the gun (the server's e2e override).
/// - `-startSeconds <n>` gives an online dev race's, and every practice race's, start sequence `n` seconds, 1…60
///   (#361: a UI test that waits for the results spends less of its watch before the gun).
/// - `-laps <n>` sails every practice race `n` laps, 1…9, instead of the setup's (#354: a UI test that waits for the
///   results sails a short race, so a slow simulator still reaches them).
/// - `-hideScene` draws none of a live race's world (#361): the scene still moves every node, and the HUD and results
///   show, but SpriteKit rasterises nothing, so a UI test waiting for the results doesn't hang on the runner's GPU.
/// - `-appearance light|dark` overrides the system appearance, for UI tests of the menus in both (#108).
/// - `-vision deut|prot|trit|grey|sun|none` puts a colour-vision filter over a live race's whole view, scene, HUD
///   and letterbox alike (#111, Debug builds). `VisionFilter`'s own names (`deuteranopia`, …, `washout`) work too.
/// - `-tuning` opens the debug tuning panel at launch (#232). Debug builds only: other builds don't know it.
/// - `-briefing practice|online` opens on the briefing (#130) for the launch race (`RaceConfig.launch()`, and `-seed`), with
///   no server: `practice` waits for Ready, `online` counts down 15 s (at `-timescale`) and advances itself.
/// - `-fakeServices <scenario>` runs the online services on a scenario's scripted fakes, for UI tests (#242):
///   `signed-out`, `underage`, `communication-restricted`, `multiplayer-restricted`, `offline`, `queued` or
///   `cancelled-race` (`FakeServiceScenario`).
/// - `-myBoat <design-id>` opens My boat with that design tried on (#136): the stand-in for results' Try it deep link.
/// - `-keepMyBoat` (with `-uitesting`) keeps My boat's livery, owned designs and races from the last launch, which UI
///   tests otherwise empty at launch: a relaunch that checks what was saved.
/// - `-completedRaces <n>` (with `-uitesting`) sets the online races you've completed, which earned designs count (#136).
///   Kept in the UI tests' own suite; without `-uitesting` it's ignored, so it never unlocks a design for real.
struct LaunchOptions: Equatable {
    enum SteeringScheme: String, CaseIterable {
        case halves, tiller
    }

    /// `-camera`: `course` is course-up and `boat` boat-up (#113). A render fixture's `camera` (#62) takes the same
    /// names for the north-up cameras it was drawn with before #113: the whole course, and following your boat.
    enum CameraMode: String, CaseIterable {
        case course, boat
    }

    enum Appearance: String, CaseIterable {
        case light, dark
    }

    /// `-briefing`'s variants (#130).
    enum Briefing: String, CaseIterable {
        case practice, online
    }

    /// Boats in the `-perf` race, the largest fleet.
    static let perfFleetSize = 16

    var autostart = false
    var demo = false
    var perf = false
    var uiTesting = false
    /// `-resetSettings`: honoured only with `-uitesting`.
    var resetSettings = false
    var seed: UInt64?
    var fixture: String?
    var timescale = 1.0
    var steeringScheme: SteeringScheme?
    var camera: CameraMode?
    var online = false
    var onlineHost: String?
    var raceSeconds: Int?
    var startSeconds: Int?
    var laps: Int?
    var hidesScene = false
    var appearance: Appearance?
    var vision: VisionFilter?
    var fakeServices: FakeServiceScenario?
    var briefing: Briefing?
    /// `-myBoat`: a design in the bundled catalogue for the practice boat class.
    var myBoat: DesignID?
    var keepMyBoat = false
    var completedRaces: Int?
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
            case "-resetSettings": resetSettings = true
            case "-online": online = true
            case "-keepMyBoat": keepMyBoat = true
            case "-hideScene": hidesScene = true
            #if DEBUG
            case "-tuning": tuning = true
            #endif
            case "-seed", "-fixture", "-timescale", "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-laps",
                 "-appearance", "-vision", "-fakeServices", "-briefing", "-myBoat", "-completedRaces":
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
        var flags: Set = ["-autostart", "-demo", "-perf", "-uitesting", "-resetSettings", "-online", "-hideScene", "-seed",
                          "-fixture", "-timescale", "-scheme", "-camera", "-onlineHost", "-raceSeconds", "-startSeconds", "-laps",
                          "-appearance", "-vision", "-fakeServices", "-briefing", "-myBoat", "-keepMyBoat", "-completedRaces"]
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
        case "-laps":
            if let n = Int(value), (1...9).contains(n) { laps = n } else { reject(argument, value, "a whole number of laps, 1…9") }
        case "-appearance":
            if let style = Appearance(rawValue: value) { appearance = style } else { reject(argument, value, "light or dark") }
        case "-vision":
            if let filter = Self.visionShortNames[value] ?? VisionFilter(rawValue: value) {
                vision = filter
            } else {
                reject(argument, value, Self.visionNames)
            }
        case "-briefing":
            if let variant = Briefing(rawValue: value) { briefing = variant } else { reject(argument, value, "practice or online") }
        case "-myBoat":
            let id = DesignID(value)
            if LiveryCatalogue.bundled.design(id)?.boatClass == RaceFiles.defaults.boatClass.ref.id {
                myBoat = id
            } else {
                reject(argument, value, "a design id of the practice boat class")
            }
        case "-completedRaces":
            if let n = Int(value), n >= 0 { completedRaces = n } else { reject(argument, value, "a whole number ≥ 0") }
        case "-fakeServices":
            if let scenario = FakeServiceScenario(rawValue: value) {
                fakeServices = scenario
            } else {
                reject(argument, value, FakeServiceScenario.allCases.map(\.rawValue).joined(separator: ", "))
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

    /// A race's seeds: fresh ones, drawn independently (ADR 0001: online races get the race seed from the server, which
    /// keeps the wind seed to itself), or `-seed`'s with the wind seed pinned to it.
    func seeds() -> (seed: UInt64, windSeed: UInt64) {
        if let seed { return (seed, RaceConfig.windSeed(pinnedTo: seed)) }
        return (.random(in: .min ... .max), .random(in: .min ... .max))
    }

    /// A practice race on `setup` (Start, Sail again): on fresh seeds or the pinned one, and `-laps`' laps and
    /// `-startSeconds`' start sequence if given, with rivals at `rivalSkill` if given (#235).
    func raceConfig(from setup: PracticeSetup, rivalSkill: Double? = nil) -> RaceConfig {
        let (seed, windSeed) = seeds()
        return raceConfig(from: setup.config(seed: seed, windSeed: windSeed, rivalSkill: rivalSkill))
    }

    /// `config` on the pinned seed if there is one, and `-laps`' laps and `-startSeconds`' start sequence if given.
    func raceConfig(from config: RaceConfig) -> RaceConfig {
        var config = config
        if let laps { config.laps = laps }
        if let startSeconds { config.prestartSeconds = Double(startSeconds) }
        if let seed {
            config.seed = seed
            config.windSeed = RaceConfig.windSeed(pinnedTo: seed)
        }
        return config
    }

    /// The race started at launch, or nil to show the menu: `config`, the launch race (`RaceConfig.launch()`) unless a
    /// test gives another.
    func launchRaceConfig(from config: RaceConfig = .launch()) -> RaceConfig? {
        guard startsRace else { return nil }
        var config = raceConfig(from: config)
        config.botSailsYourBoat = demo || perf
        if perf { config.opponents = Self.perfFleetSize - 1 }
        return config
    }
}
