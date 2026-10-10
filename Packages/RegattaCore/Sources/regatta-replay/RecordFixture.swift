// `regatta-replay record-fixture [--scene <log>] [--seeds <n>] [--survey] <fixtures folder> <table.json> <scenes.json>` (#466):
// records the render fixtures' logs, one short log per scene, so a re-record after a default-class or bot change is
// one command (`scripts/record-fixtures.sh --record`) and never a seed hunt on a fast machine.
//
// Each scene (a row of scenes.json, `FixtureScene`) is a bot race on the default class (or the class it pins) whose
// log is the fixtures folder's `<log>`. Seeds from the scene's first one are sailed, a batch at a time in parallel, and
// the lowest seed whose race meets every freeze-tick row naming that log (table.json, `FreezeTickRow`) is kept: its
// race, cut off once every row has its tick and every other fixture reading the log (a hand-set `freezeTick`) is
// covered, is written as the log. A candidate is dropped as soon as a row can no longer be met (its seat past the row's
// leg), at the scene's `maxTick`, or when its race is over. No seed in `--seeds` (default 200): exit 1, nothing written.
//
// The conditions are read as `freeze-ticks` reads them (`FreezeTicks.Scan`), so `freeze-ticks` then picks, on the
// written log, the ticks the recording found. Recording writes only logs; run `freeze-ticks` after it.
import Dispatch
import Foundation
import RegattaBots
import RegattaCore

/// One render scene's race (`scripts/fixture-scenes.json`): the fixtures log it writes and the race it sails. Files are
/// `id@version`, bundled.
struct FixtureScene: Decodable {
    var log: String
    /// The seats, the first one the human's (the fixtures' "you"), the rest bots. Every seat is sailed by a bot.
    var seats: Int
    var laps: Int
    var startSequenceTicks: Int
    /// The class: the default when nil, so a re-record after a default switch moves the fixtures onto it.
    var boatClass: String?
    var venue: String
    var conditions: String
    var rulesConfiguration: String
    /// The latest tick a candidate race sails to before it's dropped: the log's length cap.
    var maxTick: Int
    /// The first seed tried (default 1).
    var firstSeed: UInt64?
    /// Your seat's script, when the scene needs more than a bot's race (nil: a bot sails you throughout).
    /// "penaltyTurnAtOnce": on each call on you, you turn your penalty at once, the helm hard over towards the
    /// nearest other boat, for up to `scriptSeconds` (default 6) or until the turn is served; then your bot takes you
    /// back. A turn in the thick of it draws the 21.2 call the rules-call scene shows, where a bot's turn waits for
    /// clear water. "headUpAfterFirstFinish": once a ghost is in your view, you head up to close-hauled and hold there
    /// (`YourScript.headUp`).
    var yourScript: String?
    var scriptSeconds: Double?
    /// Your bot's chance of misjudging each encounter she must keep clear in (`BotWeaknesses.ruleMisjudgeRate`), in
    /// place of her draw's: 1 sails on through every one, so the rule calls the rules scenes show come on you.
    var yourRuleMisjudgeRate: Double?
}

enum RecordFixture {
    static let usage = "usage: regatta-replay record-fixture [--scene <log>] [--seeds <n>] [--survey] <fixtures folder> <table.json> <scenes.json>"

