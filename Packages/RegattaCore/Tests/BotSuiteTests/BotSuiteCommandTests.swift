import BotSuite
import RegattaBots
import Foundation
import RegattaCore
import Testing

@Suite struct BotSuiteCommandTests {
    /// #19: the full matrix covers every set of conditions, fleet sizes from 2 to 16, and every tier mix;
    /// since #238, the conditions at version 3 (#221, #233) and their venue; since #286, version 4, with the
    /// pressure field, and its venue; since #287, version 5 and dev-venue@5, whose geography steers the field;
    /// since #288, version 6 and dev-venue@6, whose puffs form from the field; since the finite lanes, version 7 and
    /// dev-venue@7; since #316, the three real venues (#83) in the two conditions each pairs with.
    @Test func bundledMatrixCoversTheSuiteAxes() throws {
        let matrix = try BotMatrix.bundled()
        try matrix.validate()
        #expect(matrix.fleetSizes == [2, 5, 10, 16])
        #expect(matrix.venues == ["dev-venue@7", "fellmere@1", "hollin-bay@1", "saltings-reach@1"])
        #expect(Set(matrix.conditions) == ["classic-oscillating@7", "gusty-offshore@7", "light-and-patchy@7", "sea-breeze@7"])
        #expect(matrix.conditions(at: "dev-venue@7") == matrix.conditions)
        #expect(matrix.conditions(at: "fellmere@1") == ["gusty-offshore@7", "light-and-patchy@7"])
        #expect(matrix.conditions(at: "hollin-bay@1") == ["classic-oscillating@7", "sea-breeze@7"])
        #expect(matrix.conditions(at: "saltings-reach@1") == ["classic-oscillating@7", "gusty-offshore@7"])
        // Each venue sails exactly the pairings its file has.
        for venue in matrix.venues {
            let parts = venue.split(separator: "@")
            let pairings = try VenueFile.bundled(id: String(parts[0]), version: try #require(Int(parts[1]))).content.pairings
            #expect(Set(matrix.conditions(at: venue)) == Set(pairings.map { "\($0.conditions.id)@\($0.conditions.version)" }))
        }
        #expect(Set(matrix.tierMixes) == Set(TierMix.allCases))
        // #231: the live bots the tiers gate, and the skill-gap scenario; #238: the fun pass, in classic
        // oscillating conditions only.
        // #355: the hunters mix is sailed only when named (`--profile-mix hunters`), never in the bundle.
        // #105: execution, the cautious bot among live bots, rivals and rank stability join it.
        // #435: so is the handling mix (`--profile-mix handling`), and the bundle sails each class as bundled.
        #expect(Set(matrix.profileMixes) == Set(ProfileMix.allCases).subtracting([.hunters, .handling]))
        #expect(!matrix.cells.contains { $0.profileMix == .hunters || $0.profileMix == .handling })
        #expect(!matrix.autohelmOff && matrix.cells.allSatisfy { $0.autohelmOff == nil })
        #expect(!matrix.seeds.isEmpty && !matrix.tideStatesDegrees.isEmpty)
        // Venue × conditions pairings: dev-venue's four and two at each real venue; three of them classic oscillating.
        let pairings = 4 + 3 * 2
        let classicPairings = 1 + 2
        #expect(matrix.venues.map { matrix.conditions(at: $0).count }.reduce(0, +) == pairings)
        let races = matrix.seeds.count * matrix.tideStatesDegrees.count
        let fleets = matrix.fleetSizes.count, tiers = TierMix.allCases.count
        // Live, skill gap and cautious in every pairing, fleet size and tier mix; the fun pass in the classic oscillating
        // pairings only; execution, rivals and rank stability in every pairing but one tier mix each
        // (`ProfileMix.tierMix`). Rivals and rank stability in fleets of 10 alone (`mixFleetSizes`), so their summaries
        // pool no other size.
        #expect(matrix.mixFleetSizes == [.rivals: 10, .rankStability: 10])
        #expect(matrix.cells.count == races * fleets * tiers * (3 * pairings + classicPairings) + races * fleets * pairings
            + races * pairings * 2)
        #expect(Set(matrix.cells.filter { [.rivals, .rankStability].contains($0.profileMix) }.map(\.fleetSize)) == [10])
        #expect(Set(matrix.cells.filter { $0.profileMix == .execution }.map(\.tierMix)) == [.national])
        #expect(Set(matrix.cells.filter { $0.profileMix == .rankStability }.map(\.tierMix)) == [.mixed])
        #expect(Set(matrix.cells.filter { $0.profileMix == .funPass }.map(\.conditions)) == ["classic-oscillating@7"])
    }

