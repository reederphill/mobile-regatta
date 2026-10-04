import Foundation
import Testing
@testable import RegattaCore

/// #298 acceptance: the backwind is a right trapezoid on the caster's windward quarter, astern of her stern. In her
/// frame (x out to windward, y forward, origin at the hull's centre, L the hull length), on ilca-dinghy@4: P1 her
/// windward stern corner (0.63 m, −L/2), P2 = P1 + (1 L, 0), P3 = P2 + (0, −2 L), P4 = P1 + (0, −1.5 L). It follows her
/// heading and her windward side, which flips at the boom crossing (#71).
@Suite struct BackwindZoneTests {
    let boatClass: BoatClass
    var shadow: BoatClass.WindShadow { boatClass.windShadow }
    var length: Double { boatClass.hull.length }

    init() throws {
        boatClass = try BoatClassFile.bundled(id: Fixtures.classID, version: 4).content
    }

    /// A caster at `apex` heading `heading` with the wind over `windward`, the apparent wind on her windward beam (so
    /// her cone streams to leeward, clear of the zone).
    func zone(apex: Vec2 = .zero, heading: Double = 0, windward: Tack = .starboard) -> ShadowCone {
        let wind = heading + (windward == .starboard ? .pi / 2 : -.pi / 2)
        return ShadowCone(apex: apex, apparentWindDirection: wind, heading: heading, windwardSide: windward, shadow: shadow)
    }

    /// The point at `(x, y)` in the caster's frame (x to windward, y forward), with the caster at `apex` on `heading`.
    func point(_ x: Double, _ y: Double, apex: Vec2 = .zero, heading: Double = 0, windward: Tack = .starboard) -> Vec2 {
        let forward = Vec2.heading(heading)
        let out = windward == .starboard ? forward.rightPerp : -forward.rightPerp
        return apex + out * x + forward * y
    }

