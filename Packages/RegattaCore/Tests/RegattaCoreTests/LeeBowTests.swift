import Foundation
import Testing
@testable import RegattaCore

/// #298 acceptance: a lee-bow pays. A boat on port tacks onto the lee bow of a boat close-hauled on starboard, so the
/// starboard boat sits in her backwind (to windward of her and astern, `ShadowCone`'s trapezoid), and loses speed
/// against a twin sailing on with no lee-bower. Twin races in open water and a steady wind (`OpenWater`, the default
/// class). What she loses is set by the class's placeholder backwind loss (skiff@4, #232's slider), and sized so a
/// lee-bow costs clearly less than sitting in a wind shadow (`ShadowCostTests`: 0.7–1.5 L over 5 s).
@Suite struct LeeBowTests {
    let knots = 10.0
    var hullLength: Double { OpenWater.hullLength }

    /// Seat 0 close-hauled on starboard (`OpenWater.race`); seat 1 close-hauled on port `ahead` hull lengths ahead of
    /// her and `leeward` to leeward, in her frame, about to tack onto her lee bow. With `together` false seat 1 is
    /// 400 m further to leeward, out of her way.
    func race(ahead: Double, leeward: Double, together: Bool) throws -> Race {
        try OpenWater.race(knots: knots) { snapshot, _ in
            let starboard = snapshot.seats[0].boat
            // Her leeward side is to port on starboard tack.
            let toLeeward = -starboard.forward.rightPerp
            var position = starboard.position + (starboard.forward * ahead + toLeeward * leeward) * hullLength
            if !together { position += toLeeward * 400 }
            let best = OpenWater.boatClass.polar.bestUpwind(tws: starboard.windSpeed)
            snapshot.seats[1].boat.position = position
            snapshot.seats[1].boat.heading = wrapAngle(starboard.windDirection + best.twa)
            snapshot.seats[1].boat.speed = starboard.speed
            snapshot.seats[1].boat.boomSide = .starboard
            snapshot.seats[1].boat.rudder = 0
            snapshot.seats[1].boat.desiredRudder = 0
            snapshot.seats[1].heldInput = .neutral
        }
    }

    /// Seat 1 starts 3 L ahead of seat 0 and 1.5 L to leeward on port and tacks at once; she is on starboard about
    /// 1.6 L ahead of her and 0.6 L to leeward when her tack ends, seat 0 in her backwind from there on. At 10 kn
    /// seat 0 loses 0.36 L in the next 5 s against her twin with skiff@4's placeholder loss (0.2): a lee-bow pays,
    /// but less than 5 s in a wind shadow (1.2–1.5 L, `ShadowCostTests`).
    @Test func leeBowedBoatLosesSpeedAgainstACleanTwin() throws {
        let (ahead, leeward) = (3.0, 1.5)
        let leeBowed = try race(ahead: ahead, leeward: leeward, together: true)
        let clean = try race(ahead: ahead, leeward: leeward, together: false)
        // One step so both autohelms engage on their grooves, then seat 1 tacks.
        leeBowed.step()
        clean.step()
        leeBowed.tap(.tackGybe, seat: 1, atTick: leeBowed.tick + 1)
        clean.tap(.tackGybe, seat: 1, atTick: clean.tick + 1)
        for _ in 0..<(10 * Race.tickRate) {
            leeBowed.step()
            clean.step()
            if leeBowed.boats[1].boomSide == .port && !leeBowed.boats[1].isTacking { break }
        }
        let lee = leeBowed.boats[1]
        #expect(!lee.isTacking && lee.tack == .starboard, "she has tacked onto starboard, seat 0's tack")
        let offset = leeBowed.boats[0].position - lee.position
        let (astern, toWindward) = (-offset.dot(lee.forward) / hullLength, offset.dot(lee.forward.rightPerp) / hullLength)
        #expect(astern > 1 && astern < 2.5 && toWindward > 0 && toWindward < 1.2,
                "the lee-bowed boat is \(astern) L astern of her and \(toWindward) L to windward")
        let cone = try #require(leeBowed.shadowCone(ofSeat: 1))
        #expect(cone.isInBackwind(leeBowed.boats[0].position), "in her backwind")
        #expect(cone.factor(at: leeBowed.boats[0].position) == cone.backwindFactor(at: leeBowed.boats[0].position),
                "and not in her cone")

        // 5 s from there, against the twin.
        let (from, twinFrom) = (leeBowed.boats[0].position, clean.boats[0].position)
        let course = leeBowed.boats[0].heading
        var backwindedTicks = 0
        for _ in 0..<(5 * Race.tickRate) {
            leeBowed.step()
            clean.step()
            if leeBowed.boats[0].shadow < 1 { backwindedTicks += 1 }
            #expect(clean.boats[0].shadow == 1)
        }
        #expect(backwindedTicks == 5 * Race.tickRate, "backwinded \(backwindedTicks) of \(5 * Race.tickRate) ticks")
        #expect(!leeBowed.drainEvents().contains { if case .ruleCall = $0.kind { true } else { false } }, "no contact, no call")
        let madeGood = (leeBowed.boats[0].position - from).dot(.heading(course))
        let twinMadeGood = (clean.boats[0].position - twinFrom).dot(.heading(course))
        let lost = (twinMadeGood - madeGood) / hullLength
        #expect(lost >= 0.3 && lost <= 0.6, "5 s lee-bowed cost \(lost) L")
    }
}
