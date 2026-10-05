import Foundation
import Testing
@testable import RegattaCore

/// #298 acceptance: a lee-bow pays. A boat on port tacks onto the lee bow of a boat close-hauled on starboard, so the
/// starboard boat sits in her backwind (to windward of her; since #377 the upwash beside her sail and astern), and loses speed
/// against a twin sailing on with no lee-bower. Twin races in open water and a steady wind (`OpenWater`, the default
/// class). What she loses is set by the class's placeholder backwind loss (skiff@4, #232's slider), and sized so a
/// lee-bow costs clearly less than sitting in a wind shadow (`ShadowCostTests`: 0.7–1.5 L over 5 s).
@Suite struct LeeBowTests {
    let knots = 10.0
    var hullLength: Double { OpenWater.hullLength }

    /// Seat 0 close-hauled on starboard (`OpenWater.race`); seat 1 close-hauled on port `ahead` hull lengths ahead of
    /// her and `leeward` to leeward, in her frame, about to tack onto her lee bow. With `together` false seat 1 is
    /// 400 m further to leeward, out of her way.
    func race(ahead: Double, leeward: Double, together: Bool, boatClassFile: BoatClassFile? = nil) throws -> Race {
        try OpenWater.race(knots: knots, boatClassFile: boatClassFile) { snapshot, _ in
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
    /// 1.6 L ahead of her and 0.6 L to leeward when her tack ends. Since #377 (skiff@6) the backwind is a header (8°, a
    /// 1 s lag) and its zone is the upwash beside her sail, from her mast back past her stern to 1.5 L astern of it and
    /// 1 L out to windward (the owner's renders review, then his lengthening): seat 0 is in it from the end of the tack
    /// and on every tick of the next 10 s, astern of the lee-bower or beside her. Holding her heading (her autohelm
    /// pinches through the header rather than bearing away onto the lee-bower's stern, so she keeps clear), she pays in
    /// pinching. Her loss is measured upwind over 10 s.
    ///
    /// The reshape without the run astern moved this scene to 2.5 L ahead (from 3 L seat 0 never reached a zone that
    /// ended at the lee-bower's stern) and to "in the zone 4 s or more"; the lengthening brings back the 3 L lee-bow
    /// and "every tick". The loss band (0.6–1.2 L) is unchanged.
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

        // 10 s from there, against the twin.
        let (from, twinFrom) = (leeBowed.boats[0].position, clean.boats[0].position)
        // Upwind: since #377 the backwind is a header, so she loses height as well as speed.
        let course = try OpenWater.windDirection()
        #expect(try #require(leeBowed.shadowCone(ofSeat: 1)).isInBackwind(leeBowed.boats[0].position), "in her backwind")
        var inZoneTicks = 0
        for _ in 0..<(10 * Race.tickRate) {
            leeBowed.step()
            clean.step()
            let zone = try #require(leeBowed.shadowCone(ofSeat: 1))
            if zone.isInBackwind(leeBowed.boats[0].position) {
                inZoneTicks += 1
                // Beside her or astern of her, between her mast and the zone's aft end, and to windward: the upwash zone.
                let off = leeBowed.boats[0].position - leeBowed.boats[1].position
                let along = off.dot(leeBowed.boats[1].forward)
                let extent = try #require(leeBowed.boatClass.windShadow.upwashExtent)
                #expect(along > extent.aft && along < extent.fore)
                #expect(off.dot(leeBowed.boats[1].forward.rightPerp) > 0)
            }
            #expect(clean.boats[0].shadow == 1 && clean.header(ofSeat: 0) == 0)
        }
        #expect(inZoneTicks == 10 * Race.tickRate, "in her backwind \(inZoneTicks) of \(10 * Race.tickRate) ticks")
        let events = leeBowed.drainEvents()
        // She keeps clear (#377): her autohelm never follows the header down onto the lee-bower's stern.
        #expect(!events.contains { if case .ruleCall = $0.kind { true } else { false } }, "no contact, no call")
        let madeGood = (leeBowed.boats[0].position - from).dot(.heading(course))
        let twinMadeGood = (clean.boats[0].position - twinFrom).dot(.heading(course))
        let lost = (twinMadeGood - madeGood) / hullLength
        #expect(lost >= 0.6 && lost <= 1.2, "10 s lee-bowed cost \(lost) L upwind")
    }

    /// The lee-bow's cost in distance made good (#376's measure, `LeeBowTests`' geometry, 3 L ahead and 1.5 L to leeward):
    /// seat 0's distance made good upwind over the 20 s from the end of seat 1's tack, lost against the clean twin, in the
    /// default class (skiff@6: ribbons, header 8°) and in a tuned copy whose header turns nothing (0°; at lull 0 the
    /// backwind then costs nothing, so what is left is the ribbons and the tack). The owner's reference (#377, from
    /// #376): today's box cost 1.50 L, and the header about +5% of it. Print only, under the fleet runs' switch
    /// (`ShadowModelFleetTests`, `REGATTA_SHADOW_FLEET=1`). Since the header's zone is the upwash beside the lee-bower's
    /// sail, run on 1.5 L astern of her stern, the 3 and 3.25 L geometries sit seat 0 in its run astern, fading towards its
    /// end; 2.5 and 2.25 L are the overlapped lee-bows, nearer her side.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGATTA_SHADOW_FLEET"] == "1"))
    func leeBowCostOverTwentySeconds() throws {
        let data = try #require(try BoatClassFile.bundledData(id: "skiff", version: 6))
        let text = String(decoding: data, as: UTF8.self)
        let header = #""header": { "degrees": 8,"#
        #expect(text.contains(header))
        let unheaded = try BoatClassFile(data: Data(text.replacingOccurrences(of: header, with: #""header": { "degrees": 0,"#).utf8),
                                         tune: 1)
        let box = 1.50
        let course = try OpenWater.windDirection()
        for (ahead, leeward) in [(3.0, 1.5), (3.25, 1.5), (2.5, 1.5), (2.25, 1.5)] {
            var lost: [String: (at5: Double, at20: Double, cleanDMG: Double, calls: Int, headed: Int)] = [:]
            for (name, file) in [("header 8°", nil), ("header 0°", unheaded)] as [(String, BoatClassFile?)] {
                let leeBowed = try race(ahead: ahead, leeward: leeward, together: true, boatClassFile: file)
                let clean = try race(ahead: ahead, leeward: leeward, together: false, boatClassFile: file)
                leeBowed.step()
                clean.step()
                leeBowed.tap(.tackGybe, seat: 1, atTick: leeBowed.tick + 1)
                clean.tap(.tackGybe, seat: 1, atTick: clean.tick + 1)
                for _ in 0..<(10 * Race.tickRate) {
                    leeBowed.step()
                    clean.step()
                    if leeBowed.boats[1].boomSide == .port && !leeBowed.boats[1].isTacking { break }
                }
                _ = leeBowed.drainEvents()
                let (from, twinFrom) = (leeBowed.boats[0].position, clean.boats[0].position)
                var at5 = 0.0, headed = 0
                for tick in 1...(20 * Race.tickRate) {
                    leeBowed.step()
                    clean.step()
                    if leeBowed.header(ofSeat: 0) > 0 { headed += 1 }
                    if tick == 5 * Race.tickRate {
                        at5 = (OpenWater.madeGood(clean, from: twinFrom, direction: course)
                               - OpenWater.madeGood(leeBowed, from: from, direction: course)) / hullLength
                    }
                }
                let twin = OpenWater.madeGood(clean, from: twinFrom, direction: course)
                let at20 = (twin - OpenWater.madeGood(leeBowed, from: from, direction: course)) / hullLength
                let calls = leeBowed.drainEvents().filter { if case .ruleCall = $0.kind { true } else { false } }.count
                lost[name] = (at5, at20, twin / hullLength, calls, headed)
            }
            for name in ["header 8°", "header 0°"] {
                let l = lost[name]!
                print(String(format: "LEE-BOW %.2f L ahead, %.2f L to leeward, %@: DMG lost at 5 s %.3f L, over 20 s %.3f L "
                             + "(%.1f%% of the clean twin's %.2f L; %+.0f%% of #376's box %.2f L); rule calls %d; headed %.1f s",
                             ahead, leeward, name, l.at5, l.at20, l.at20 / l.cleanDMG * 100, l.cleanDMG, (l.at20 / box - 1) * 100, box, l.calls,
                             Double(l.headed) / Double(Race.tickRate)))
            }
            let header = lost["header 8°"]!.at20 - lost["header 0°"]!.at20
            print(String(format: "LEE-BOW %.2f L ahead: the header's own cost over 20 s %.3f L (%.1f%% of the clean twin's DMG)",
                         ahead, header, header / lost["header 8°"]!.cleanDMG * 100))
        }
    }
}
