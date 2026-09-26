import Foundation
import Testing
import RegattaCore
import VenueTools

/// The offline sailability check (#11, #14, #83): every shipped pairing, a 25 % lull at peak current.
@Suite struct VenueSailabilityTests {
    @Test func sailabilityPassesForAllSixPairings() throws {
        let pairings = try ShippedVenues.pairings()
        #expect(pairings.count == 6)
        for pairingCase in pairings {
            let report = VenueSailability.report(pairingCase)
            #expect(report.passes, "\(pairingCase.name): \(report.summary)")
        }
    }

    /// With no current, progress is the polar's best upwind VMG in the lulled wind and the grid's factor.
    @Test func progressWithoutCurrentIsTheLulledVMG() throws {
        let pairingCase = try #require(try ShippedVenues.pairings().first { $0.venue.ref.id == "fellmere" })
        let strength = VenueSailability.lulledStrength(pairingCase)
        #expect(strength == pairingCase.conditions.content.strength.lowerBound * 0.75)
        let p = pairingCase.pairing.startLineCentre
        let factor = pairingCase.pairing.geographicGrid.sample(p).speedFactor
        let made = VenueSailability.progress(at: p, axis: pairingCase.pairing.meanDirection, strength: strength,
                                             pairingCase: pairingCase, tidePeak: nil)
        #expect(made == pairingCase.boatClass.polar.bestUpwind(tws: strength * factor).vmg)
    }

    /// In the estuary's channel the flood and the ebb take the current off and add it to the boat's VMG,
    /// run along the course by classic oscillating's wind, which blows down the reach.
    @Test func estuaryChannelCurrentRunsDownAndUpTheCourse() throws {
        let pairingCase = try #require(try ShippedVenues.pairings().first { $0.name == "saltings-reach@1 × classic-oscillating@2" })
        let strength = VenueSailability.lulledStrength(pairingCase)
        let p = pairingCase.pairing.startLineCentre
        let axis = pairingCase.pairing.meanDirection
        let still = VenueSailability.progress(at: p, axis: axis, strength: strength, pairingCase: pairingCase, tidePeak: nil)
        let flood = VenueSailability.progress(at: p, axis: axis, strength: strength, pairingCase: pairingCase, tidePeak: .pi / 2)
        let ebb = VenueSailability.progress(at: p, axis: axis, strength: strength, pairingCase: pairingCase, tidePeak: 3 * .pi / 2)
        #expect(flood < still - metresPerSecond(knots: 1.5))
        #expect(ebb > still + metresPerSecond(knots: 1.5))
        #expect(flood > 0)
    }
}
