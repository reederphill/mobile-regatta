import Foundation
import Testing
@testable import RegattaCore

/// A boat in a steady 10 kn wind from 0 in still water, her winds resolved by hand (no race): for the ribbon model's
/// and the sail's unit tests.
enum WakeScene {
    static let windDirection = 0.0
    static let tws = metresPerSecond(knots: 10)
    static let wind = Wind(direction: windDirection, speed: tws)
    static var boatClass: BoatClass { OpenWater.boatClass }
    static var shadow: BoatClass.WindShadow { boatClass.windShadow }
    static var upwind: (twa: Double, speed: Double) { let b = boatClass.polar.bestUpwind(tws: tws); return (b.twa, b.speed) }

    static func boat(id: Int = 0, position: Vec2 = .zero, heading: Double, speed: Double) -> Boat {
        var b = Boat(id: id, isPlayer: false, colorIndex: id, position: position, heading: heading, speed: speed)
        b.windOverGround = wind
        b.sailingWind = wind
        refresh(&b)
        return b
    }

    static func refresh(_ b: inout Boat) {
        b.apparentWind = BoatWinds.resolve(ground: wind, current: .zero, velocityThroughWater: b.velocity).apparent
        b.boomSide = b.relativeWind > 0 ? .port : .starboard
    }

    /// Close-hauled on her best upwind angle and speed, at the origin.
    static var upwindCaster: Boat { boat(heading: windDirection - upwind.twa, speed: upwind.speed) }
}

/// #377: the ribbon wake (`TurbulenceRibbons`), the sail's working scale (`SailTrim`) and the backwind's level and side
/// (`BackwindSails`) as units. The race's use of them is below in this suite and in `BackwindZoneTests`.
@Suite struct WakeRibbonsTests {
    typealias R = TurbulenceRibbons
    static var shadow: BoatClass.WindShadow { WakeScene.shadow }

