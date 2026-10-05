@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #376 B, ported to the production model (#377): fleet simulations of the ribbon shadow with and without the backwind
/// header (print only, no expectations). The same seeded Mixed fleets of ten, full races, sailed in the default class
/// (skiff@6: ribbons, header 8°, cap 12°, lull 0, lag 1 s) and in a tuned copy of it whose header turns nothing
/// (0°: the ribbons alone, the backwind costing nothing at lull 0). The prototype's `ShadowSettings` combos (boxes,
/// box) are gone with the cone: a class file is the only switch. Slow (80 three-lap races), so it runs only with
/// `REGATTA_SHADOW_FLEET=1`:
///
///     REGATTA_SHADOW_FLEET=1 scripts/heavy.sh swift test --package-path Packages/RegattaCore \
///         --scratch-path .build/check/RegattaCore -Xswiftc -O --filter ShadowModelFleetTests
///
/// The lee-bow's own cost (distance made good over 20 s against a clean twin) is `LeeBowTests.leeBowCostOverTwentySeconds`,
/// under the same switch.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REGATTA_SHADOW_FLEET"] == "1"))
struct ShadowModelFleetTests {
    static let seeds = 40
    static let fleetSize = 10
    /// A header past this, degrees, in the `headerWindow` before a tack makes it a header-driven tack: the
    /// tactician's 4°, the cautious 5° and the blip-tacker's 3° are the bots' thresholds (`BotBrain+Tactics`).
    static let headerTackDegrees = 3.0
    static let headerWindow = 3.0
    /// A header past this, degrees, counts as headed time.
    static let headedDegrees = 1.0
    /// A boat whose shadow factor is under this is in dirty air, for the seconds counted.
    static let shadowedFactor = 0.95
    /// A tack within this many seconds of her previous one is a tack back.
    static let tackBackSeconds = 10.0

    struct Combo: Sendable {
        let name: String
        /// The class the race sails, with the catalog that resolves it.
        let boatClass: BoatClassFile
    }