    static func main(arguments: [String]) -> Int32 {
        var arguments = arguments
        var only: String?
        var seeds = 200
        // --survey: sail every seed of the range and report how many meet the rows, writing nothing (how robust a
        // scene is, e.g. after a bot change).
        let survey = arguments.contains("--survey")
        arguments.removeAll { $0 == "--survey" }
        while let flag = arguments.first(where: { $0.hasPrefix("--") }), let index = arguments.firstIndex(of: flag) {
            guard index + 1 < arguments.count else { return usageError() }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            switch flag {
            case "--scene": only = value
            case "--seeds": guard let n = Int(value), n > 0 else { return usageError() }; seeds = n
            default: return usageError()
            }
        }
        guard arguments.count == 3 else { return usageError() }
        let folder = URL(fileURLWithPath: arguments[0])
        do {
            let rows = try JSONDecoder().decode([FreezeTickRow].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            let scenes = try JSONDecoder().decode([FixtureScene].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let chosen = scenes.filter { only == nil || $0.log == only || $0.log == only.map { "\($0).racelog.json" } }
            guard !chosen.isEmpty else {
                FileHandle.standardError.write(Data("regatta-replay: no scene \(only ?? "")\n".utf8))
                return 2
            }
            var status: Int32 = 0
            for scene in chosen {
                let started = Date()
                let sceneRows = rows.filter { $0.log == scene.log }
                guard !sceneRows.isEmpty else {
                    print("\(scene.log): no freeze-tick row reads it")
                    status = 1
                    continue
                }
                let covered = try handSetTicks(folder, log: scene.log, rows: rows)
                if survey {
                    let hits = try search(scene, rows: sceneRows, through: covered.max(), seeds: seeds, all: true)
                    print("\(scene.log): \(hits.count) of \(seeds) seeds meet its rows: \(hits.map(\.0))")
                    continue
                }
                guard let (seed, log) = try search(scene, rows: sceneRows, through: covered.max(), seeds: seeds).first else {
                    print("\(scene.log): no seed in \(scene.firstSeed ?? 1)..<\((scene.firstSeed ?? 1) + UInt64(seeds)) meets its rows")
                    status = 1
                    continue
                }
                try log.jsonData().write(to: folder.appendingPathComponent(scene.log))
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                print("\(scene.log): seed \(seed), \(log.header.setup.boatClass), final tick \(log.finalTick) (\(seconds) s)")
            }
            return status
        } catch {
            FileHandle.standardError.write(Data("regatta-replay: \(error)\n".utf8))
            return 1
        }
    }

    static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }

    /// The freeze ticks of the fixtures reading `log` that no row picks: the log must reach them.
    static func handSetTicks(_ folder: URL, log: String, rows: [FreezeTickRow]) throws -> [Int] {
        let picked = Set(rows.flatMap(\.fixtures))
        struct Fixture: Decodable { var log: String?; var freezeTick: Int? }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".racelog.json") }
            .filter { !picked.contains($0.deletingPathExtension().lastPathComponent) }
            .compactMap { url in
                let fixture = try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
                return fixture?.log == log ? fixture?.freezeTick : nil
            }
    }

    /// The lowest seed in the scene's range whose race meets every row, and its log (every such seed when `all`); none
    /// when none does.
    static func search(_ scene: FixtureScene, rows: [FreezeTickRow], through handSet: Int?, seeds: Int, all: Bool = false)
        throws -> [(UInt64, RaceLog)] {
        var hits: [(UInt64, RaceLog)] = []
        let first = scene.firstSeed ?? 1
        let batch = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var next = first
        while next < first + UInt64(seeds) {
            let candidates = Array(next..<min(next + UInt64(batch), first + UInt64(seeds)))
            next += UInt64(candidates.count)
            let results = Results(count: candidates.count)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                results.set(index, Result { try sail(scene, seed: candidates[index], rows: rows, through: handSet) })
            }
            for (seed, result) in zip(candidates, results.all) {
                if let log = try result.get() { hits.append((seed, log)) }
            }
            if !all, !hits.isEmpty { return [hits[0]] }
        }
        return hits
    }

    /// Seed `seed`'s race of the scene, every seat a bot, cut off at the last tick its fixtures need; nil when a row
    /// isn't met by `maxTick`, the race's end, or the leg it wants.
    static func sail(_ scene: FixtureScene, seed: UInt64, rows: [FreezeTickRow], through handSet: Int?) throws -> RaceLog? {
        let setup = try RaceSetup(
            raceSeed: RaceSeed(seed), seats: [.human] + Array(repeating: .bot, count: scene.seats - 1), laps: scene.laps,
            startSequenceTicks: scene.startSequenceTicks,
            boatClass: try scene.boatClass.map { try BoatClassFile.bundled(ref($0)).ref } ?? RaceFiles.defaults.boatClass.ref,
            venue: try VenueFile.bundled(ref(scene.venue)).ref,
            conditions: try ConditionsFile.bundled(ref(scene.conditions)).ref,
            rulesConfiguration: try RulesConfigFile.bundled(ref(scene.rulesConfiguration)).ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: windSeed(seed)))
        var controllers = SeatControllers(race.boats.indices.map {
            .bot($0 == 0 ? yourDriver(scene, raceSeed: setup.raceSeed) : BotDriver(seat: $0, raceSeed: setup.raceSeed))
        })
        var scan = FreezeTicks.Scan(rows, setup: setup)
        scan.observe(race)
        var script = YourScript(scene)
        while true {
            if scan.allFound, race.tick >= (scan.found.compactMap { $0 } + [handSet ?? .min]).max()! { return race.log }
            if race.isOver || race.tick >= scene.maxTick || scan.isHopeless(race) { return nil }
            script?.drive(race, &controllers, calls: scan.calls, you: yourDriver(scene, raceSeed: setup.raceSeed))
            controllers.drive(race)
            race.step()
            scan.observe(race)
        }
    }

    /// The bot sailing your seat: the fleet's draw for it (`BotDriver(seat:raceSeed:)`), misjudging as the scene says.
    static func yourDriver(_ scene: FixtureScene, raceSeed: RaceSeed) -> BotDriver {
        guard let rate = scene.yourRuleMisjudgeRate else { return BotDriver(seat: 0, raceSeed: raceSeed) }
        let seed = botSeed(raceSeed: raceSeed, seat: 0)
        let drawn = BotTier.mixedFleetDraw(seed: seed)
        let handling = drawn.tier.handling(seed: seed)
        var weaknesses = BotWeaknesses(skill: drawn.skill, handling: handling)
        weaknesses.ruleMisjudgeRate = rate
        return BotDriver(seat: 0, raceSeed: raceSeed, skill: drawn.skill, handling: handling, weaknesses: weaknesses)
    }

    /// Your seat's script (`FixtureScene.yourScript`): seat 0, the setup's human seat.
    struct YourScript {
        enum Kind { case penaltyTurnAtOnce, headUpAfterFirstFinish }
        let kind: Kind
        let ticks: Int
        var seen = 0
        /// While a penalty turn is scripted: the rudder held and the tick a bot takes you back.
        var turn: (rudder: Double, until: Int)?
        var headingUp = false

        init?(_ scene: FixtureScene) {
            switch scene.yourScript {
            case "penaltyTurnAtOnce": kind = .penaltyTurnAtOnce
            case "headUpAfterFirstFinish": kind = .headUpAfterFirstFinish
            default: return nil
            }
            ticks = Int((scene.scriptSeconds ?? 6) * Double(Race.tickRate))
        }

        mutating func drive(_ race: Race, _ controllers: inout SeatControllers, calls: [RuleCall], you: BotDriver) {
            switch kind {
            case .penaltyTurnAtOnce: turnAtOnce(race, &controllers, calls: calls, you: you)
            case .headUpAfterFirstFinish: headUp(race, &controllers)
            }
        }

        mutating func turnAtOnce(_ race: Race, _ controllers: inout SeatControllers, calls: [RuleCall], you: BotDriver) {
            let me = 0
            for call in calls[seen...] where call.offender == me && turn == nil && !race.boats[me].isGhost {
                // Hard over towards the nearest boat but the one you fouled (a call on that pair again is the same
                // incident): headings run clockwise and a positive rudder turns that way.
                let boat = race.boats[me]
                let others = race.boats.indices.filter { $0 != me && $0 != call.victim && !race.boats[$0].isGhost }
                let target = others.min { (race.boats[$0].position - boat.position).length
                    < (race.boats[$1].position - boat.position).length } ?? call.victim
                let towards = race.boats[target].position - boat.position
                let clockwise = boat.forward.x * towards.y - boat.forward.y * towards.x < 0
                turn = (clockwise ? 1 : -1, race.tick + ticks)
                controllers[me] = .human
            }
            seen = calls.count
            guard let held = turn else { return }
            if race.tick >= held.until || race.boats[me].penaltyTurnsOwed == 0 || race.boats[me].isGhost {
                turn = nil
                controllers[me] = .bot(you.takingOver())
            } else {
                _ = race.apply(BoatInput(rudder: held.rudder), seat: me, atTick: race.tick + 1)
            }
        }

        /// Once a boat has finished and her ghost is in your view, while you still race to the finish, you head up to
        /// close-hauled and hold there: your sail working upwind casts the backwind wedge the fleet scene shows beside the ghost, where
        /// every boat running to a downwind finish casts none (#437).
        mutating func headUp(_ race: Race, _ controllers: inout SeatControllers) {
            let me = 0
            let boat = race.boats[me]
            if !headingUp {
                // Once a ghost is in your view (as the fleet row reads it), at the finish with the boats around you.
                let centre = boat.position + boat.velocity * 2
                let view = FreezeTickRow.defaultView
                let ghostInView = race.boats.contains {
                    $0.isGhost && abs($0.position.x - centre.x) < view[0] && abs($0.position.y - centre.y) < view[1]
                }
                guard boat.status == .racing, ghostInView else { return }
                headingUp = true
                controllers[me] = .human
            }
            guard !boat.isGhost else { return }
            // Wind over the starboard side (relative > 0) is clockwise of the bow, and a positive rudder turns
            // clockwise: towards the wind.
            let closeHauled = Autohelm.grooveAngle(.upwind, tws: boat.grooveWindSpeed(in: race.boatClass), boatClass: race.boatClass)
            let relative = boat.relativeWind
            let off = relative - (relative >= 0 ? closeHauled : -closeHauled)
            _ = race.apply(BoatInput(rudder: (2 * off).clamped(to: -1...1)), seat: me, atTick: race.tick + 1)
        }
    }

    /// The app's wind seed for a pinned race seed (`RaceConfig.windSeed(pinnedTo:)`), so `-demo -seed <n>` sails it too.
    static func windSeed(_ seed: UInt64) -> WindSeed {
        var rng = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544) // "WINDSEED"
        return WindSeed(rng.next())
    }

    /// `id@version` as its parts.
    static func ref(_ text: String) throws -> (id: String, version: Int) {
        let parts = text.split(separator: "@")
        guard parts.count == 2, let version = Int(parts[1]) else { throw FreezeTicks.Failure(description: "not id@version: \(text)") }
        return (String(parts[0]), version)
    }

    /// Each parallel candidate's result, by index.
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<RaceLog?, Error>]

        init(count: Int) { results = Array(repeating: .success(nil), count: count) }

        func set(_ index: Int, _ result: Result<RaceLog?, Error>) {
            lock.lock()
            results[index] = result
            lock.unlock()
        }

        var all: [Result<RaceLog?, Error>] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }
}

extension DataFile {
    static func bundled(_ ref: (id: String, version: Int)) throws -> DataFile { try bundled(id: ref.id, version: ref.version) }
}