    @Test func zoneIsARightTrapezoidFromTheWindwardSternCorner() {
        let e = 0.01
        let p1 = Vec2(0.63, -length / 2)
        #expect(shadow.sternCorner == p1 && abs(p1.x / length - 0.15) < 1e-12)
        let p2 = p1 + Vec2(length, 0), p3 = p2 + Vec2(0, -2 * length), p4 = p1 + Vec2(0, -1.5 * length)
        // Off a caster somewhere on the course, heading 30°, so the frame is hers and not the world's.
        let (apex, heading) = (Vec2(120, -40), deg2rad(30))
        let cone = zone(apex: apex, heading: heading)
        // The trapezoid alone (her cone streams the other way, to leeward); `factor(at:)` is the same on this side.
        func factor(_ p: Vec2) -> Double { cone.backwindFactor(at: point(p.x, p.y, apex: apex, heading: heading)) }
        let windwardQuarter = point(p1.x + 0.5 * length, p1.y - 0.5 * length, apex: apex, heading: heading)
        #expect(cone.factor(at: windwardQuarter) == cone.backwindFactor(at: windwardQuarter))

        // Inside: just past P1, and just inside the far edge.
        #expect(factor(p1 + Vec2(e, -e)) < 1 && abs(factor(p1 + Vec2(e, -e)) - (1 - shadow.backwindLoss)) < 1e-3,
                "full loss at the stern edge")
        #expect(factor(p2 + Vec2(-e, -e)) < 1)
        let farMiddle = (p3 + p4) / 2
        #expect(factor(farMiddle + Vec2(0, 2 * e)) < 1 && factor(farMiddle + Vec2(0, 2 * e)) > 1 - 0.01 * shadow.backwindLoss,
                "nearly nothing just inside the far edge")
        #expect(factor(p3 + Vec2(-e, 2 * e)) < 1 && factor(p4 + Vec2(e, 2 * e)) < 1)
        // The loss fades from the stern edge to the far edge.
        #expect(factor(p1 + Vec2(0.5 * length, -0.5 * length)) < factor(p1 + Vec2(0.5 * length, -1.2 * length)))

        // Outside: ahead of the stern, past 2 L, beyond the slanted edge, beyond 1 L out, and on the leeward side.
        #expect(factor(p1 + Vec2(0.5 * length, e)) == 1, "ahead of the stern")
        #expect(factor(Vec2(0, 0)) == 1 && factor(Vec2(p1.x + 0.5 * length, length)) == 1, "alongside and ahead")
        #expect(factor(p3 + Vec2(-e, -e)) == 1, "past 2 L astern")
        #expect(factor(p4 + Vec2(e, -e)) == 1, "past the inner edge's 1.5 L")
        #expect(factor(farMiddle + Vec2(0, -2 * e)) == 1, "beyond the slanted edge")
        #expect(factor(p2 + Vec2(e, -e)) == 1, "beyond 1 L out")
        #expect(factor(Vec2(-p1.x - 0.5 * length, p1.y - 0.5 * length)) == 1, "on the leeward side")
        #expect(factor(Vec2(p1.x - e, p1.y - 0.5 * length)) == 1, "inside the windward corner's line")
    }

    @Test func zoneSwitchesSidesAtTheBoomCrossing() throws {
        // A boat head to wind, turning from starboard tack to port: the zone is on her starboard quarter until
        // the boom crosses, then on her port quarter.
        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: 0, speed: 2, boomSide: .port)
        #expect(boat.tack == .starboard)
        let quarter = (x: shadow.sternCorner.x + 0.5 * length, y: shadow.sternCorner.y - 0.5 * length)
        let starboardQuarter = Vec2(quarter.x, quarter.y), portQuarter = Vec2(-quarter.x, quarter.y)
        let before = ShadowCone(caster: boat, shadow: shadow)
        #expect(before.isInBackwind(starboardQuarter) && !before.isInBackwind(portQuarter))
        boat.boomSide = .starboard
        #expect(boat.tack == .port)
        let after = ShadowCone(caster: boat, shadow: shadow)
        #expect(after.isInBackwind(portQuarter) && !after.isInBackwind(starboardQuarter))
        #expect(after.factor(at: portQuarter) == before.factor(at: starboardQuarter), "mirrored")

        // In a race: a boat tacking carries her zone across at the boom crossing, and only there.
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: 4)
        let race = try placedRace(current: CurrentField(current: nil, tideStateAtGun: 0), boatClass: file.ref) { snapshot, _ in
            var b = snapshot.seats[0].boat
            let best = boatClass.polar.bestUpwind(tws: b.windSpeed)
            b.heading = wrapAngle(b.windDirection - best.twa)
            b.speed = best.speed
            b.boomSide = .port
            b.rudder = 0
            b.desiredRudder = 0
            snapshot.seats[0].boat = b
            snapshot.seats[0].heldInput = .neutral
        }
        race.step()
        race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        var crossed = false
        for _ in 0..<(10 * Race.tickRate) {
            let side = race.boats[0].tack
            race.step()
            let b = race.boats[0]
            let cone = try #require(race.shadowCone(ofSeat: 0))
            let forward = b.forward
            let windwardQuarter = b.position + (b.tack == .starboard ? forward.rightPerp : -forward.rightPerp) * quarter.x
                + forward * quarter.y
            let leewardQuarter = b.position - (b.tack == .starboard ? forward.rightPerp : -forward.rightPerp) * quarter.x
                + forward * quarter.y
            #expect(cone.isInBackwind(windwardQuarter) && !cone.isInBackwind(leewardQuarter))
            if b.tack != side {
                #expect(!crossed, "the side flips once")
                #expect(side == .starboard && b.tack == .port)
                crossed = true
            }
        }
        #expect(crossed, "the boom crossed")
    }

    // MARK: #377: the backwind off a working sail, faded, above a floor speed (skiff@6, the default class)

    /// Through a tack her sail goes head to wind and her windward side flips at the boom crossing (#71). Her backwind
    /// fades out over the class's 1.5 s on the side it was cast on, never jumping across, and once it is gone builds on
    /// the new side over 2 s: no jump either way. The fade follows the class's value (the Debug slider), 0 cutting it.
    @Test func zoneFadesOutOnItsOldSideThenBuildsOnTheNew() throws {
        let race = try LeeBowTests().race(ahead: 3, leeward: 1.5, together: true)
        let shadow = race.boatClass.windShadow
        #expect(shadow.header != nil && shadow.backwindFadeSeconds == 1.5 && shadow.ribbons.buildSeconds == 2)
        race.step()
        let before = try #require(race.backwindSide(ofSeat: 1))
        #expect(race.backwindSail(ofSeat: 1) == 1, "close-hauled, trimmed")
        #expect(before == race.boats[1].tack)
        _ = race.tap(.tackGybe, seat: 1, atTick: race.tick + 1)
        var levels: [Double] = [], sides: [Tack] = [], flip: Int?
        for i in 0..<(8 * Race.tickRate) {
            let side = race.boats[1].boomSide
            race.step()
            levels.append(race.backwindSail(ofSeat: 1))
            sides.append(try #require(race.backwindSide(ofSeat: 1)))
            let zone = try #require(race.shadowCone(ofSeat: 1))
            #expect(zone.backwindSide == sides[i] && zone.backwindSail == levels[i])
            if flip == nil && race.boats[1].boomSide != side { flip = i }
        }
        let f = try #require(flip)
        let rise = Race.dt / shadow.ribbons.buildSeconds, fall = Race.dt / shadow.backwindFadeSeconds
        let swap = try #require(sides.firstIndex { $0 != before })
        #expect(sides[f] == before, "a fading zone keeps her old side past the boom crossing")
        #expect(levels[swap] == 0 && (swap == 0 || levels[swap - 1] > 0), "the side changes only once the old zone is gone")
        #expect(sides[swap...].allSatisfy { $0 != before }, "and stays on the new side")
        for i in 1..<levels.count {
            #expect(levels[i] - levels[i - 1] <= rise + 1e-12, "builds, never jumps, at tick \(i)")
            #expect(levels[i - 1] - levels[i] <= fall + 1e-12, "fades, never drops, at tick \(i)")
        }
        let firstUp = try #require(levels[swap...].firstIndex { $0 > 0 })
        let full = try #require(levels[firstUp...].firstIndex { $0 >= 1 })
        #expect(Double(full - firstUp + 1) * Race.dt >= shadow.ribbons.buildSeconds - Race.dt, "over 2 s")
        #expect(levels.last == 1, "full again on the new side")

        // The fade is the class's value: easing fades her level out over it, whatever it is (0: at once).
        let boat = WakeScene.upwindCaster
        for fade in [0.0, 0.5, 1.5, 3.0] {
            var sails = BackwindSails()
            sails.step(boats: [boat], scales: [1], buildSeconds: 2, fadeSeconds: fade)
            var ticks = 0
            repeat {
                sails.step(boats: [boat], scales: [0], buildSeconds: 2, fadeSeconds: fade)
                ticks += 1
            } while sails.levels[0] > 0 && ticks < 10 * Race.tickRate
            let expected = max(1, Int((fade / Race.dt).rounded(.up)))
            #expect(abs(ticks - expected) <= 1, "fade \(fade) s: \(ticks) ticks, expected about \(expected)")
        }
    }

    /// Below the class's floor speed (2 kn on skiff@6) she casts no backwind; above it it builds in straight over the
    /// next 2 kn, the trapezoid's length held at its size there (`BoatClass.WindShadow.backwindScale(speed:)`).
    @Test func boatBelowTheFloorSpeedCastsNoBackwind() throws {
        let shadow = RaceFiles.defaults.boatClass.content.windShadow
        let floor = try #require(shadow.backwindFloorSpeed), span = shadow.backwindFloorSpan
        #expect(floor == metresPerSecond(knots: 2) && span == metresPerSecond(knots: 2))
        func zone(speed: Double) -> ShadowCone {
            ShadowCone(apex: .zero, apparentWindDirection: .pi / 2, heading: 0, windwardSide: .starboard, shadow: shadow,
                       trueWindAngle: deg2rad(45), speed: speed)
        }
        let out = shadow.backwindWidth / 2
        let spanAstern = try #require(shadow.backwindSpan(out: out))
        func p(_ z: ShadowCone) -> Vec2 {
            let astern = spanAstern.start + 0.25 * (spanAstern.end - spanAstern.start)
            return z.apex + z.windward * (shadow.sternCorner.x + out) + z.forward * (shadow.sternCorner.y - astern * shadow.backwindScale(speed: z.speed))
        }
        for speed in [0, 0.5, floor - 1e-9, floor] {
            let z = zone(speed: speed)
            #expect(z.backwindEnvelope(at: p(z)) == 0 && !z.isInBackwind(p(z)), "\(speed) m/s")
            #expect(shadow.backwindFloorFactor(speed: speed) == 0)
        }
        let full = zone(speed: floor + span), half = zone(speed: floor + span / 2)
        #expect(shadow.backwindScale(speed: floor) == shadow.backwindScale(speed: floor + span), "the length holds below the build-in's end")
        #expect(abs(full.backwindEnvelope(at: p(full)) - 0.75) < 1e-9)
        #expect(abs(half.backwindEnvelope(at: p(half)) - 0.375) < 1e-9, "half built in")
        // A class without a floor (ilca-dinghy@4) fades it from rest by its length scale alone, as before.
        #expect(self.shadow.backwindFloorSpeed == nil && self.shadow.backwindFloorFactor(speed: 0) == 1)
    }
}
