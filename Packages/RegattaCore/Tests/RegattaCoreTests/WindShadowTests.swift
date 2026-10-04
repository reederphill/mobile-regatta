import Foundation
import Testing
@testable import RegattaCore

/// #79 acceptance, as #377 left it: the shadow is the caster's ribbon wake down the wind from her, the backwind reaches
/// to windward of her; the shadow slows a boat without turning her wind (#10), and so does #298's backwind loss (a class
/// with a header turns it instead, `WakeRibbonsTests`).
@Suite struct WindShadowTests {
    let dinghy: BoatClass
    var shadow: BoatClass.WindShadow { dinghy.windShadow }
    var hullLength: Double { dinghy.hull.length }
    let noCurrent = CurrentField(current: nil, tideStateAtGun: 0)

    init() throws {
        dinghy = try Fixtures.boatClass()
    }

    /// Angle between two unit vectors, radians.
    func angle(_ a: Vec2, _ b: Vec2) -> Double { acos(a.dot(b).clamped(to: -1...1)) }

    /// Close-hauled on starboard at her polar speed in her sailing wind.
    func closeHauled(_ boat: inout Boat) {
        let best = dinghy.polar.bestUpwind(tws: boat.windSpeed)
        boat.heading = wrapAngle(boat.windDirection - best.twa)
        boat.speed = best.speed
        boat.boomSide = .port
        boat.rudder = 0
        boat.desiredRudder = 0
    }

    @Test func reachingCastersConeFollowsHerApparentWind() throws {
        let tws = metresPerSecond(knots: 10)
        var caster = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: -.pi / 2,
                          speed: dinghy.polar.speed(twa: .pi / 2, tws: tws))
        let winds = BoatWinds.resolve(ground: Wind(direction: 0, speed: tws), current: .zero, velocityThroughWater: caster.velocity)
        caster.sailingWind = winds.sailing
        caster.apparentWind = winds.apparent
        #expect(abs(caster.twa - .pi / 2) < 1e-12)
        let cone = ShadowCone(caster: caster, shadow: shadow)
        let trueDownwind = -Vec2.heading(caster.windDirection)
        #expect(rad2deg(angle(cone.axis, trueDownwind)) > 10, "axis \(rad2deg(angle(cone.axis, trueDownwind)))° off true downwind")
        #expect((cone.axis - -Vec2.heading(caster.apparentWind.direction)).length < 1e-12)
        // Bent forward: the cone streams aft of the beam on her leeward side.
        #expect(cone.axis.dot(caster.forward) < 0 && cone.axis.dot(trueDownwind) > 0)

