@testable import BotSuite
import Foundation
import Testing

@Suite struct BotSuiteGateTests {
    private func seat(_ tier: BotTier, finished: Bool = true, irons: Double = 0, marks: Int = 0, contacts: Int = 0,
                      fouls: Int = 0, edge: Double = 0) -> SeatMetrics {
        SeatMetrics(seat: 0, tier: tier, skill: 0.5, status: finished ? "finished" : "dnf", finished: finished,
                    place: finished ? 1 : nil, ironsSeconds: irons, markContacts: marks, boatContacts: contacts,
                    contactsEndingInFouls: fouls, contactsToFoulsShare: share(fouls, of: contacts), foulsAsOffender: 0,
                    dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: edge, landContacts: 0, boundaryContacts: 0)
    }

    /// #19's limits, each on its own: finish share, irons, mark contact, contacts to fouls, the edge;
    /// and #27's tick.
    @Test func eachLimitBreachesOnItsOwn() {
        let limits = TierLimits(minFinishShare: 0.5, maxMeanIronsSeconds: 10, maxMeanMarkContacts: 1,
                                maxContactsToFoulsShare: 0.1, maxMeanEdgeSeconds: 5)
        let thresholds = BotThresholds(tiers: ["national": limits], maxP99TickMs: 5)
        let calm = BotSuiteReport.RunTimings(maxP99Ms: 5, maxMs: 9)
        func breaches(_ seats: [SeatMetrics], timings: BotSuiteReport.RunTimings = calm) -> [String] {
            thresholds.breaches(tiers: ["national": TierSummary(seats)], timings: timings)
        }
        #expect(breaches([seat(.national), seat(.national, finished: false)]).isEmpty, "limits are inclusive")
        #expect(breaches([seat(.national, finished: false), seat(.national, finished: false), seat(.national)]).count == 1)
        #expect(breaches([seat(.national, irons: 21)]).count == 1)
        #expect(breaches([seat(.national, marks: 2), seat(.national, marks: 1)]).count == 1)
        #expect(breaches([seat(.national, contacts: 10, fouls: 2)]).count == 1)
        #expect(breaches([seat(.national, edge: 6)]).count == 1)
        #expect(breaches([seat(.national)], timings: .init(maxP99Ms: 5.01, maxMs: 9)) == ["tick: worst p99 5.010 ms > 5.000"])
        #expect(breaches([seat(.national, finished: false, irons: 99, marks: 9, contacts: 1, fouls: 1, edge: 99)]).count == 5)
        // A tier with no limits isn't gated.
        #expect(thresholds.breaches(tiers: ["club": TierSummary([seat(.club, finished: false)])], timings: calm).isEmpty)
    }

    @Test func bundledThresholdsGateEveryTier() throws {
        let thresholds = try BotThresholds.bundled()
        #expect(Set(thresholds.tiers.keys) == Set(BotTier.allCases.map(\.rawValue)))
        #expect(thresholds.maxP99TickMs > 0)
        var pro = unmissableThresholds()
        pro.tiers["pro"] = pro.tiers["club"]
        let unknown = try fixture(pro, named: "unknown-tier")
        #expect(throws: BotSuiteError.self) { try BotThresholds.load(from: URL(fileURLWithPath: unknown)) }
    }

    #if os(macOS) || os(Linux)
    /// #97 acceptance: a run that misses the thresholds exits non-zero, and one that meets them exits 0.
    @Test func thresholdBreachExitsNonZero() throws {
        let matrix = try fixture(BotMatrix(seeds: [3], fleetSizes: [2], tierMixes: [.club], laps: 1, capSecondsAfterGun: 60), named: "matrix")

        let failing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(impossibleThresholds(), named: "impossible")])
        #expect(failing.status == 1)
        #expect(failing.stdout.contains("gate: FAIL"))
        #expect(failing.stdout.contains("club: finish share"))

        let passing = try botsuite(["--matrix", matrix, "--thresholds", try fixture(unmissableThresholds(), named: "unmissable")])
        #expect(passing.status == 0)
        #expect(passing.stdout.contains("gate: pass"))
    }
    #endif
}
