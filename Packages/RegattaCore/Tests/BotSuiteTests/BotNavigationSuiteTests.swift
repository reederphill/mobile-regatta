@testable import BotSuite
import RegattaBots
import Foundation
import RegattaCore
import Testing

/// #100: the bots' course navigation, over the fleets its acceptance names: all-National fleets of live bots at every
/// available venue in every conditions it pairs with. Their numbers (`NavigationSummary`) are gated by the thresholds'
/// `navigation` limits, the suite thresholds file's v1 placeholders: finish share, disqualifications for a missed
/// penalty, time at the race area's edge, and mark contacts.
///
/// The fleets themselves are too many full races for `swift test`: the full run is the CLI's, over the bundled matrix,
///
///     scripts/heavy.sh swift run -c release --package-path Packages/RegattaCore regatta-botsuite \
///         --tier-mix national --profile-mix live
///
/// which exits 1 when they miss the limits. These tests hold that run to the acceptance: that it sails what the
/// acceptance names, and that its gate counts and breaches as the acceptance says.
@Suite struct BotNavigationSuiteTests {
    /// The CLI's options for the full navigation run.
    static let fullRun = ["--tier-mix", "national", "--profile-mix", "live"]

    /// Every venue this build ships, at its latest version, as `id@version`.
    static func availableVenues() -> [String] {
        let latest = Dictionary(VenueFile.bundledKeys().map { ($0.id, $0.version) }, uniquingKeysWith: max)
        return latest.map { "\($0.key)@\($0.value)" }.sorted()
    }

    /// A seat of a race: finished unless not, with the given penalty disqualifications, seconds at the edge of the
    /// seconds on the water, and mark contacts.
    private func seat(_ seat: Int, finished: Bool = true, dsq: Int = 0, edge: Double = 0, onCourse: Double = 600,
                      marks: Int = 0) -> SeatMetrics {
        SeatMetrics(seat: seat, tier: .national, skill: 0.9, status: finished ? "finished" : dsq > 0 ? "dsq" : "racing",
                    finished: finished, place: finished ? seat + 1 : nil, ironsSeconds: 0, markContacts: marks, boatContacts: 0,
                    contactsEndingInFouls: 0, contactsToFoulsShare: 0, foulsAsOffender: 0, dsqMissedPenalty: dsq, ocsCount: 0,
                    edgeSeconds: edge, landContacts: 0, boundaryContacts: 0, onCourseSeconds: onCourse)
    }

