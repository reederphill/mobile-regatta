import BotSuite
import Foundation
import RegattaCore
import Testing

@Suite struct BotSuiteCommandTests {
    /// #19: the full matrix covers every set of conditions, fleet sizes from 2 to 16, and every tier mix.
    @Test func bundledMatrixCoversTheSuiteAxes() throws {
        let matrix = try BotMatrix.bundled()
        try matrix.validate()
        #expect(matrix.fleetSizes == [2, 5, 10, 16])
        #expect(matrix.venues == ["dev-venue@2"])
        #expect(Set(matrix.conditions) == ["classic-oscillating@2", "gusty-offshore@2", "light-and-patchy@2", "sea-breeze@2"])
        #expect(Set(matrix.tierMixes) == Set(TierMix.allCases))
        #expect(!matrix.seeds.isEmpty && !matrix.tideStatesDegrees.isEmpty)
        #expect(matrix.cells.count == matrix.seeds.count * 4 * matrix.tideStatesDegrees.count * 4 * TierMix.allCases.count)
    }

    @Test func optionsOverrideTheMatrix() throws {
        let options = try BotSuiteOptions(arguments: ["--seeds", "2", "--fleet-size", "16", "--fleet-size", "2",
                                                      "--tier-mix", "national", "--laps", "1", "--json", "-"])
        let matrix = try options.matrix()
        #expect(matrix.seeds == [1, 2])
        #expect(matrix.fleetSizes == [16, 2])
        #expect(matrix.tierMixes == [.national])
        #expect(matrix.laps == 1)
        #expect(options.jsonPath == "-")

        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--seeds"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--seeds", "0"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--tier-mix", "pro"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--fleet-size", "17"]).matrix() }
    }

    @Test func matrixRejectsAnEmptyAxisAndUnbundledFiles() {
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [], fleetSizes: [2]).validate() }
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], fleetSizes: [1]).validate() }
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], venues: ["dev-venue"], fleetSizes: [2]).validate() }
        #expect(throws: (any Error).self) { try BotMatrix(seeds: [1], conditions: ["doldrums@1"], fleetSizes: [2]).validate() }
    }

    #if os(macOS) || os(Linux)
    /// #97 acceptance: the CLI sails a 16-boat matrix and emits JSON with every metric, for every seat.
    @Test func sixteenBoatMatrixEmitsEveryMetric() throws {
        let matrix = BotMatrix(seeds: [7], fleetSizes: [16], tierMixes: [.mixed], laps: 1)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "thresholds"), "--json", "-"])
        #expect(run.status == 0)

        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        for key in ["simulationVersion", "matrix", "thresholds", "races", "tiers", "timings", "breaches", "passed"] {
            #expect(object[key] != nil, "report has no \(key)")
        }
        let races = try #require(object["races"] as? [[String: Any]])
        #expect(races.count == 1)
        let race = try #require(races.first)
        let seats = try #require(race["seats"] as? [[String: Any]])
        #expect(seats.count == 16)
        for seat in seats {
            for key in SeatMetrics.metricKeys + ["seat", "tier", "skill", "status"] {
                #expect(seat[key] != nil, "seat \(seat["seat"] ?? "?") has no \(key)")
            }
        }
        let timings = try #require(race["timings"] as? [String: Any])
        for key in ["ticks", "p50Ms", "p99Ms", "maxMs"] { #expect(timings[key] != nil, "timings have no \(key)") }
        let fleet = try #require(race["fleet"] as? [String: Any])
        for key in ["finished", "finishShare", "ironsSeconds", "markContacts", "boatContacts", "ruleCalls",
                    "dsqMissedPenalty", "ocsCount", "edgeSeconds"] {
            #expect(fleet[key] != nil, "fleet has no \(key)")
        }

        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        let result = try #require(report.races.first)
        #expect(result.cell.fleetSize == 16)
        #expect(result.seats.map(\.seat) == Array(0..<16))
        #expect(result.seats.map(\.tier) == (0..<16).map { TierMix.mixed.tier(ofSeat: $0) })
        #expect(!result.capped)
        #expect(result.fleet.finished > 0)
        #expect(result.seats.allSatisfy { $0.finished == ($0.place != nil) || $0.status == "dsq" })
        #expect(result.timings.ticks > 0 && result.timings.p50Ms <= result.timings.p99Ms)
        #expect(Set(report.tiers.keys) == ["club", "regional", "national"])
        #expect(report.passed)
    }

    @Test func unknownArgumentIsAUsageError() throws {
        #expect(try botsuite(["--nope"]).status == 2)
    }
    #endif
}