    /// skiff@6 as bundled, and a tuned copy whose header is 0°.
    static func combos() throws -> [Combo] {
        let bundled = try BoatClassFile.bundled(id: "skiff", version: 6)
        let data = try #require(try BoatClassFile.bundledData(id: "skiff", version: 6))
        let text = String(decoding: data, as: UTF8.self)
        let header = #""header": { "degrees": 8,"#
        #expect(text.contains(header), "skiff@6's header is no longer \(header)")
        let unheaded = try BoatClassFile(data: Data(text.replacingOccurrences(of: header, with: #""header": { "degrees": 0,"#).utf8),
                                         tune: 1)
        return [Combo(name: "ribbons/header", boatClass: bundled), Combo(name: "ribbons/0° header", boatClass: unheaded)]
    }

    /// One race's numbers.
    struct RaceNumbers: Sendable {
        var seed: UInt64 = 0
        var finishTimes: [Double] = []
        var places: [Int?] = []
        var tiers: [BotTier] = []
        var stuck = 0
        var tacks = 0
        var headerTacks = 0
        var tackBacks = 0
        var headedSeconds = 0.0
        var headerSum = 0.0
        var headerTicks = 0
        var maxHeaderDegrees = 0.0
        var shadowedSeconds = 0.0
        var incidents = 0
        var ruleCalls = 0
        var boatContacts = 0
        var capped = false
        var seconds = 0.0
    }

    static func sail(_ cell: BotRaceCell, _ combo: Combo) throws -> RaceNumbers {
        let cellSetup = try BotRaceHarness.raceSetup(for: cell)
        let setup = try RaceSetup(raceSeed: cellSetup.raceSeed, seats: cellSetup.seats, laps: cellSetup.laps,
                                  startSequenceTicks: cellSetup.startSequenceTicks,
                                  boatClass: combo.boatClass.ref, venue: cellSetup.venue, conditions: cellSetup.conditions)
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(combo.boatClass)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) }
        var controllers = SeatControllers(tiers.indices.map {
            .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed, profile: cell.profile(ofSeat: $0)))
        })
        let n = setup.seats.count
        let dt = 1 / Double(Race.tickRate)
        let window = Int(headerWindow * Double(Race.tickRate))
        let tackBack = Int(tackBackSeconds * Double(Race.tickRate))
        var lastHeaderTick = [Int?](repeating: nil, count: n)
        var lastTack = [Int?](repeating: nil, count: n)
        var numbers = RaceNumbers(seed: cell.seed, tiers: tiers)
        let lastTick = cell.capSecondsAfterGun * Race.tickRate
        while !race.isOver && race.tick < lastTick {
            controllers.drive(race)
            race.step()
            for seat in 0..<n where race.boats[seat].status == .racing {
                let degrees = rad2deg(race.header(ofSeat: seat))
                if degrees > headerTackDegrees { lastHeaderTick[seat] = race.tick }
                if degrees > headedDegrees {
                    numbers.headedSeconds += dt
                    numbers.headerSum += degrees
                    numbers.headerTicks += 1
                }
                numbers.maxHeaderDegrees = max(numbers.maxHeaderDegrees, degrees)
                if race.boats[seat].shadow < shadowedFactor { numbers.shadowedSeconds += dt }
            }
            for event in race.drainEvents() {
                switch event.kind {
                case .tacked(let seat) where !race.boats[seat].isTakingPenalty && race.boats[seat].status == .racing:
                    numbers.tacks += 1
                    if let h = lastHeaderTick[seat], race.tick - h <= window { numbers.headerTacks += 1 }
                    if let t = lastTack[seat], race.tick - t <= tackBack { numbers.tackBacks += 1 }
                    lastTack[seat] = race.tick
                case .ruleCall: numbers.ruleCalls += 1
                case .contact: numbers.boatContacts += 1
                default: break
                }
            }
        }
        numbers.capped = !race.isOver
        numbers.seconds = Double(race.tick) / Double(Race.tickRate)
        numbers.incidents = race.incidents.count
        numbers.places = race.boats.map(\.place)
        numbers.finishTimes = race.boats.compactMap(\.finishTime)
        numbers.stuck = race.boats.filter { $0.status != .finished }.count
        return numbers
    }

    @Test func compareHeaderInMixedFleets() async throws {
        let matrix = BotMatrix(seeds: (1...UInt64(Self.seeds)).map { $0 }, fleetSizes: [Self.fleetSize],
                               tierMixes: [.mixed])
        let cells = matrix.cells
        let combos = try Self.combos()
        let start = Date()
        let results = try await withThrowingTaskGroup(of: (Int, [RaceNumbers]).self) { group in
            for (i, combo) in combos.enumerated() {
                group.addTask { (i, try cells.map { try Self.sail($0, combo) }) }
            }
            var out = [[RaceNumbers]](repeating: [], count: combos.count)
            for try await (i, races) in group { out[i] = races }
            return out
        }
        print("ShadowModelFleetTests: \(cells.count) races x \(combos.count) combos, fleet \(Self.fleetSize), "
              + "laps \(matrix.laps), \(cells.first.map { "\($0.venue) \($0.conditions)" } ?? ""), "
              + "\(String(format: "%.0f", Date().timeIntervalSince(start))) s wall")
        report(results, combos: combos)
    }

    private func report(_ results: [[RaceNumbers]], combos: [Combo]) {
        let boats = Double(Self.seeds * Self.fleetSize)
        func f(_ x: Double, _ digits: Int = 2) -> String { x.isNaN ? "-" : String(format: "%.\(digits)f", x) }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }
        var rows: [(String, [String])] = []
        func row(_ name: String, _ value: ([RaceNumbers]) -> String) { rows.append((name, results.map(value))) }

        row("mean finish s") { f(mean($0.flatMap(\.finishTimes)), 1) }
        row("finish sd s") { races in
            let all = races.flatMap(\.finishTimes), m = mean(all)
            return f((mean(all.map { ($0 - m) * ($0 - m) })).squareRoot(), 1)
        }
        row("1st-to-last spread s") { f(mean($0.compactMap { r in r.finishTimes.max().flatMap { mx in r.finishTimes.min().map { mx - $0 } } }), 1) }
        for tier in [BotTier.national, .regional, .club] {
            row("mean place \(tier.rawValue)") { races in
                f(mean(races.flatMap { r in r.tiers.indices.filter { r.tiers[$0] == tier }
                    .map { Double(r.places[$0] ?? Self.fleetSize) } }))
            }
        }
        row("tacks/boat/race") { f(Double($0.map(\.tacks).reduce(0, +)) / boats) }
        row("header tacks/boat/race") { f(Double($0.map(\.headerTacks).reduce(0, +)) / boats) }
        row("header tacks share") { races in
            let t = races.map(\.tacks).reduce(0, +)
            return f(t == 0 ? 0 : Double(races.map(\.headerTacks).reduce(0, +)) / Double(t), 3)
        }
        row("tack-backs <10s/boat/race") { f(Double($0.map(\.tackBacks).reduce(0, +)) / boats) }
        row("headed >1deg s/boat") { f($0.map(\.headedSeconds).reduce(0, +) / boats, 1) }
        row("mean header when >1deg") { races in
            let ticks = races.map(\.headerTicks).reduce(0, +)
            return ticks == 0 ? "-" : f(races.map(\.headerSum).reduce(0, +) / Double(ticks))
        }
        row("max header deg") { f($0.map(\.maxHeaderDegrees).max() ?? 0) }
        row("shadow<0.95 s/boat") { f($0.map(\.shadowedSeconds).reduce(0, +) / boats, 1) }
        row("incidents/race") { f(mean($0.map { Double($0.incidents) })) }
        row("rule calls/race") { f(mean($0.map { Double($0.ruleCalls) })) }
        row("boat contacts/race") { f(mean($0.map { Double($0.boatContacts) })) }
        row("unfinished boats") { "\($0.map(\.stuck).reduce(0, +))" }
        row("capped races") { "\($0.filter(\.capped).count)" }
        // How far the results move: each boat's place against her place in the same seed's first-combo race.
        let base = results[0]
        row("mean |place change| vs first") { races in
            f(mean(zip(races, base).flatMap { r, b in
                r.places.indices.map { Double(abs((r.places[$0] ?? Self.fleetSize) - (b.places[$0] ?? Self.fleetSize))) }
            }))
        }
        row("same winner as first") { races in
            "\(zip(races, base).filter { r, b in r.places.firstIndex(of: 1) == b.places.firstIndex(of: 1) }.count)/\(races.count)"
        }

        let width = rows.map(\.0.count).max() ?? 0
        func pad(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
        print("| " + "metric".padding(toLength: width, withPad: " ", startingAt: 0) + " | "
              + combos.map { pad($0.name, 16) }.joined(separator: " | ") + " |")
        for (name, values) in rows {
            print("| " + name.padding(toLength: width, withPad: " ", startingAt: 0) + " | "
                  + values.map { pad($0, 16) }.joined(separator: " | ") + " |")
        }
    }
}