        // A race's cone query is the same geometry, at each boat, along her apparent wind.
        let race = try placedRace(current: noCurrent) { snapshot, _ in
            var boat = snapshot.seats[0].boat
            boat.heading = wrapAngle(boat.windDirection - .pi / 2)
            boat.speed = dinghy.polar.speed(twa: .pi / 2, tws: boat.windSpeed)
            snapshot.seats[0].boat = boat
        }
        race.step()
        let raced = try #require(race.shadowCone(ofSeat: 0))
        #expect(raced == ShadowCone(caster: race.boats[0], shadow: race.boatClass.windShadow))
        #expect(raced.apex == race.boats[0].position)
        #expect(rad2deg(angle(raced.axis, -Vec2.heading(race.boats[0].windOverGround.direction))) > 10)
        #expect(race.shadowCone(ofSeat: 2) == nil)
    }

    /// Two casters' ribbons over one point stack by product, never below the class's floor (#377, as the cones did).
    @Test func twoStackedRibbonsNeverGoBelowTheFloor() {
        var ribbons = TurbulenceRibbons(shadow: shadow)
        let up = dinghy.polar.bestUpwind(tws: WakeScene.tws)
        func boat(_ id: Int, _ at: Vec2) -> Boat {
            var b = Boat(id: id, isPlayer: false, colorIndex: id, position: at, heading: -up.twa, speed: up.speed)
            b.windOverGround = WakeScene.wind
            b.sailingWind = WakeScene.wind
            b.apparentWind = BoatWinds.resolve(ground: WakeScene.wind, current: .zero, velocityThroughWater: b.velocity).apparent
            b.boomSide = .port
            return b
        }
        var boats = [boat(0, .zero), boat(1, Vec2(0.5, 0))]
        for tick in 0..<(6 * Race.tickRate) {
            for i in boats.indices { boats[i].position += boats[i].velocity * Race.dt }
            ribbons.step(boats: boats, tick: tick)
        }
        let tick = 6 * Race.tickRate - 1
        let p = boats[0].position - Vec2.heading(boats[0].apparentWind.direction) * hullLength
        let each = (1 - ribbons.loss(of: 0, at: p, tick: tick)) * (1 - ribbons.loss(of: 1, at: p, tick: tick))
        #expect(ribbons.loss(of: 0, at: p, tick: tick) > 0 && ribbons.loss(of: 1, at: p, tick: tick) > 0)
        #expect(ribbons.factor(at: p, tick: tick, receiver: 2) == max(each, shadow.stackingFloor))
        #expect(ribbons.factor(at: p, tick: tick, receiver: 2) >= shadow.stackingFloor)
        var low = shadow
        low.stackingFloor = 0.99
        let floored = TurbulenceRibbons(shadow: low, points: ribbons.points, levels: ribbons.levels)
        #expect(floored.factor(at: p, tick: tick, receiver: 2) == 0.99)
    }

    /// ilca-dinghy@4 (#298): ilca-dinghy@3 with its backwind the trapezoid astern on the windward quarter.
    func trapezoidDinghy() throws -> BoatClassFile { try BoatClassFile.bundled(id: Fixtures.classID, version: 4) }

    /// A leeward boat close-hauled on ilca-dinghy@4 with another to windward of her and astern, in her backwind half a
    /// hull length out from her windward stern corner and half a hull length astern of her stern; and the same windward
    /// boat with the leeward one sailed away.
    func backwindRaces() throws -> (together: Race, alone: Race) {
        let file = try trapezoidDinghy()
        let length = file.content.hull.length
        let corner = file.content.windShadow.sternCorner
        func race(together: Bool) throws -> Race {
            try placedRace(current: noCurrent, boatClass: file.ref) { snapshot, _ in
                var leeward = snapshot.seats[0].boat
                closeHauled(&leeward)
                // On starboard (boom to port) her windward side is to starboard.
                let out = corner.x + 0.5 * length, along = corner.y - 0.5 * length
                var windward = Boat(id: 1, isPlayer: true, colorIndex: 1,
                                position: leeward.position + leeward.forward.rightPerp * out + leeward.forward * along,
                                heading: leeward.heading, speed: leeward.speed, boomSide: .port)
                windward.sailingWind = leeward.sailingWind
                // Her autohelm holds the angle she's placed on, not the groove, which moves with the wind
                // strength her backwind leaves her: the same course in both races, so only the speed differs.
                windward.autohelm = Autohelm(target: .angle(leeward.sailingAngle))
                if !together { leeward.position += Vec2(400, 0) }
                snapshot.seats[0].boat = leeward
                snapshot.seats[1].boat = windward
            }
        }
        return (try race(together: true), try race(together: false))
    }

    @Test func boatWindwardAndAsternOfALeewardBoatLosesSpeedInHerBackwind() throws {
        let (together, alone) = try backwindRaces()
        let (leeward, windward) = (together.boats[0], together.boats[1])
        // To windward of the leeward boat and astern of her.
        let side = (windward.position - leeward.position).dot(leeward.forward.rightPerp)
        #expect(side * leeward.relativeWind > 0, "to windward")
        #expect((windward.position - leeward.position).dot(leeward.forward) < 0, "astern")

        together.step()
        alone.step()
        let cone = try #require(together.shadowCone(ofSeat: 0))
        #expect(cone.isInBackwind(together.boats[1].position))
        #expect(cone.factor(at: together.boats[1].position) < 1)
        #expect(together.boats[1].shadow < 1 && alone.boats[1].shadow == 1)
        for _ in 0..<(3 * Race.tickRate) {
            together.step()
            alone.step()
        }
        #expect(together.boats[1].speed < alone.boats[1].speed,
                "backwinded \(together.boats[1].speed) m/s, clear \(alone.boats[1].speed) m/s")
        #expect(!together.drainEvents().contains { if case .ruleCall = $0.kind { true } else { false } }, "the boats never touched")
    }

    /// The boat #79's band slowed, to windward of the leeward boat and ahead of her, is outside the trapezoid.
    @Test func boatToWindwardAndAheadIsOutsideTheBackwind() throws {
        let file = try trapezoidDinghy()
        var leeward = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: 0, speed: 2, boomSide: .port)
        leeward.windOverGround = Wind(direction: deg2rad(45), speed: metresPerSecond(knots: 10))
        let winds = BoatWinds.resolve(ground: leeward.windOverGround, current: .zero, velocityThroughWater: leeward.velocity)
        leeward.sailingWind = winds.sailing
        leeward.apparentWind = winds.apparent
        let band = ShadowCone(caster: leeward, shadow: shadow)
        let trapezoid = ShadowCone(caster: leeward, shadow: file.content.windShadow)
        let ahead = Vec2.heading(leeward.apparentWind.direction) * 0.6 * shadow.backwindLength
        #expect(band.factor(at: ahead) < 1, "in #79's band")
        #expect(trapezoid.factor(at: ahead) == 1 && !trapezoid.isInBackwind(ahead), "not in the trapezoid")
    }

    @Test func boatInShadowKeepsTheWindDirection() throws {
        // A reaching caster with a reaching boat two lengths down her cone; the same boat alone. In a wind
        // the same everywhere, so the autohelm holds both on their course exactly (ADR 0007).
        let steady = GroundWind(direction: 0, speed: metresPerSecond(knots: 10))
        func race(together: Bool) throws -> Race {
            try placedRace(current: noCurrent, wind: { _ in steady }) { snapshot, _ in
                var caster = snapshot.seats[0].boat
                caster.heading = wrapAngle(caster.windDirection - .pi / 2)
                caster.speed = dinghy.polar.speed(twa: .pi / 2, tws: caster.windSpeed)
                caster.rudder = 0
                caster.desiredRudder = 0
                let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                                 velocityThroughWater: caster.velocity).apparent
                let receiver = Boat(id: 1, isPlayer: true, colorIndex: 1,
                                position: caster.position - Vec2.heading(apparent.direction) * 2 * hullLength,
                                heading: caster.heading, speed: caster.speed, boomSide: caster.boomSide)
                if !together { caster.position += Vec2(0, 400) }
                snapshot.seats[0].boat = caster
                snapshot.seats[1].boat = receiver
            }
        }
        let together = try race(together: true), alone = try race(together: false)
        var shadedTicks = 0
        for _ in 0..<(6 * Race.tickRate) {
            together.step()
            alone.step()
            let (shaded, clear) = (together.boats[1], alone.boats[1])
            #expect(clear.shadow == 1)
            if shaded.shadow < 1 { shadedTicks += 1 }
            // Shadow slows her; it never turns the wind she steers by, so her autohelm holds the same course.
            #expect(shaded.sailingWind.direction == clear.sailingWind.direction)
            #expect(shaded.windOverGround == clear.windOverGround)
            #expect(shaded.heading == clear.heading)
        }
        // The caster's ribbon reaches her once its air has drifted the two lengths down to her.
        #expect(shadedTicks > 2 * Race.tickRate, "in the ribbons \(shadedTicks) ticks")
        #expect(together.boats[1].speed < alone.boats[1].speed)
    }

    @Test func backwindAndShadowFloorComeFromTheClassFile() throws {
        let file = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version)
        #expect(file.header.placeholders.contains("/windShadow/backwind"))
        #expect(file.header.placeholders.contains("/windShadow/stackingFloor"))
        #expect(shadow.backwindLength == 1.5 * hullLength && shadow.backwindWidth == 1.0 * hullLength)
        #expect(shadow.backwindLoss == 0.1 && shadow.stackingFloor == 0.6)

        let retuned = try BoatClassFile(data: Fixtures.edited([
            (of: #""stackingFloor": 0.6"#, with: #""stackingFloor": 0.5"#),
            (of: #""lengthHullLengths": 1.5"#, with: #""lengthHullLengths": 2.0"#),
            (of: #""loss": 0.1"#, with: #""loss": 0.2"#),
        ])).content.windShadow
        let upwind = Vec2.heading(0) * 1.75 * hullLength
        #expect(ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: shadow).factor(at: upwind) == 1)
        let wider = ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: retuned)
        #expect(wider.factor(at: upwind) < 1)
        #expect(abs(wider.factor(at: Vec2.heading(0) * 0.001) - 0.8) < 1e-3)
        #expect(retuned.stackingFloor == 0.5)
        // A class without a ribbons block (#377) seeds its ribbons from its cone: as wide and as strong.
        #expect(retuned.ribbons == .seeded(coneWidthAtBoat: retuned.coneWidthAtBoat, coneWidthAtEnd: retuned.coneWidthAtEnd,
                                           lossCloseIn: retuned.lossCloseIn))
        // skiff@6 and ilca-dinghy@5 carry theirs, and the backwind header, fade and floor (#377).
        for (id, version) in [("skiff", 6), (Fixtures.classID, 5)] {
            let file = try BoatClassFile.bundled(id: id, version: version)
            let s = file.content.windShadow
            #expect(s.header != nil && s.backwindFadeSeconds == 1.5 && s.backwindFloorSpeed != nil)
            #expect(s.ribbons.peak == s.lossCloseIn && s.ribbons.startWidth == s.coneWidthAtBoat && s.ribbons.endWidth == s.coneWidthAtEnd)
        }
        let edited = try BoatClassFile(data: Fixtures.edited([
            (of: #""degrees": 8"#, with: #""degrees": 5"#),
            (of: #""peakLoss": 0.25"#, with: #""peakLoss": 0.3"#),
            (of: #""floorKnots": 2,"#, with: #""floorKnots": 3,"#),
        ], version: 5)).content.windShadow
        #expect(edited.header?.angle == deg2rad(5) && edited.ribbons.peak == 0.3)
        #expect(edited.backwindFloorSpeed == metresPerSecond(knots: 3))

        // ilca-dinghy@3 keeps #79's band (no inner length); version 4 (#298) casts the trapezoid, its corner read off
        // the hull outline (0.63 m out, 0.15 L), 1 L wide, 2 L on its outer edge and 1.5 L on its inner one.
        #expect(shadow.backwindInnerLength == nil)
        let v4 = try trapezoidDinghy()
        #expect(v4.header.placeholders.contains("/windShadow/backwind"))
        let trapezoid = v4.content.windShadow
        #expect(trapezoid.sternCorner == Vec2(0.63, -2.1) && abs(trapezoid.sternCorner.x / hullLength - 0.15) < 1e-12)
        #expect(trapezoid.backwindWidth == 1.0 * hullLength && trapezoid.backwindLength == 2.0 * hullLength)
        #expect(trapezoid.backwindInnerLength == 1.5 * hullLength && trapezoid.backwindLoss == 0.2)
        let longer = try BoatClassFile(data: Fixtures.edited([
            (of: #""innerLengthHullLengths": 1.5"#, with: #""innerLengthHullLengths": 1.9"#),
            (of: #""loss": 0.2"#, with: #""loss": 0.4"#),
        ], version: 4)).content.windShadow
        #expect(longer.backwindInnerLength == 1.9 * hullLength && longer.backwindLoss == 0.4)
        // Just past the inner corner: 1.7 L astern of the stern is beyond version 4's slanted edge, inside the longer one.
        let slanted = Vec2(0.63 + 0.01, -2.1 - 1.7 * hullLength)
        #expect(ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: trapezoid).backwindFactor(at: slanted) == 1)
        #expect(ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: longer).backwindFactor(at: slanted) < 1)
        let atTheStern = Vec2(0.63 + 0.5 * hullLength, -2.1 - 0.001)
        #expect(abs(ShadowCone(apex: .zero, apparentWindDirection: 0, heading: 0, windwardSide: .starboard, shadow: longer)
            .backwindFactor(at: atTheStern) - 0.6) < 1e-3)
        // An inner length past the outer edge's length, or none with a zero-sized zone, is refused.
        #expect(throws: DataFileError.self) {
            try BoatClassFile(data: Fixtures.edited([(of: #""innerLengthHullLengths": 1.5"#, with: #""innerLengthHullLengths": 2.5"#)],
                                                    version: 4))
        }
        #expect(throws: DataFileError.self) {
            try BoatClassFile(data: Fixtures.edited([(of: #""widthHullLengths": 1.0"#, with: #""widthHullLengths": 0"#)], version: 4))
        }

        // A race casts with its class's values.
        let race = try placedRace(current: noCurrent) { _, _ in }
        #expect(race.shadowCone(ofSeat: 0)?.shadow == race.boatClass.windShadow)
        #expect(race.wake.shadow == race.boatClass.windShadow)
    }

    /// #377: an eased boat's sail isn't working, so she sheds no turbulence (a boat down her apparent wind stays in clean
    /// air) and, once her backwind has faded (1.5 s), casts none: the boat she had lee-bowed is headed no longer.
    @Test func easedBoatCastsNoShadowAndNoBackwind() throws {
        let trail = try WakeRibbonsTests.pairRace(.down)
        _ = trail.apply(BoatInput(rudder: 0 as Int8, ease: true), seat: 0, atTick: trail.tick + 1)
        for _ in 0..<(10 * Race.tickRate) {
            trail.step()
            #expect(trail.boats[1].shadow == 1)
        }
        #expect(trail.wake.levels[0] == 0 && trail.wake.points[0].allSatisfy { $0.peak == 0 && $0.scale == 0 })

        let race = try WakeRibbonsTests.leeBow().leeBowed
        for _ in 0..<(3 * Race.tickRate) { race.step() }
        #expect(race.header(ofSeat: 0) > 0 && race.backwindSail(ofSeat: 1) == 1)
        _ = race.apply(BoatInput(rudder: 0 as Int8, ease: true), seat: 1, atTick: race.tick + 1)
        race.step()
        race.step()
        #expect(race.backwindSail(ofSeat: 1) > 0 && race.backwindSail(ofSeat: 1) < 1, "fading, not cut")
        for _ in 0..<(2 * Race.tickRate) { race.step() }
        #expect(race.backwindSail(ofSeat: 1) == 0, "gone by 1.5 s")
        let zone = try #require(race.shadowCone(ofSeat: 1))
        #expect(zone.backwindEnvelope(at: race.boats[0].position) == 0 && !zone.isInBackwind(race.boats[0].position))
        for _ in 0..<(5 * Race.tickRate) { race.step() }
        #expect(race.header(ofSeat: 0) < deg2rad(0.1), "\(rad2deg(race.header(ofSeat: 0)))° left")
        #expect(race.boats[0].shadow == 1, "and no lull")
    }
}