    @Test func optionsOverrideTheMatrix() throws {
        let options = try BotSuiteOptions(arguments: ["--seeds", "2", "--fleet-size", "16", "--fleet-size", "2",
                                                      "--tier-mix", "national", "--profile-mix", "skillGap",
                                                      "--profile-mix", "funPass", "--profile-mix", "hunters", "--laps", "1",
                                                      "--json", "-", "--jobs", "3"])
        let matrix = try options.matrix()
        #expect(matrix.seeds == [1, 2])
        #expect(matrix.fleetSizes == [16, 2])
        #expect(matrix.tierMixes == [.national])
        #expect(matrix.profileMixes == [.skillGap, .funPass, .hunters])
        #expect(matrix.laps == 1)
        #expect(options.jsonPath == "-")
        #expect(options.jobs == 3)
        #expect(try BotSuiteOptions(arguments: []).jobs == nil)
        #expect(BotSuite.defaultJobs >= 1)

        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--seeds"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--seeds", "0"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--jobs", "0"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--tier-mix", "pro"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--profile-mix", "blipTacker"]) }
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--fleet-size", "17"]).matrix() }
    }

    /// #316: a venue sails only the conditions `conditionsByVenue` gives it, in the matrix's order; a venue it doesn't
    /// name sails them all, its cells as before; and it names only the matrix's own venues and conditions.
    @Test func matrixSailsEachVenueInItsOwnPairings() throws {
        let all = ["classic-oscillating@7", "gusty-offshore@7", "light-and-patchy@7", "sea-breeze@7"]
        let dev = BotMatrix(seeds: [1, 2], venues: ["dev-venue@7"], conditions: all, fleetSizes: [2, 10],
                            profileMixes: [.live, .funPass])
        var both = dev
        both.venues.append("fellmere@1")
        both.conditionsByVenue = ["fellmere@1": ["light-and-patchy@7", "gusty-offshore@7"]]
        try both.validate()
        #expect(both.cells.filter { $0.venue == "dev-venue@7" } == dev.cells, "dev-venue's cells are unchanged")
        let fellmere = both.cells.filter { $0.venue == "fellmere@1" }
        #expect(Set(fellmere.map(\.conditions)) == ["gusty-offshore@7", "light-and-patchy@7"])
        #expect(fellmere.first?.conditions == "gusty-offshore@7", "in the matrix's order")
        #expect(!fellmere.contains { $0.profileMix == .funPass }, "fellmere has no classic oscillating pairing")
        // Encoded without the map when it is empty; decoded with it, or without it as before.
        let encoded = try JSONEncoder().encode(dev)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("conditionsByVenue"))
        #expect(try JSONDecoder().decode(BotMatrix.self, from: encoded) == dev)
        #expect(try JSONDecoder().decode(BotMatrix.self, from: JSONEncoder().encode(both)) == both)

