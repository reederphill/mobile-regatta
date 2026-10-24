@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// Scratch, never committed: #591's cheap test. Sails the start gate (all-National and mixed) and a conduct sample at
/// the probe knobs the environment sets (`ProbeKnobs`).
@Suite struct ScratchKeepClearProbe {
    @Test func probe() throws {
        let conditions = BotStartSuiteTests.conditions
        func cells(_ mix: TierMix, laps: Int, cap: Int, seeds: ClosedRange<Int>, profiles: ProfileMix = .live) -> [BotRaceCell] {
            seeds.map { seed in
                BotRaceCell(seed: UInt64(seed), venue: "dev-venue@3", conditions: conditions[seed % 4], tideStateDegrees: 0,
                            fleetSize: 10, tierMix: mix, profileMix: profiles, laps: laps, capSecondsAfterGun: cap)
            }
        }
        func sail(_ cells: [BotRaceCell]) throws -> [RaceResult] {
            try BotSuite.inParallel(cells, jobs: BotSuite.defaultJobs) { try BotRaceHarness.run($0) }
        }
        func line(_ name: String, _ seats: [SeatMetrics]) -> String {
            let starts = seats.map { $0.startSeconds ?? 30 }
            return String(format: "%@ seats %d mean start %.2f s on time %.3f OCS %.3f", name, seats.count,
                          starts.reduce(0, +) / Double(seats.count),
                          Double(seats.filter { ($0.startSeconds ?? .infinity) <= 3 }.count) / Double(seats.count),
                          Double(seats.filter { $0.ocsCount > 0 }.count) / Double(seats.count))
        }
        let env = ProcessInfo.processInfo.environment
        let label = ["KC_DISTANCE", "KC_MARGIN", "KC_SLOPE", "KC_THIN_COST", "KC_PLANNER", "KC_PROFILES"].map { "\($0)=\(env[$0] ?? "-")" }
            .joined(separator: " ")
        let profiles = ProfileMix(rawValue: env["KC_PROFILES"] ?? "live") ?? .live
        if env["KC_CONDUCT_ONLY"] == nil {
        let national = try sail(cells(.national, laps: 1, cap: 30, seeds: 1...200)).flatMap(\.seats)
        print("PROBE [\(label)] " + line("all-national", national))
        let mixed = try sail(cells(.mixed, laps: 1, cap: 30, seeds: 1...200)).flatMap(\.seats)
        for tier in [BotTier.national, .regional, .club] {
            print("PROBE [\(label)] " + line("mixed-\(tier.rawValue)", mixed.filter { $0.tier == tier }))
        }
        }
        let conduct = try sail(cells(.national, laps: 1, cap: BotMatrix.defaultCapSecondsAfterGun, seeds: 1...40,
                                     profiles: profiles))
        let seats = conduct.flatMap(\.seats)
        let encounters = seats.reduce(0) { $0 + $1.encounters }
        let fouls = seats.reduce(0) { $0 + $1.encountersEndingInFouls }
        let pre = seats.reduce(0) { $0 + $1.preStartEncounters }
        let preFouls = seats.reduce(0) { $0 + $1.preStartEncountersEndingInFouls }
        let contacts = seats.reduce(0) { $0 + $1.boatContacts }
        let marks = seats.reduce(0) { $0 + $1.markContacts }
        let r161 = conduct.reduce(0) { $0 + ($1.rule161?.calls ?? 0) }
        let centred = conduct.reduce(0) { $0 + ($1.rule161?.centredRudder ?? 0) }
        print(String(format: "PROBE [%@] conduct 40 all-national laps 1: encounters %d fouls %d share %.4f; pre-start %d fouls %d share %.4f; boat contacts %d mark contacts %d; 16.1 calls %d centred-rudder %d; finished %d/%d",
                     label, encounters, fouls, Double(fouls) / Double(max(encounters, 1)), pre, preFouls,
                     Double(preFouls) / Double(max(pre, 1)), contacts, marks, r161, centred,
                     seats.filter(\.finished).count, seats.count))
        var all: [String: Int] = [:], preRules: [String: Int] = [:]
        for seat in seats {
            all.merge(seat.callsByRule, uniquingKeysWith: +)
            preRules.merge(seat.preStartCallsByRule, uniquingKeysWith: +)
        }
        func rules(_ d: [String: Int]) -> String {
            d.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { "\($0) \(d[$0]!)" }.joined(separator: ", ")
        }
        print("PROBE [\(label)] calls by rule (offender): all: \(rules(all)); pre-start: \(rules(preRules))")
    }
}
