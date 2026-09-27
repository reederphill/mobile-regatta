import Foundation
import RegattaBots
import RegattaCore

/// The bot glyph (#19): every bot is marked with it wherever its name shows. A placeholder until
/// the art direction's glyph lands.
enum BotGlyph {
    static let text = "\u{2699}\u{FE0E}"
    static let symbolName = "gearshape.fill"
}

extension FleetRoster {
    /// Your boat is "You" and a bot shows its sailing name. Another player (none offline yet) is "Helm n"
    /// until handles come with the online client.
    func name(of seat: Int, playerSeat: Int) -> String {
        if seat == playerSeat { return "You" }
        return self[seat].sailingName ?? "Helm \(seat + 1)"
    }

    /// `name(of:playerSeat:)` with the bot glyph in front of a bot's name, for text-only places.
    func label(of seat: Int, playerSeat: Int) -> String {
        let name = name(of: seat, playerSeat: playerSeat)
        return self[seat].isBot && seat != playerSeat ? "\(BotGlyph.text) \(name)" : name
    }
}

/// The data files a practice race is sailed on (ADR 0004): the bundled defaults, or the debug tuning panel's
/// choice (#232), whose tuned copies (#229) resolve from `catalog` and are saved beside the race's log with
/// `tunedFiles`' bytes so it replays. Two are equal when they name the same files.
struct PracticeFiles: Equatable {
    var boatClass: FileRef
    var venue: FileRef
    var conditions: FileRef
    var rulesConfiguration: FileRef
    /// Where the race's tuned copies resolve from, ahead of this build's bundled files.
    var catalog = RaceFileCatalog()
    /// Each tuned copy's exact bytes, by its ref: what the race's log is saved with (`RaceLogFolder`).
    var tunedFiles: [FileRef: Data] = [:]

    /// The bundled files a `RaceSetup` names unless told otherwise (`RaceFiles.defaults`).
    static var defaults: PracticeFiles {
        let files = RaceFiles.defaults
        return PracticeFiles(boatClass: files.boatClass.ref, venue: files.venue.ref, conditions: files.conditions.ref,
                             rulesConfiguration: files.rulesConfiguration.ref)
    }

    /// Whether any file is a tuned copy.
    var isTuned: Bool { [boatClass, venue, conditions, rulesConfiguration].contains { $0.tune != nil } }

    static func == (a: PracticeFiles, b: PracticeFiles) -> Bool {
        (a.boatClass, a.venue, a.conditions, a.rulesConfiguration) == (b.boatClass, b.venue, b.conditions, b.rulesConfiguration)
    }
}

/// A practice race as the app starts it: you in seat 0 and `opponents` bots, the race seed, the wind seed the
/// device holds for practice (ADR 0001; online, the server keeps it), and the files it's sailed on.
struct RaceConfig: Equatable {
    var opponents = 7
    var laps = RaceSetup.defaultLaps
    var prestartSeconds = 60.0
    /// The public race seed: placement, and the bots' seeds (styles and sailing names).
    var seed: UInt64
    /// Keys the wind. Always given explicitly: drawn independently of `seed` for a real race, and
    /// derived with `windSeed(pinnedTo:)` only for a pinned `-seed` launch or a test (ADR 0001).
    var windSeed: UInt64
    /// A bot controller sails your seat too (`-demo`, `-perf`).
    var botSailsYourBoat = false
    /// The bundled defaults, or the tuning panel's files (#232, Debug builds). Bots sail them too (#19).
    var files = PracticeFiles.defaults

    init(opponents: Int = 7, laps: Int = RaceSetup.defaultLaps, prestartSeconds: Double = 60,
         seed: UInt64, windSeed: UInt64, botSailsYourBoat: Bool = false) {
        self.opponents = opponents
        self.laps = laps
        self.prestartSeconds = prestartSeconds
        self.seed = seed
        self.windSeed = windSeed
        self.botSailsYourBoat = botSailsYourBoat
    }

    /// The wind seed for a race pinned to `seed` by a developer (`-seed`) or a test: a fixed mix of the
    /// launch option, so a pinned launch replays the same wind. Only those call it: real races draw both
    /// seeds independently, since the wind must never be derivable from the race seed (ADR 0001).
    static func windSeed(pinnedTo seed: UInt64) -> UInt64 {
        var rng = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544) // "WINDSEED"
        return rng.next()
    }

    /// The menu keeps opponents in 1...15 and `-perf` sails 15, so the fleet is always a valid 2...16. It
    /// names `files`: the bundled defaults (`RaceFiles.defaults`) unless the tuning panel chose others (#232).
    var setup: RaceSetup {
        try! RaceSetup(
            raceSeed: RaceSeed(seed),
            seats: [.human] + Array(repeating: .bot, count: opponents),
            laps: laps,
            startSequenceTicks: Int((prestartSeconds * Double(Race.tickRate)).rounded()),
            boatClass: files.boatClass,
            venue: files.venue,
            conditions: files.conditions,
            rulesConfiguration: files.rulesConfiguration
        )
    }

    /// A bot for each bot seat and you in seat 0, or, for `-demo`, a bot attached to seat 0 as well.
    var seatControllers: SeatControllers {
        var controllers = SeatControllers(setup: setup)
        if botSailsYourBoat { controllers[0] = .bot(BotDriver(seat: 0, raceSeed: RaceSeed(seed))) }
        return controllers
    }

    var roster: FleetRoster { FleetRoster(setup: setup) }
}