        var unpaired = both
        unpaired.conditionsByVenue = [:]
        #expect(throws: BotSuiteError.self) { try unpaired.validate() }
        var stranger = both
        stranger.conditionsByVenue["hollin-bay@1"] = ["classic-oscillating@7"]
        #expect(throws: BotSuiteError.self) { try stranger.validate() }
        var unnamed = both
        unnamed.conditions = ["gusty-offshore@7"]
        #expect(throws: BotSuiteError.self) { try unnamed.validate() }
        var empty = both
        empty.conditionsByVenue["fellmere@1"] = []
        #expect(throws: BotSuiteError.self) { try empty.validate() }
    }

    @Test func matrixRejectsAnEmptyAxisAndUnbundledFiles() {
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [], fleetSizes: [2]).validate() }
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], fleetSizes: [2], profileMixes: []).validate() }
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], fleetSizes: [1]).validate() }
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], venues: ["dev-venue"], fleetSizes: [2]).validate() }
        #expect(throws: (any Error).self) { try BotMatrix(seeds: [1], conditions: ["doldrums@1"], fleetSizes: [2]).validate() }
        // dev-venue@3 pairs with the version 3 conditions only (#233).
        #expect(throws: BotSuiteError.self) { try BotMatrix(seeds: [1], conditions: ["classic-oscillating@2"], fleetSizes: [2]).validate() }
        // #238: the fun pass sails only in classic oscillating conditions.
        #expect(throws: BotSuiteError.self) {
            try BotMatrix(seeds: [1], conditions: ["gusty-offshore@3"], fleetSizes: [2], profileMixes: [.funPass]).validate()
        }
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
        #expect(result.seats.map(\.tier) == (0..<16).map { TierMix.mixed.tier(ofSeat: $0, raceSeed: RaceSeed(7)) })
        #expect(!result.capped)
        #expect(result.fleet.finished > 0)
        #expect(result.seats.allSatisfy { $0.finished == ($0.place != nil) || $0.status == "dsq" })
        #expect(result.timings.ticks > 0 && result.timings.p50Ms <= result.timings.p99Ms)
        #expect(Set(report.tiers.keys) == ["club", "regional", "national"])
        #expect(report.passed)

        // #443: each live bot's handling skill, in the handling band of her tier, and places by either axis.
        for seat in result.seats {
            let handling = try #require(seat.handling, "seat \(seat.seat) has no handling")
            #expect(seat.tier.handlingBand.contains(handling))
            #expect(seats[seat.seat]["handling"] != nil)
        }
        let axes = try #require(report.axes)
        #expect(report.handlingAxes == nil)
        #expect(axes.skillBuckets == BotTier.allCases.map(\.rawValue) && axes.handlingBuckets == axes.skillBuckets)
        #expect(axes.bySkill.values.reduce(0) { $0 + $1.seats } == 16)
        #expect(axes.byHandling.values.reduce(0) { $0 + $1.seats } == 16)
        #expect(axes.grid.values.flatMap(\.values).reduce(0) { $0 + $1.seats } == 16)
        #expect(report.lines.contains { $0.hasPrefix("live places by tactics skill and handling skill") })
        // A run from before #443, with no handling, still decodes.
        var old = object
        old["races"] = races.map { race in
            var race = race
            race["seats"] = (race["seats"] as? [[String: Any]])?.map { $0.filter { $0.key != "handling" } }
            return race
        }
        old["axes"] = nil
        let decoded = try JSONDecoder().decode(BotSuiteReport.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.races.first?.seats.allSatisfy { $0.handling == nil } == true && decoded.axes == nil)
    }

    /// #435: `--profile-mix handling --autohelm off` sails the handling mix's four profiles in all-National fleets on an
    /// autohelm-off copy of the class, out of the live tiers' gate; the copy is the bundled class but for the autohelm.
    @Test func handlingMixSailsByHandWithTheAutohelmOff() throws {
        let options = try BotSuiteOptions(arguments: ["--profile-mix", "handling", "--autohelm", "off", "--seeds", "2",
                                                      "--fleet-size", "5"])
        #expect(options.autohelmOff == true)
        let matrix = try options.matrix()
        #expect(matrix.autohelmOff && matrix.profileMixes == [.handling])
        #expect(!matrix.cells.isEmpty && matrix.cells.allSatisfy { $0.autohelmOff == true && $0.tierMix == .national })
        #expect(!ProfileMix.handling.gatesLiveTiers)
        let cell = try #require(matrix.cells.first)
        #expect(Set((0..<4).compactMap(cell.profile(ofSeat:))) == Set(ProfileMix.handlingProfiles))
        #expect(try BotSuiteOptions(arguments: ["--autohelm", "on"]).autohelmOff == false)
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--autohelm", "sideways"]) }

        let bundled = RaceFiles.defaults.boatClass
        let copy = try BotRaceHarness.handSteered(bundled)
        #expect(!copy.content.steering.autohelm.holdsWhenCentred)
        var held = copy.content
        held.steering.autohelm.holdsWhenCentred = true
        #expect(held == bundled.content && copy.ref != bundled.ref)
        let setup = try BotRaceHarness.raceSetup(for: cell)
        #expect(setup.boatClass == copy.ref)
    }

    /// #435: the handling mix measures hand steering, which shows only with the autohelm off, and deals four profiles
    /// by turns, so a matrix naming it without `autohelmOff`, or sailing it in a fleet under four, fails loudly.
    @Test func handlingMixNeedsTheAutohelmOffAndFleetsOfFour() throws {
        try BotMatrix(seeds: [1], fleetSizes: [5], tierMixes: [.national], profileMixes: [.handling], autohelmOff: true).validate()
        #expect(throws: BotSuiteError.self) {
            try BotMatrix(seeds: [1], fleetSizes: [5], tierMixes: [.national], profileMixes: [.handling]).validate()
        }
        for size in [2, 3] {
            #expect(throws: BotSuiteError.self) {
                try BotMatrix(seeds: [1], fleetSizes: [size, 10], tierMixes: [.national], profileMixes: [.live, .handling],
                              autohelmOff: true).validate()
            }
        }
        // A small fleet the handling mix doesn't sail in (`mixFleetSizes`) is no matter.
        try BotMatrix(seeds: [1], fleetSizes: [2, 10], tierMixes: [.national], profileMixes: [.live, .handling],
                      mixFleetSizes: [.handling: 10], autohelmOff: true).validate()
        #expect(throws: BotSuiteError.self) {
            try BotSuiteOptions(arguments: ["--profile-mix", "handling", "--fleet-size", "5"]).matrix()
        }
        #expect(throws: BotSuiteError.self) {
            try BotSuiteOptions(arguments: ["--profile-mix", "handling", "--autohelm", "off", "--fleet-size", "2"]).matrix()
        }
    }

    @Test func unknownArgumentIsAUsageError() throws {
        #expect(try botsuite(["--nope"]).status == 2)
    }
    #endif
}
