import Foundation
import Testing
import RegattaCore
import VenueTools

/// The offline venue checks (#83) over the shipped venues, and a fixture each one must fail.
@Suite struct VenueOfflineCheckTests {
    /// #12's launch table: each venue with its two conditions.
    static let shippedPairings = [
        "hollin-bay@1 × classic-oscillating@2", "hollin-bay@1 × sea-breeze@2",
        "saltings-reach@1 × classic-oscillating@2", "saltings-reach@1 × gusty-offshore@2",
        "fellmere@1 × light-and-patchy@2", "fellmere@1 × gusty-offshore@2",
    ]

    @Test func offlineCheckPassesForAllSixBundledPairings() throws {
        let pairings = try ShippedVenues.pairings()
        #expect(pairings.map(\.name) == Self.shippedPairings)
        for pairingCase in pairings {
            #expect(VenueOfflineCheck.problems(pairingCase) == [], "\(pairingCase.name)")
        }
    }

    @Test func offlineCheckFailsWhenLandIsInsideTheRaceArea() throws {
        let venue = try VenueFile.bundled(id: "land-in-race-area", version: 1, in: .module)
        let pairingCase = try VenuePairingCase(venue: venue, conditions: .bundled(id: "classic-oscillating", version: 2))
        let problems = VenueOfflineCheck.problems(pairingCase)
        #expect(problems.first == "land-in-race-area@1 × classic-oscillating@2: land 0 reaches into the race area, at -10.0°")
        // The shortest course's windward and offset marks are on the island too; nothing else is wrong.
        #expect(problems.allSatisfy { $0.contains(": land 0 ") })
    }

    /// The shortest course's race area sits inside the longest's, both laid from the same anchor.
    @Test func longestCourseHoldsTheShortest() throws {
        for pairingCase in try ShippedVenues.pairings() {
            // #14: "Venues must fit a beat of about 360 m": every pairing's longest is the cap.
            #expect(pairingCase.longestBeat == pairingCase.rules.raceFormat.beatSizing.maxMetres)
            #expect(pairingCase.shortestBeat < pairingCase.longestBeat)
            for rotation in [-WindSetup.meanDirectionSpread, 0, WindSetup.meanDirectionSpread] {
                let longest = pairingCase.longestCourse(rotation: rotation)
                let shortest = pairingCase.shortestCourse(rotation: rotation)
                #expect(longest.startLine.centre == pairingCase.pairing.startLineCentre)
                #expect(shortest.raceArea.corners.allSatisfy { longest.raceArea.inset($0) >= -1e-9 }, "\(pairingCase.name)")
            }
        }
    }

    @Test func rotationsSpanTheSeededSpreadBothEndsIncluded() {
        let rotations = VenuePairingCase.rotations(step: VenueOfflineCheck.rotationStep)
        #expect(rotations.count == 41)
        #expect(rotations.first == -WindSetup.meanDirectionSpread)
        #expect(abs(rotations.last! - WindSetup.meanDirectionSpread) < 1e-12)
    }

    /// The estuary's channel and shallows are inside every race area; a venue with no current has neither
    /// to check.
    @Test func estuaryIsTheOnlyVenueWithCurrent() throws {
        let venues = try ShippedVenues.keys.map { try VenueFile.bundled(id: $0.id, version: $0.version).content }
        #expect(venues.map(\.hasCurrent) == [false, true, false])
        let estuary = try #require(venues[1].current)
        #expect(estuary.isTidal)
        #expect(knots(metresPerSecond: estuary.peak) == 2)
    }
}
