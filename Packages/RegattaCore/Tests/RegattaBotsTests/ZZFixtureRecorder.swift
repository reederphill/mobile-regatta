// THROWAWAY (#437): re-records the render fixture logs on the default class. Not committed.
import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

@Suite struct ZZFixtureRecorder {
    static func pinnedWind(_ seed: UInt64) -> UInt64 {
        var rng = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544)
        return rng.next()
    }

    @Test func record() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REC_OUT"], let src = env["REC_SRC"], let namesText = env["REC_NAMES"] else { return }
        let seeds: [UInt64]? = env["REC_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } }
        let defaultClass = RaceFiles.defaults.boatClass.ref
        for name in namesText.split(separator: ",").map(String.init) {
            let old = try RaceLog(jsonData: Data(contentsOf: URL(fileURLWithPath: "\(src)/\(name).racelog.json")))
            let s = old.header.setup
            print("REC \(name): old seed \(s.raceSeed.value) wind \(old.header.windSeed.value) pinned(old) \(Self.pinnedWind(s.raceSeed.value))")
            for seed in seeds ?? [s.raceSeed.value] {
                let windSeed = seeds == nil ? old.header.windSeed : WindSeed(Self.pinnedWind(seed))
                let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: s.seats, laps: s.laps,
                                          startSequenceTicks: s.startSequenceTicks, boatClass: defaultClass, venue: s.venue,
                                          conditions: s.conditions, rulesConfiguration: s.rulesConfiguration)
                let race = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: windSeed))
                var controllers = allBots(race)
                let untilOver = name == "fleet"
                let until = env["REC_UNTIL"].flatMap { Int($0) } ?? old.finalTick
                while !race.isOver && (untilOver || race.tick < until) {
                    controllers.drive(race)
                    race.step()
                }
                let log = try #require(race.log)
                let dir = seeds == nil ? out : "\(out)/\(seed)"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try log.jsonData().write(to: URL(fileURLWithPath: "\(dir)/\(name).racelog.json"))
                print("REC \(name) seed \(seed): finalTick \(log.finalTick) (old \(old.finalTick)) over \(race.isOver)")
            }
        }
    }
}