    @Test func classWithoutARibbonsBlockSeedsThemFromItsCone() throws {
        let old = try BoatClassFile.bundled(id: "ilca-dinghy", version: 4).content.windShadow
        #expect(old.ribbons == .seeded(coneWidthAtBoat: old.coneWidthAtBoat, coneWidthAtEnd: old.coneWidthAtEnd,
                                       lossCloseIn: old.lossCloseIn))
        #expect(old.ribbons.peak == 0.25 && old.ribbons.buildSeconds == 2 && old.ribbons.emitSeconds == 0.5)
        #expect(old.header == nil && old.backwindFloorSpeed == nil && old.backwindFadeSeconds == 0)
    }

    @Test func emissionLevelDropsAtOnceAndBuildsBack() {
        var r = R(shadow: Self.shadow)
        let b = WakeScene.upwindCaster
        r.step(boats: [b], tick: 0, scales: [1])
        #expect(r.levels == [1])
        r.step(boats: [b], tick: 1, scales: [0])
        #expect(r.levels == [0], "at once")
        for tick in 2..<(2 + Race.tickRate) { r.step(boats: [b], tick: tick, scales: [1]) }
        #expect(abs(r.levels[0] - 0.5) < 1e-9, "half way in 1 s of 2")
        for tick in (2 + Race.tickRate)..<(2 + 2 * Race.tickRate) { r.step(boats: [b], tick: tick, scales: [1]) }
        #expect(abs(r.levels[0] - 1) < 1e-9)
    }

    @Test func emissionCadenceIsEvery15Ticks() {
        var r = R(shadow: Self.shadow)
        #expect(r.every == 15)
        var b = WakeScene.upwindCaster
        for tick in -61..<31 {
            b.position += b.velocity * Race.dt
            r.step(boats: [b], tick: tick)
        }
        #expect(r.points[0].map(\.born) == [-60, -45, -30, -15, 0, 15, 30])
        // Each point drifts with the true wind over the ground, and lives a cone length over her apparent wind.
        let p = r.points[0][0]
        #expect(p.drift == WakeScene.wind.velocity)
        #expect(abs(p.life - Self.shadow.coneLength / b.apparentWind.speed) < 1e-12)
    }

    @Test func aStoppedBoatAndAGhostShedNothing() {
        var r = R(shadow: Self.shadow)
        var ghost = WakeScene.upwindCaster
        ghost.status = .finished
        #expect(ghost.isGhost)
        let stopped = WakeScene.boat(id: 1, heading: WakeScene.windDirection - WakeScene.upwind.twa, speed: 0.1)
        for tick in 0..<60 {
            ghost.position += ghost.velocity * Race.dt
            r.step(boats: [ghost, stopped], tick: tick)
        }
        #expect(r.pointCount == 0)
        #expect(r.factor(at: .zero, tick: 60, receiver: 2) == 1)
    }

    /// The trail lies down the wind from her: a point just astern down her apparent wind is slowed, one well ahead of
    /// her or far to windward isn't; the loss never passes the class's floor.
    @Test func aSteadyTrailSlowsOnlyWhatIsInIt() {
        var r = R(shadow: Self.shadow)
        var b = WakeScene.upwindCaster
        let ticks = 8 * Race.tickRate
        for tick in 0..<ticks {
            b.position += b.velocity * Race.dt
            r.step(boats: [b], tick: tick)
        }
        let hull = OpenWater.hullLength
        let downApparent = -Vec2.heading(b.apparentWind.direction)
        let inTrail = b.position + downApparent * (2 * hull)
        let ahead = b.position + b.forward * (3 * hull)
        let windward = b.position + Vec2.heading(WakeScene.windDirection) * (4 * hull)
        let tick = ticks - 1
        #expect(r.factor(at: inTrail, tick: tick, receiver: 1) < 0.9)
        #expect(r.factor(at: ahead, tick: tick, receiver: 1) == 1)
        #expect(r.factor(at: windward, tick: tick, receiver: 1) == 1)
        #expect(r.factor(at: inTrail, tick: tick, receiver: 0) == 1, "her own trail never slows her")
        // The walk equals the max over the built ribbons.
        let byRuns = r.ribbons(of: 0, tick: tick).reduce(0) { max($0, R.loss(along: $1, at: inTrail)) }
        #expect(abs(r.loss(of: 0, at: inTrail, tick: tick) - byRuns) < 1e-15)
    }

    @Test func workingScaleReadsTheSailAngle() {
        let boatClass = WakeScene.boatClass, trim = SailTrim.standard
        let groove = WakeScene.upwindCaster
        #expect(trim.workingScale(of: groove, ease: true, boatClass: boatClass) == 0, "sheets out")
        var head = groove
        head.heading = WakeScene.windDirection
        WakeScene.refresh(&head)
        #expect(trim.workingScale(of: head, ease: false, boatClass: boatClass) == 0, "head to wind")
        var run = groove
        run.heading = WakeScene.windDirection + .pi * 0.9
        WakeScene.refresh(&run)
        #expect(trim.workingScale(of: run, ease: false, boatClass: boatClass) == 1, "running, stalled")
        let aoa = trim.angleOfAttack(groove, ease: false, boatClass: boatClass)
        #expect(aoa > 0)
        var half = boatClass
        half.windShadow.ribbons.fullAngle = 2 * aoa
        #expect(abs(trim.workingScale(of: groove, ease: false, boatClass: half) - 0.5) < 1e-9)
    }

    /// `BackwindSails`: easing fades the level over the fade time; a side change fades the old side to nothing, and only
    /// then builds on the new one over the build time.
    @Test func backwindSailsFadeOnTheirSideThenBuild() {
        var sails = BackwindSails()
        var b = WakeScene.upwindCaster
        sails.step(boats: [b], scales: [1], buildSeconds: 2, fadeSeconds: 1.5)
        #expect(sails.levels == [1] && sails.sides == [b.tack])
        let before = b.tack
        b.boomSide = b.boomSide == .port ? .starboard : .port
        var levels: [Double] = [], sides: [Tack] = []
        for _ in 0..<(5 * Race.tickRate) {
            sails.step(boats: [b], scales: [1], buildSeconds: 2, fadeSeconds: 1.5)
            levels.append(sails.levels[0])
            sides.append(sails.sides[0])
        }
        let swap = try! #require(sides.firstIndex { $0 != before })
        #expect(levels[swap] == 0 && levels[swap - 1] > 0)
        #expect(abs(Double(swap + 1) * Race.dt - 1.5) <= Race.dt + 1e-9, "faded over 1.5 s")
        let full = try! #require(levels.firstIndex { $0 >= 1 })
        #expect(abs(Double(full - swap) * Race.dt - 2) <= Race.dt + 1e-9, "built over 2 s")
        for i in 1..<levels.count {
            #expect(levels[i] - levels[i - 1] <= Race.dt / 2 + 1e-12)
            #expect(levels[i - 1] - levels[i] <= Race.dt / 1.5 + 1e-12)
        }
    }

    // MARK: In the race (#377 acceptance)

    static var hull: Double { OpenWater.hullLength }

    /// Seat 1 sails on seat 0's tack at her speed, `lengths` hull lengths from seat 0 along `direction` (her frame:
    /// `down` her apparent wind, `ahead` along her heading, `windward` square to the wind).
    enum Offset { case down, ahead, windward }

    static func pairRace(_ offset: Offset, lengths: Double = 3) throws -> Race {
        try OpenWater.race(knots: 10) { snapshot, _ in
            let caster = snapshot.seats[0].boat
            let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                             velocityThroughWater: caster.velocity).apparent
            let direction: Vec2
            switch offset {
            case .down: direction = -Vec2.heading(apparent.direction)
            case .ahead: direction = caster.forward
            case .windward: direction = Vec2.heading(caster.windDirection)
            }
            var b = snapshot.seats[1].boat
            b.position = caster.position + direction * (lengths * hull)
            b.heading = caster.heading
            b.speed = caster.speed
            b.boomSide = caster.boomSide
            b.rudder = 0
            b.desiredRudder = 0
            snapshot.seats[1].boat = b
            snapshot.seats[1].heldInput = .neutral
        }
    }

    /// `LeeBowTests`' lee-bow (seat 1 tacks onto seat 0's lee bow from 3 L ahead, 1.5 L to leeward) and its clean twin,
    /// stepped together until her tack ends; seat 0 is in her backwind from there on.
    static func leeBow(ahead: Double = 3, leeward: Double = 1.5) throws -> (leeBowed: Race, clean: Race) {
        let leeBowed = try LeeBowTests().race(ahead: ahead, leeward: leeward, together: true)
        let clean = try LeeBowTests().race(ahead: ahead, leeward: leeward, together: false)
        leeBowed.step()
        clean.step()
        _ = leeBowed.tap(.tackGybe, seat: 1, atTick: leeBowed.tick + 1)
        _ = clean.tap(.tackGybe, seat: 1, atTick: clean.tick + 1)
        for _ in 0..<(10 * Race.tickRate) {
            leeBowed.step()
            clean.step()
            if leeBowed.boats[1].boomSide == .port && !leeBowed.boats[1].isTacking { break }
        }
        return (leeBowed, clean)
    }

    /// The sim's wind shadow is the ribbons, not a cone: a boat down another's apparent wind, in her ribbon once it has
    /// formed, loses speed; one ahead of the caster or well to windward of her never does.
    @Test func ribbonsAreTheSimsShadow() throws {
        let trail = try Self.pairRace(.down), ahead = try Self.pairRace(.ahead), windward = try Self.pairRace(.windward, lengths: 4)
        var inTrail: [Double] = []
        for _ in 0..<(20 * Race.tickRate) {
            for race in [trail, ahead, windward] { race.step() }
            inTrail.append(trail.boats[1].shadow)
            #expect(ahead.boats[1].shadow == 1 && windward.boats[1].shadow == 1)
        }
        let late = inTrail[(10 * Race.tickRate)...]
        #expect(late.reduce(0, +) / Double(late.count) < 0.9, "the ribbons slow her")
        #expect(inTrail.allSatisfy { $0 >= Self.shadow.stackingFloor && $0 <= 1 })
        #expect(trail.wake.points[0].count > 5)
        // And the race's ribbons slow her more than clean air does: she falls behind her twin out of them.
        #expect(trail.boats[1].speed < ahead.boats[1].speed)
    }

    /// The backwind is a header: seat 0, lee-bowed, has her wind turned towards her bow, its speed unchanged (no lull),
    /// while her clean twin's isn't. Headers from several casters add, capped at 12°.
    @Test func backwindTurnsTheReceiversWindTowardsHerBow() throws {
        // The header's zone is the upwash beside the lee-bower's sail, from her mast to her stern (skiff@6): seat 0 has
        // to be overlapped with her to be in it. From 2.5 L ahead (`LeeBowTests`' overlapped lee-bow) she ends her tack
        // about 1 L ahead of seat 0, who sails up into it beside her within 2 s and is in it at 4 s.
        let (leeBowed, clean) = try Self.leeBow(ahead: 2.5)
        for _ in 0..<(4 * Race.tickRate) {
            leeBowed.step()
            clean.step()
        }
        let headed = leeBowed.boats[0], free = clean.boats[0]
        #expect(leeBowed.header(ofSeat: 0) > deg2rad(1) && clean.header(ofSeat: 0) == 0)
        #expect(leeBowed.header(ofSeat: 0) <= deg2rad(12))
        // Her wind over the ground is the clean one turned by her header, towards her bow; its speed is the same.
        let turn = wrapAngle(headed.windOverGround.direction - free.windOverGround.direction)
        #expect(abs(abs(turn) - leeBowed.header(ofSeat: 0)) < 1e-9, "turned by her header: \(rad2deg(turn))°")
        #expect(abs(headed.windOverGround.speed - free.windOverGround.speed) < 1e-12, "no lull")
        // The header carries the backwind's cost, not a loss: any shadow she has is the lee-bower's ribbons (her tack
        // leaves some lying over seat 0), never the zone.
        let zones = leeBowed.boats.indices.map(leeBowed.shadowCone(ofSeat:))
        #expect(zones[1]?.factor(at: headed.position) == 1 && zones[1]?.isInBackwind(headed.position) == true)

        // Stacked: two full envelopes would turn her 16°; the cap holds it at 12°.
        let header = try #require(Self.shadow.header)
        let caster = WakeScene.upwindCaster
        let zone = ShadowCone(caster: caster, shadow: Self.shadow)
        // Full at her side, half way between her stern and her mast.
        let extent = try #require(Self.shadow.upwashExtent)
        let p = zone.apex + zone.windward * (extent.out + 1e-6 * extent.reach) + zone.forward * ((extent.aft + extent.fore) / 2)
        #expect(abs(zone.backwindEnvelope(at: p) - 1) < 1e-5)
        #expect(abs(Race.headerTarget(at: p, receiver: 9, zones: [zone], header: header) - deg2rad(8)) < 1e-6)
        #expect(Race.headerTarget(at: p, receiver: 9, zones: [zone, zone], header: header) == deg2rad(12))
        #expect(Race.headerTarget(at: p, receiver: 0, zones: [zone], header: header) == 0, "never her own")
        // Never past her bow.
        let w = Wind(direction: 0, speed: 5)
        #expect(abs(Race.headed(w, heading: deg2rad(5), by: deg2rad(8)).direction - deg2rad(5)) < 1e-12)
        #expect(abs(Race.headed(w, heading: deg2rad(-40), by: deg2rad(8)).direction - deg2rad(-8)) < 1e-12)
    }

    /// The backwind needs a working sail: eased, luffing, head to wind, mid-tack and mid-gybe she casts none (her
    /// working scale is 0, so her level falls to 0 over the fade); trimmed in the groove she casts it all.
    @Test func noBackwindWithoutAWorkingSail() throws {
        let boatClass = WakeScene.boatClass, trim = SailTrim.standard
        // A point in her upwash zone: a quarter of its reach out from her side, half way between her stern and her mast.
        let extent = try #require(Self.shadow.upwashExtent)
        let (out, along) = (extent.out + 0.25 * extent.reach, (extent.aft + extent.fore) / 2)
        func envelope(_ caster: Boat, ease: Bool) -> Double {
            var zone = ShadowCone(caster: caster, shadow: Self.shadow)
            zone.backwindSail = trim.workingScale(of: caster, ease: ease, boatClass: boatClass)
            return zone.backwindEnvelope(at: zone.apex + zone.windward * out + zone.forward * along)
        }
        let groove = WakeScene.upwindCaster
        #expect(envelope(groove, ease: false) > 0.5, "trimmed in the groove")
        #expect(envelope(groove, ease: true) == 0, "eased")
        var luffing = groove
        luffing.heading = WakeScene.windDirection - (BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(1))
        WakeScene.refresh(&luffing)
        #expect(envelope(luffing, ease: false) == 0, "luffing")
        var head = groove
        head.heading = WakeScene.windDirection
        WakeScene.refresh(&head)
        #expect(envelope(head, ease: false) == 0, "head to wind")

        // Mid-tack: the lee-bower tacks away; through the tack her working scale goes to 0 and her backwind is gone
        // (level 0) before it builds on her new side.
        let race = try Self.leeBow().leeBowed
        for _ in 0..<(3 * Race.tickRate) { race.step() }
        #expect(race.backwindSail(ofSeat: 1) == 1)
        _ = race.tap(.tackGybe, seat: 1, atTick: race.tick + 1)
        var sawNone = false, sawZeroTarget = false
        let before = race.backwindSide(ofSeat: 1)
        for _ in 0..<(6 * Race.tickRate) {
            race.step()
            if trim.workingScale(of: race.boats[1], ease: false, boatClass: race.boatClass) == 0 { sawZeroTarget = true }
            if race.backwindSail(ofSeat: 1) == 0 { sawNone = true }
            if race.backwindSide(ofSeat: 1) != before { #expect(sawNone, "the side swaps only once it is gone") }
        }
        #expect(sawZeroTarget && sawNone)

        // Mid-gybe: a boat on a broad reach gybes; through it she casts no backwind anywhere (running, then fading on
        // her old side until it is gone).
        let gybe = try OpenWater.race(knots: 10) { snapshot, _ in
            var b = snapshot.seats[0].boat
            b.heading = wrapAngle(b.windDirection + .pi - deg2rad(30))
            b.speed = OpenWater.boatClass.polar.speed(twa: deg2rad(150), tws: b.windSpeed)
            b.boomSide = b.relativeWind > 0 ? .port : .starboard
            snapshot.seats[0].boat = b
        }
        gybe.step()
        _ = gybe.tap(.tackGybe, seat: 0, atTick: gybe.tick + 1)
        let startSide = gybe.boats[0].tack
        var gybed = false
        for _ in 0..<(6 * Race.tickRate) {
            gybe.step()
            let zone = try #require(gybe.shadowCone(ofSeat: 0))
            let b = gybe.boats[0]
            for side in [1.0, -1.0] {
                let q = b.position + b.forward.rightPerp * (side * out) + b.forward * along
                #expect(zone.backwindEnvelope(at: q) == 0)
            }
            if b.tack != startSide { gybed = true }
        }
        #expect(gybed, "she gybed")
    }

    /// The ribbons, headers and backwind levels are race state stepped from the boats alone: two runs of the same race
    /// and inputs carry the same points, shadows and digests every tick.
    @Test func ribbonStateReplaysFromTheLog() {
        let races = (0..<2).map { _ in testRace(seats: Array(repeating: .human, count: 8), prestartSeconds: 20, seed: 377) }
        for race in races {
            _ = race.tap(.tackGybe, seat: 2, atTick: -400)
            _ = race.apply(BoatInput(rudder: 60 as Int8, ease: true), seat: 3, atTick: -500)
            _ = race.apply(.neutral, seat: 3, atTick: -420)
        }
        for _ in 0..<900 {
            for race in races { race.step() }
            #expect(races[0].wake == races[1].wake)
            #expect((0..<8).map(races[0].header(ofSeat:)) == (0..<8).map(races[1].header(ofSeat:)))
            #expect((0..<8).map(races[0].backwindSail(ofSeat:)) == (0..<8).map(races[1].backwindSail(ofSeat:)))
            #expect(races[0].boats.map(\.shadow) == races[1].boats.map(\.shadow))
            #expect(races[0].digest() == races[1].digest())
        }
        #expect(races[0].wake.pointCount > 0)
    }
}