    private func race(_ seats: [SeatMetrics], venue: String = "dev-venue@3", conditions: String = "classic-oscillating@3",
                      mix: TierMix = .national, profiles: ProfileMix = .live) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: venue, conditions: conditions, tideStateDegrees: 0, fleetSize: seats.count,
                               tierMix: mix, profileMix: profiles, laps: 2, capSecondsAfterGun: BotMatrix.defaultCapSecondsAfterGun)
        return RaceResult(cell: cell, finalTick: 0, capped: false, tideStateAtGun: nil, seats: seats,
                          ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
    }

    /// #100 acceptance: all-National fleets, at every available venue in every conditions it pairs with, sail the
    /// course cleanly: a finish share of at least 98 %, no disqualification for a missed penalty, at most 2 % of their
    /// time at the race area's edge, and at most 0.2 mark contacts per boat per race. The fleets are the CLI's full
    /// run (above): its matrix sails exactly those pairings, all-National live fleets only, and the bundled thresholds
    /// gate it on those four numbers, each inclusive, each breaching on its own.
    @Test func nationalFleetsSailEveryPairingCleanly() throws {
        // The full run sails every available venue × conditions pairing, with all-National live fleets only.
        let matrix = try BotSuiteOptions(arguments: Self.fullRun).matrix()
        var pairings: Set<String> = []
        for venue in Self.availableVenues() {
            let key = try dataFileKey(venue)
            for pairing in try VenueFile.bundled(id: key.id, version: key.version).content.pairings {
                pairings.insert("\(venue) × \(pairing.conditions.id)@\(pairing.conditions.version)")
            }
        }
        #expect(!pairings.isEmpty)
        let cells = matrix.cells
        #expect(Set(cells.map { "\($0.venue) × \($0.conditions)" }) == pairings, "the full run sails every pairing, and only those")
        #expect(cells.allSatisfy { $0.tierMix == .national && $0.profileMix == .live })
        #expect(Set(cells.map(\.fleetSize)) == Set(try BotMatrix.bundled().fleetSizes), "every fleet size the matrix names")
        // Two laps or more: the final run passes the gate's marks, which she keeps off as obstructions.
        #expect(matrix.laps >= 2 && matrix.capSecondsAfterGun == BotMatrix.defaultCapSecondsAfterGun)

        // The bundled thresholds gate it on the acceptance's numbers.
        let thresholds = try BotThresholds.bundled()
        let limits = try #require(thresholds.navigation)
        #expect(limits == NavigationLimits(minFinishShare: 0.98, maxDSQMissedPenalty: 0, maxEdgeShare: 0.02,
                                           maxMarkContactsPerBoat: 0.2))

        // A run that meets them passes, at the limits too; each one missed fails it on its own (the tiers' own limits,
        // #102's to tighten, left out).
        let gate = BotThresholds(tiers: [:], navigation: limits, maxP99TickMs: .greatestFiniteMagnitude)
        func report(_ seats: [SeatMetrics]) -> BotSuiteReport {
            // Fifty boats over every pairing: one in fifty is 2 %.
            let perPairing = seats.count / pairings.count
            let races = pairings.sorted().enumerated().map { index, pairing in
                let parts = pairing.components(separatedBy: " × ")
                let last = index == pairings.count - 1 ? seats.count : (index + 1) * perPairing
                return race(Array(seats[(index * perPairing)..<last]), venue: parts[0], conditions: parts[1])
            }
            return BotSuiteReport(matrix: matrix, thresholds: gate, races: races)
        }
        let fleet = (0..<50).map { seat($0) }
        let clean = report(fleet)
        #expect(clean.navigation?.pairings.count == pairings.count)
        #expect(clean.passed, "\(clean.breaches)")
        var atTheLimits = fleet
        atTheLimits[0] = seat(0, finished: false)
        atTheLimits[1] = seat(1, edge: 600 * 50 * 0.02)
        for i in 2..<12 { atTheLimits[i] = seat(i, marks: 1) }
        #expect(report(atTheLimits).passed, "limits are inclusive: \(report(atTheLimits).breaches)")

        var slow = fleet
        slow[0] = seat(0, finished: false)
        slow[1] = seat(1, finished: false)
        #expect(report(slow).breaches == ["navigation: finish share 0.960 < 0.980"])
        var disqualified = fleet
        disqualified[3] = seat(3, finished: false, dsq: 1)
        #expect(report(disqualified).breaches == ["navigation: dsq for a missed penalty 1 > 0"])
        var edgy = fleet
        edgy[4] = seat(4, edge: 600 * 50 * 0.021)
        #expect(report(edgy).breaches == ["navigation: edge 0.0210 of the time > 0.0200"])
        var marked = fleet
        marked[5] = seat(5, marks: 11)
        #expect(report(marked).breaches == ["navigation: mark contacts 0.220/boat/race > 0.200"])
    }

    /// The summary is taken over the all-National live fleets only, every size, venue and conditions: finish share,
    /// missed-penalty disqualifications, edge time as a share of time on the water, and mark contacts per boat per race.
    @Test func navigationSummaryCountsTheAllNationalLiveFleets() throws {
        let light = race([seat(0, edge: 30, onCourse: 500, marks: 1), seat(1, finished: false, dsq: 1, edge: 0, onCourse: 100)],
                         conditions: "light-and-patchy@3")
        let gusty = race([seat(0, edge: 10, onCourse: 400), seat(1), seat(2, marks: 2)], conditions: "gusty-offshore@3")
        let mixed = race([seat(0, finished: false, dsq: 3, edge: 99, marks: 9)], mix: .mixed)
        let skillGap = race([seat(0, finished: false, dsq: 3, edge: 99, marks: 9)], profiles: .skillGap)
        let summary = try #require(NavigationSummary([light, gusty, mixed, skillGap]))
        #expect(summary.races == 2 && summary.seats == 5)
        #expect(summary.pairings == ["dev-venue@3 × gusty-offshore@3", "dev-venue@3 × light-and-patchy@3"])
        #expect(summary.finishShare == 4.0 / 5)
        #expect(summary.dsqMissedPenalty == 1)
        #expect(summary.edgeShare == 40.0 / 2_200)
        #expect(summary.markContactsPerBoat == 3.0 / 5)
        #expect(NavigationSummary([mixed, skillGap]) == nil, "no all-National live fleet sailed")
        #expect(try #require(NavigationSummary([race([seat(0, onCourse: 0)])])).edgeShare == 0)
    }

    /// Each navigation limit breaches on its own, and only for a run that sailed an all-National live fleet; a
    /// thresholds file from before #100 has none, and gates none.
    @Test func navigationLimitsBreachOnlyARunThatSailedTheFleets() throws {
        var thresholds = unmissableThresholds()
        thresholds.navigation = NavigationLimits(minFinishShare: 0.98, maxDSQMissedPenalty: 0, maxEdgeShare: 0.02,
                                                 maxMarkContactsPerBoat: 0.2)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 1, maxMs: 1)
        let summary = try #require(NavigationSummary([race([seat(0, finished: false, dsq: 2, edge: 300, marks: 4)])]))
        #expect(thresholds.breaches(tiers: [:], timings: calm, navigation: summary).count == 4)
        #expect(thresholds.breaches(tiers: [:], timings: calm, navigation: nil).isEmpty, "no all-National live fleet sailed")
        thresholds.navigation = NavigationLimits(maxDSQMissedPenalty: 0)
        #expect(thresholds.breaches(tiers: [:], timings: calm, navigation: summary) == ["navigation: dsq for a missed penalty 2 > 0"])
        let old = try JSONDecoder().decode(BotThresholds.self, from: Data(#"{"maxP99TickMs": 10, "tiers": {}}"#.utf8))
        #expect(old.navigation == nil)
    }

    #if os(macOS) || os(Linux)
    /// The CLI's JSON report gives navigation for an all-National live fleet, and each seat's time on the water, which
    /// holds her time at the edge.
    @Test func reportGivesNavigation() throws {
        let matrix = BotMatrix(seeds: [1], fleetSizes: [2], tierMixes: [.national], laps: 1, capSecondsAfterGun: 60)
        let run = try botsuite(["--matrix", try fixture(matrix, named: "navigation-matrix"),
                                "--thresholds", try fixture(unmissableThresholds(), named: "unmissable"), "--json", "-"])
        #expect(run.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let navigation = try #require(object["navigation"] as? [String: Any])
        for key in ["races", "seats", "pairings", "finishShare", "dsqMissedPenalty", "edgeShare", "markContactsPerBoat"] {
            #expect(navigation[key] != nil, "navigation has no \(key)")
        }
        let report = try JSONDecoder().decode(BotSuiteReport.self, from: Data(run.stdout.utf8))
        #expect(report.navigation?.races == 1 && report.navigation?.seats == 2)
        #expect(report.navigation?.pairings == ["dev-venue@3 × classic-oscillating@3"])
        let race = try #require(report.races.first)
        let sequence = Double(RaceSetup.defaultStartSequenceTicks) / Double(Race.tickRate)
        for seat in race.seats {
            #expect(seat.onCourseSeconds > sequence && seat.onCourseSeconds <= sequence + race.raceSeconds + 1,
                    "seat \(seat.seat) on the water \(seat.onCourseSeconds) s")
            #expect(seat.edgeSeconds <= seat.onCourseSeconds)
        }
    }
    #endif
}
