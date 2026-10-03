import Foundation
import Testing
@testable import RegattaCore

/// #376 follow-on B: the sim reads the ribbon wake (`ShadowModel`) and a header-and-lull backwind (`BackwindModel`),
/// behind `Race.shadowSettings`. The defaults are today's sim exactly; the other settings are a Debug practice race's.
/// Tests that print are the tuning tables for the finding (`swift test --filter WakeRibbonsTests`).
@Suite struct WakeRibbonsTests {
    typealias R = TurbulenceRibbons
    static var shadow: BoatClass.WindShadow { OpenWater.boatClass.windShadow }
    static var hull: Double { OpenWater.hullLength }

    static func settings(_ shadowModel: ShadowModel = .boxes, _ backwindModel: BackwindModel = .box,
                         header: Double? = nil, lull: Double? = nil, tau: Double? = nil) -> ShadowSettings {
        var s = ShadowSettings(shadowModel: shadowModel, backwindModel: backwindModel)
        if let header { s.headerDegrees = header }
        s.lullLoss = lull
        if let tau { s.headerTimeConstant = tau }
        return s
    }

    // MARK: Races

    /// Seat 1 sails on seat 0's tack at her speed, 3 L down seat 0's apparent wind: in her wake on either model.
    static func trailRace(_ settings: ShadowSettings) throws -> Race {
        let race = try OpenWater.race(knots: 10) { snapshot, _ in
            let caster = snapshot.seats[0].boat
            let apparent = BoatWinds.resolve(ground: caster.windOverGround, current: .zero,
                                             velocityThroughWater: caster.velocity).apparent
            var b = snapshot.seats[1].boat
            b.position = caster.position - Vec2.heading(apparent.direction) * (3 * hull)
            b.heading = caster.heading
            b.speed = caster.speed
            b.boomSide = caster.boomSide
            b.rudder = 0
            b.desiredRudder = 0
            snapshot.seats[1].boat = b
            snapshot.seats[1].heldInput = .neutral
        }
        race.shadowSettings = settings
        return race
    }

    /// `LeeBowTests`' lee-bow (seat 1 tacks onto seat 0's lee bow from 3 L ahead, 1.5 L to leeward) and its clean
    /// twin, stepped together until her tack ends; seat 0 is in her backwind from there on. The twin sails the
    /// default settings: nothing reaches her either way.
    static func leeBow(_ settings: ShadowSettings) throws -> (leeBowed: Race, clean: Race) {
        let leeBowed = try LeeBowTests().race(ahead: 3, leeward: 1.5, together: true)
        let clean = try LeeBowTests().race(ahead: 3, leeward: 1.5, together: false)
        leeBowed.shadowSettings = settings
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

    // MARK: 1. Defaults unchanged

    /// A race at the default settings, the same race told them explicitly, one set to other models and back before
    /// it steps, and one at the header-and-lull model with no header and the class's loss: bit for bit the same race.
    /// In a fleet's start sequence, a boat in another's trail, and the lee-bow.
    @Test func defaultSettingsLeaveTheShadowAndWinds() throws {
        let setups: [(name: String, make: () throws -> Race)] = [
            ("fleet", { testRace(seats: Array(repeating: .human, count: 8), prestartSeconds: 20, seed: 376) }),
            ("trail", { try Self.trailRace(ShadowSettings()) }),
            ("lee-bow", { try Self.leeBow(ShadowSettings()).leeBowed }),
        ]
        for setup in setups {
            let races = try (0..<4).map { _ in try setup.make() }
            races[1].shadowSettings = ShadowSettings()
            races[2].shadowSettings = Self.settings(.both, .headerAndLull, header: 5, lull: 0.5)
            races[2].shadowSettings = ShadowSettings()
            races[3].shadowSettings = Self.settings(.boxes, .headerAndLull, header: 0)
            var shadowed = 0
            for _ in 0..<600 {
                for race in races { race.step() }
                if races[0].boats.contains(where: { $0.shadow < 1 }) { shadowed += 1 }
                let digest = races[0].digest()
                for race in races.dropFirst() {
                    #expect(race.digest() == digest)
                    #expect(race.boats.map(\.shadow) == races[0].boats.map(\.shadow))
                    #expect(race.boats.map(\.apparentWind) == races[0].boats.map(\.apparentWind))
                    #expect(race.boats.map(\.position) == races[0].boats.map(\.position))
                }
            }
            #expect(races.allSatisfy { $0.wake == nil && $0.header(ofSeat: 0) == 0 })
            print("DEFAULTS \(setup.name): some boat shadowed on \(shadowed) of 600 ticks; digests equal")
            if setup.name != "fleet" { #expect(shadowed > 300) }
        }
    }

    // MARK: 2. (The prototype's tests, `TurbulenceTrailPrototypeTests`, now read this type.)

    // MARK: 3. The shadow model

    @Test func ribbonsModelSlowsABoatInTheTrail() throws {
        let boxes = try Self.trailRace(ShadowSettings()), ribbons = try Self.trailRace(Self.settings(.ribbons))
        var box: [Double] = [], ribbon: [Double] = []
        for _ in 0..<(20 * Race.tickRate) {
            boxes.step()
            ribbons.step()
            box.append(boxes.boats[1].shadow)
            ribbon.append(ribbons.boats[1].shadow)
        }
        let late = 10 * Race.tickRate
        let mean = { (xs: ArraySlice<Double>) in xs.reduce(0, +) / Double(xs.count) }
        print(String(format: "TRAIL seat 1 3 L down seat 0's apparent wind: mean factor last 10 s boxes %.3f ribbons %.3f; ribbon first < 1 at %.1f s",
                     mean(box[late...]), mean(ribbon[late...]),
                     Double(ribbon.firstIndex { $0 < 1 } ?? -1) / Double(Race.tickRate)))
        #expect(mean(ribbon[late...]) < 0.9, "the ribbons slow her")
        #expect(ribbon.allSatisfy { $0 >= Self.shadow.stackingFloor && $0 <= 1 })
        #expect(ribbons.wake != nil && boxes.wake == nil)
        #expect((ribbons.wake?.points.first?.count ?? 0) > 5)
    }

    /// Every cone and the wake from a ribbon race, read on a grid around the boats.
    static func sampled() throws -> (cones: [ShadowCone?], wake: R, tick: Int, points: [Vec2]) {
        let race = try Self.trailRace(Self.settings(.both))
        for _ in 0..<(12 * Race.tickRate) { race.step() }
        let cones = race.boats.indices.map(race.shadowCone(ofSeat:))
        let wake = try #require(race.wake)
        let centre = race.boats[0].position
        var points: [Vec2] = []
        for x in stride(from: -8.0, through: 8, by: 0.5) {
            for y in stride(from: -8.0, through: 8, by: 0.5) { points.append(centre + Vec2(x, y) * hull) }
        }
        return (cones, wake, race.tick, points)
    }

    @Test func boxesModelEqualsTodaysFactor() throws {
        let (cones, wake, tick, points) = try Self.sampled()
        let others = cones.dropFirst().compactMap { $0 }
        for p in points {
            #expect(Race.shadow(at: p, receiver: 0, cones: cones, wake: wake, tick: tick, settings: ShadowSettings(),
                                windShadow: Self.shadow) == ShadowCone.factor(at: p, of: others, floor: Self.shadow.stackingFloor))
        }
    }

    @Test func bothModelIsTheFlooredProduct() throws {
        let (cones, wake, tick, points) = try Self.sampled()
        let others = cones.dropFirst().compactMap { $0 }
        var inBoth = 0
        for p in points {
            let box = ShadowCone.factor(at: p, of: others, floor: Self.shadow.stackingFloor)
            let ribbon = wake.factor(at: p, tick: tick, receiver: 0)
            if box < 1 && ribbon < 1 { inBoth += 1 }
            #expect(Race.shadow(at: p, receiver: 0, cones: cones, wake: wake, tick: tick, settings: Self.settings(.both),
                                windShadow: Self.shadow) == max(box * ribbon, Self.shadow.stackingFloor))
            // The ribbons alone: the wake in place of the cone, the backwind as the box's.
            let backwind = others.reduce(1.0) { $0 * $1.backwindFactor(at: p) }
            let alone = Race.shadow(at: p, receiver: 0, cones: cones, wake: wake, tick: tick, settings: Self.settings(.ribbons),
                                    windShadow: Self.shadow)
            #expect(abs(alone - max(wake.unflooredFactor(at: p, tick: tick, receiver: 0) * backwind, Self.shadow.stackingFloor)) < 1e-12)
        }
        #expect(inBoth > 0)
    }

    // MARK: 4. Header and lull

    @Test func headerAndLullWithZeroHeaderEqualsTheBox() throws {
        let box = try Self.leeBow(ShadowSettings()).leeBowed
        let zero = try Self.leeBow(Self.settings(.boxes, .headerAndLull, header: 0)).leeBowed
        var worst = 0.0, backwinded = 0
        for _ in 0..<(20 * Race.tickRate) {
            box.step()
            zero.step()
            worst = max(worst, abs(box.boats[0].shadow - zero.boats[0].shadow))
            if box.boats[0].shadow < 1 { backwinded += 1 }
        }
        #expect(worst < 1e-12)
        #expect(backwinded > 10 * Race.tickRate)
        #expect(zero.digest() == box.digest())
    }

    /// A caster close-hauled at the origin (`TrailScene`, 10 kn from 0) and a point `share` of the way from her
    /// trapezoid's stern edge to its far edge, half way out.
    static func inTrapezoid(_ cone: ShadowCone, share: Double) -> Vec2 {
        let s = cone.shadow
        let out = s.backwindWidth / 2
        let span = s.backwindSpan(out: out)!
        let astern = span.start + share * (span.end - span.start)
        let scale = s.backwindScale(speed: cone.speed)
        return cone.apex + cone.windward * (s.sternCorner.x + out) + cone.forward * (s.sternCorner.y - astern * scale)
    }

    static var upwindCaster: Boat {
        let up = TrailScene.upwind
        return TrailScene.boat(position: .zero, heading: TrailScene.windDirection - up.twa, speed: up.speed)
    }

    @Test func headerEnvelopeIsFullAtSternEdgeAndZeroAtFarEdge() {
        let cone = ShadowCone(caster: Self.upwindCaster, shadow: Self.shadow)
        #expect(cone.backwindPresence == 1)
        #expect(abs(cone.backwindEnvelope(at: Self.inTrapezoid(cone, share: 1e-6)) - 1) < 1e-5)
        #expect(abs(cone.backwindEnvelope(at: Self.inTrapezoid(cone, share: 0.5)) - 0.5) < 1e-9)
        #expect(cone.backwindEnvelope(at: Self.inTrapezoid(cone, share: 1 - 1e-6)) < 1e-5)
        #expect(cone.backwindEnvelope(at: Self.inTrapezoid(cone, share: 1.01)) == 0)
        #expect(cone.backwindEnvelope(at: cone.apex + cone.axis * (3 * Self.hull)) == 0, "none in her cone")
        // The box's loss is the class's loss × the envelope.
        for share in [0.1, 0.3, 0.7] {
            let p = Self.inTrapezoid(cone, share: share)
            #expect(abs((1 - Self.shadow.backwindLoss * cone.backwindEnvelope(at: p)) - cone.backwindFactor(at: p)) < 1e-12)
            #expect(cone.factor(at: p, lull: Self.shadow.backwindLoss) == cone.factor(at: p))
            #expect(abs(cone.factor(at: p, lull: 0.1) - cone.coneFactor(at: p) * (1 - 0.1 * cone.backwindEnvelope(at: p))) < 1e-15)
        }
    }

    @Test func noHeaderWhileRunning() {
        func cone(twaDegrees: Double) -> ShadowCone {
            ShadowCone(caster: TrailScene.boat(position: .zero, heading: TrailScene.windDirection + deg2rad(twaDegrees), speed: 4),
                       shadow: Self.shadow)
        }
        let running = cone(twaDegrees: 120)
        #expect(running.isRunning && running.backwindPresence == 0)
        for share in [0.01, 0.5] { #expect(running.backwindEnvelope(at: Self.inTrapezoid(running, share: share)) == 0) }
        let cones: [ShadowCone?] = [running, nil]
        #expect(Race.headerTarget(at: Self.inTrapezoid(running, share: 0.01), receiver: 1, cones: cones, settings: ShadowSettings()) == 0)
        // In the fade (90 to 115 degrees) it is part of the way in: at 100 degrees, 0.6.
        let reaching = cone(twaDegrees: 100)
        #expect(abs(reaching.backwindEnvelope(at: Self.inTrapezoid(reaching, share: 1e-6)) - 0.6) < 1e-5)
    }

    @Test func bandClassesHaveNoEnvelope() throws {
        let band = try BoatClassFile.bundled(id: "ilca-dinghy", version: 3).content.windShadow
        #expect(band.backwindInnerLength == nil)
        let cone = ShadowCone(caster: Self.upwindCaster, shadow: band)
        var inBand = 0
        for x in stride(from: -20.0, through: 20, by: 0.5) {
            for y in stride(from: -20.0, through: 20, by: 0.5) {
                let p = Vec2(x, y)
                #expect(cone.backwindEnvelope(at: p) == 0)
                #expect(cone.factor(at: p, lull: 0.5) == cone.factor(at: p))
                if cone.backwindOnlyFactor(at: p, lull: 0.5) < 1 { inBand += 1 }
                // The cone alone times the band alone is the whole.
                #expect(abs(cone.coneFactor(at: p) * cone.backwindOnlyFactor(at: p, lull: 0) - cone.factor(at: p)) < 1e-12)
            }
        }
        #expect(inBand > 0)
    }

    @Test func headerTurnsHerWindTowardsHerBow() throws {
        // Both tacks, never past her bow line.
        let wind = Wind(direction: 0, speed: 5)
        #expect(abs(Race.headed(wind, heading: -0.7, by: 0.05).direction - -0.05) < 1e-15)
        #expect(abs(Race.headed(wind, heading: 0.7, by: 0.05).direction - 0.05) < 1e-15)
        #expect(abs(Race.headed(wind, heading: 0.7, by: 1).direction - 0.7) < 1e-15)
        #expect(Race.headed(wind, heading: 0.7, by: 0.05).speed == 5)
        #expect(abs(Race.headed(Wind(direction: 3.1, speed: 5), heading: -3.0, by: 0.05).direction - -3.1332) < 1e-3, "across ±π")
        // In the race: only the lee-bowed boat's wind turns, by her header, towards her bow.
        let race = try Self.leeBow(Self.settings(.boxes, .headerAndLull)).leeBowed
        let field = try OpenWater.windDirection()
        var headed = 0
        for _ in 0..<(5 * Race.tickRate) {
            let heading = race.boats[0].heading
            race.step()
            let h = race.header(ofSeat: 0)
            let turned = wrapAngle(race.boats[0].windOverGround.direction - field)
            #expect(abs(abs(turned) - h) < 1e-12)
            if h > 0 {
                headed += 1
                #expect(turned * wrapAngle(heading - field) > 0, "towards her bow")
            }
            #expect(race.header(ofSeat: 1) == 0)
            #expect(abs(wrapAngle(race.boats[1].windOverGround.direction - field)) < 1e-12, "the caster's own wind is unchanged")
        }
        #expect(headed > 4 * Race.tickRate)
    }

    @Test func headersStackBySumAndCap() {
        let cone = ShadowCone(caster: Self.upwindCaster, shadow: Self.shadow)
        let p = Self.inTrapezoid(cone, share: 0.25)
        let e = cone.backwindEnvelope(at: p)
        #expect(e > 0.7)
        var s = ShadowSettings()
        s.headerDegrees = 3
        s.headerCapDegrees = 6
        #expect(abs(Race.headerTarget(at: p, receiver: 2, cones: [cone, cone, nil], settings: s) - 2 * deg2rad(3) * e) < 1e-15)
        #expect(abs(Race.headerTarget(at: p, receiver: 1, cones: [cone, nil, cone], settings: s) - 2 * deg2rad(3) * e) < 1e-15)
        #expect(abs(Race.headerTarget(at: p, receiver: 0, cones: [cone, cone], settings: s) - deg2rad(3) * e) < 1e-15, "not her own")
        s.headerCapDegrees = 4
        #expect(Race.headerTarget(at: p, receiver: 2, cones: [cone, cone, nil], settings: s) == deg2rad(4))
    }

    @Test func lullsStackByProductWithFloor() {
        let cone = ShadowCone(caster: Self.upwindCaster, shadow: Self.shadow)
        let p = Self.inTrapezoid(cone, share: 0.05)
        let cones: [ShadowCone?] = [cone, cone, nil]
        for lull in [0.1, 0.3, 0.9] {
            let s = Self.settings(.boxes, .headerAndLull, lull: lull)
            let one = cone.factor(at: p, lull: lull)
            #expect(Race.shadow(at: p, receiver: 2, cones: cones, wake: nil, tick: 0, settings: s, windShadow: Self.shadow)
                    == max(one * one, Self.shadow.stackingFloor))
        }
        // 0.9 at the stern edge: (1 - 0.9 × ~0.95)² is under the floor.
        #expect(Race.shadow(at: p, receiver: 2, cones: cones, wake: nil, tick: 0, settings: Self.settings(.boxes, .headerAndLull, lull: 0.9),
                            windShadow: Self.shadow) == Self.shadow.stackingFloor)
    }

    /// Crossing into her backwind the header follows through its lag: her wind turns no faster than
    /// header / (τ × 30) a tick. The heading steps it causes are printed (none over 1 degree a tick).
    @Test func headerIsLowPassed() throws {
        for tau in [1.5, 0.0] {
            let s = Self.settings(.boxes, .headerAndLull, header: 3, tau: tau)
            // From before the tack, so she crosses into the trapezoid.
            let leeBowed = try LeeBowTests().race(ahead: 3, leeward: 1.5, together: true)
            leeBowed.shadowSettings = s
            leeBowed.step()
            _ = leeBowed.tap(.tackGybe, seat: 1, atTick: leeBowed.tick + 1)
            var header = leeBowed.header(ofSeat: 0), wind = leeBowed.boats[0].windOverGround.direction
            var heading = leeBowed.boats[0].heading
            var steps = (header: 0.0, wind: 0.0, heading: 0.0)
            for _ in 0..<(20 * Race.tickRate) {
                leeBowed.step()
                let b = leeBowed.boats[0]
                steps.header = max(steps.header, abs(leeBowed.header(ofSeat: 0) - header))
                steps.wind = max(steps.wind, abs(wrapAngle(b.windOverGround.direction - wind)))
                steps.heading = max(steps.heading, abs(wrapAngle(b.heading - heading)))
                (header, wind, heading) = (leeBowed.header(ofSeat: 0), b.windOverGround.direction, b.heading)
            }
            print(String(format: "HEADER LAG tau %.1f s: largest step a tick header %.3f deg, her wind %.3f deg, her heading %.3f deg",
                         tau, rad2deg(steps.header), rad2deg(steps.wind), rad2deg(steps.heading)))
            if tau > 0 {
                let bound = deg2rad(3) / (tau * Double(Race.tickRate)) + 1e-12
                #expect(steps.header <= bound && steps.wind <= bound)
                #expect(rad2deg(steps.heading) < 1, "no visible snap")
            }
        }
    }

    // MARK: 6. The sail multiplier and the cadence

    @Test func sailMultiplierReadsTheSailAngle() {
        let boatClass = OpenWater.boatClass, p = R.Parameters.game
        let groove = Self.upwindCaster
        #expect(R.scale(of: groove, ease: true, boatClass: boatClass, parameters: p) == 0, "sheets out")
        var head = groove
        head.heading = TrailScene.windDirection
        TrailScene.refresh(&head)
        #expect(R.scale(of: head, ease: false, boatClass: boatClass, parameters: p) == 0, "head to wind")
        var run = groove
        run.heading = TrailScene.windDirection + .pi * 0.9
        TrailScene.refresh(&run)
        #expect(R.scale(of: run, ease: false, boatClass: boatClass, parameters: p) == 1, "running, stalled")
        let aoa = R.angleOfAttack(groove, ease: false, boatClass: boatClass, parameters: p)
        #expect(aoa > 0)
        var half = p
        half.fullAngleDegrees = 2 * rad2deg(aoa)
        #expect(abs(R.scale(of: groove, ease: false, boatClass: boatClass, parameters: half) - 0.5) < 1e-9)
    }

    @Test func multiplierDropsAtOnceAndBuildsBack() {
        var r = R(shadow: Self.shadow, parameters: .game)
        let b = Self.upwindCaster
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
        var r = R(shadow: Self.shadow, parameters: .game)
        #expect(r.every == 15)
        var b = Self.upwindCaster
        for tick in -61..<31 {
            b.position += b.velocity * Race.dt
            r.step(boats: [b], tick: tick)
        }
        #expect(r.points[0].map(\.born) == [-60, -45, -30, -15, 0, 15, 30])
    }

    // MARK: 7. Determinism

    @Test func ribbonStateReplaysFromTheLog() {
        let s = Self.settings(.both, .headerAndLull)
        let races = (0..<2).map { _ in testRace(seats: Array(repeating: .human, count: 8), prestartSeconds: 20, seed: 377) }
        for race in races {
            race.shadowSettings = s
            _ = race.tap(.tackGybe, seat: 2, atTick: -400)
            _ = race.apply(BoatInput(rudder: 60 as Int8, ease: true), seat: 3, atTick: -500)
            _ = race.apply(.neutral, seat: 3, atTick: -420)
        }
        for _ in 0..<900 {
            for race in races { race.step() }
            #expect(races[0].wake?.points == races[1].wake?.points)
            #expect(races[0].boats.map(\.shadow) == races[1].boats.map(\.shadow))
            #expect(races[0].digest() == races[1].digest())
        }
        #expect((races[0].wake?.pointCount ?? 0) > 0)
    }

    @Test func ghostCastsAndTakesNothing() {
        var r = R(shadow: Self.shadow, parameters: .game)
        var ghost = Self.upwindCaster
        ghost.status = .finished
        #expect(ghost.isGhost)
        for tick in 0..<60 {
            ghost.position += ghost.velocity * Race.dt
            r.step(boats: [ghost], tick: tick)
        }
        #expect(r.pointCount == 0)
        let cones: [ShadowCone?] = [nil, nil]
        #expect(Race.shadow(at: .zero, receiver: 1, cones: cones, wake: r, tick: 60, settings: Self.settings(.ribbons), windShadow: Self.shadow) == 1)
    }

    // MARK: 8. Snapshots

    /// A race restored from a snapshot starts with no wake (`importSnapshot`): the boat in the trail sails in clean air
    /// until it regrows. Prints the pop: her factor each second in the stepped race and in the restored one.
    @Test func restoredRaceRegrowsItsRibbonsAfterAPop() throws {
        let s = Self.settings(.ribbons)
        let stepped = try Self.trailRace(s)
        for _ in 0..<(15 * Race.tickRate) { stepped.step() }
        let restored = try Self.trailRace(s)
        try restored.importSnapshot(stepped.exportSnapshot())
        #expect(restored.wake == nil && stepped.wake != nil)
        var a: [Double] = [], b: [Double] = []
        for _ in 0..<(10 * Race.tickRate) {
            stepped.step()
            restored.step()
            a.append(stepped.boats[1].shadow)
            b.append(restored.boats[1].shadow)
        }
        let lossSeconds = { (xs: [Double]) in xs.reduce(0) { $0 + (1 - $1) } * Race.dt }
        let perSecond = { (xs: [Double]) in stride(from: 0, to: xs.count, by: Race.tickRate).map { String(format: "%.2f", xs[$0]) }.joined(separator: " ") }
        let back = b.firstIndex { $0 < 1 }.map { Double($0) / Double(Race.tickRate) } ?? -1
        print("""
        SNAPSHOT POP seat 1 in seat 0's trail, 10 s after a restore at 15 s:
          stepped  factor/s: \(perSecond(a))  (\(String(format: "%.2f", lossSeconds(a))) loss-s)
          restored factor/s: \(perSecond(b))  (\(String(format: "%.2f", lossSeconds(b))) loss-s); shadow back after \(String(format: "%.1f", back)) s
          gap at the end: \(String(format: "%.3f", (restored.boats[1].position - stepped.boats[1].position).length / Self.hull)) L
        """)
        #expect(lossSeconds(b) < lossSeconds(a), "the pop: she sails clean until the wake regrows")
        #expect(back > 0, "and it does regrow")
    }

    @Test func headerStateResetsOnImport() throws {
        let race = try Self.leeBow(Self.settings(.ribbons, .headerAndLull)).leeBowed
        for _ in 0..<(3 * Race.tickRate) { race.step() }
        #expect(race.header(ofSeat: 0) > 0 && race.wake != nil)
        try race.importSnapshot(race.exportSnapshot())
        #expect(race.header(ofSeat: 0) == 0 && race.wake == nil)
    }

    // MARK: 9. Tuning: the lee-bow

    struct LeeBowRun {
        /// Seat 0's distance made good upwind lost against the clean twin, hull lengths, each tick.
        var lost: [Double] = []
        /// The part of her upwind VMG lost to her angle (height) and to her speed, m/s, each tick.
        var height: [Double] = []
        var speed: [Double] = []
        var lost20: Double { lost.last ?? 0 }
        func lost(at seconds: Int) -> Double { lost[seconds * Race.tickRate - 1] }
        /// Seconds until `series` first reaches half its largest value in the first 10 s.
        static func halfTime(_ series: [Double]) -> Double {
            let early = series.prefix(10 * Race.tickRate)
            let half = (early.max() ?? 0) / 2
            return Double((early.firstIndex { $0 >= half } ?? early.count) + 1) * Race.dt
        }
        var heightHalf: Double { Self.halfTime(height) }
        var speedHalf: Double { Self.halfTime(speed) }
    }

    /// 20 s from the end of seat 1's tack: seat 0's upwind distance made good against the clean twin's, and how she
    /// loses it, to height (her angle to the true wind, at the twin's speed) or to speed.
    static func leeBowRun(_ settings: ShadowSettings) throws -> LeeBowRun {
        let (leeBowed, clean) = try Self.leeBow(settings)
        let field = try OpenWater.windDirection()
        let upwind = Vec2.heading(field)
        let (from, twinFrom) = (leeBowed.boats[0].position, clean.boats[0].position)
        var run = LeeBowRun()
        for _ in 0..<(20 * Race.tickRate) {
            leeBowed.step()
            clean.step()
            let her = leeBowed.boats[0], twin = clean.boats[0]
            let dmg = (her.position - from).dot(upwind), twinDMG = (twin.position - twinFrom).dot(upwind)
            run.lost.append((twinDMG - dmg) / Self.hull)
            let herAngle = abs(wrapAngle(her.heading - field)), twinAngle = abs(wrapAngle(twin.heading - field))
            run.height.append(twin.speed * (RegattaCore.cos(twinAngle) - RegattaCore.cos(herAngle)))
            run.speed.append((twin.speed - her.speed) * RegattaCore.cos(herAngle))
        }
        return run
    }

    /// The table: lee-bow DMG lost over 20 s at the box, and header × lull. The defaults (`ShadowSettings()`'s
    /// header, lull and lag) come out within 10% of the box's.
    @Test func leeBowDistanceMadeGoodOver20s() throws {
        let box = try Self.leeBowRun(ShadowSettings())
        print(String(format: "LEE-BOW box (loss %.2f): DMG lost over 20 s %.3f L; at 5 s %.3f L", Self.shadow.backwindLoss,
                     box.lost20, box.lost(at: 5)))
        for header in [0.0, 2, 3, 4, 6] {
            var row = String(format: "LEE-BOW header %3.0f deg:", header)
            for lull in [0.2, 0.15, 0.1, 0.05, 0.0] {
                let run = try Self.leeBowRun(Self.settings(.boxes, .headerAndLull, header: header, lull: lull))
                row += String(format: "  lull %.2f %.3f L (%+4.0f%%)", lull, run.lost20, (run.lost20 / box.lost20 - 1) * 100)
            }
            print(row)
        }
        let d = ShadowSettings()
        let defaults = try Self.leeBowRun(Self.settings(.boxes, .headerAndLull))
        print(String(format: "LEE-BOW defaults (header %.1f deg, lull %@, tau %.1f s): %.3f L (%+.0f%% of the box)",
                     d.headerDegrees, d.lullLoss.map { String(format: "%.2f", $0) } ?? "class", d.headerTimeConstant,
                     defaults.lost20, (defaults.lost20 / box.lost20 - 1) * 100))
        #expect(abs(defaults.lost20 / box.lost20 - 1) < 0.1)
    }

    /// How she loses it: the box takes only speed; with the header she loses height too. Printed: each part's VMG loss
    /// each second and the time each takes to reach half its peak, by the header's lag. At the defaults she loses
    /// height no later than speed.
    @Test func headerLosesHeightBeforeSpeed() throws {
        let box = try Self.leeBowRun(ShadowSettings())
        let headed = try Self.leeBowRun(Self.settings(.boxes, .headerAndLull))
        func row(_ name: String, _ r: LeeBowRun) -> String {
            let f = { (xs: [Double]) in
                stride(from: Race.tickRate - 1, to: 10 * Race.tickRate, by: Race.tickRate).map { String(format: "%5.2f", xs[$0]) }.joined(separator: " ")
            }
            return "  \(name) VMG lost to height m/s: \(f(r.height))\n  \(name) VMG lost to speed  m/s: \(f(r.speed))\n  \(name) DMG lost L:            \(f(r.lost))"
        }
        print("LEE-BOW first 10 s, each second\n\(row("box   ", box))\n\(row("header", headed))")
        for header in [2.0, 3, 3.5, 4, 5] {
            for tau in [0.0, 0.5, 0.75, 1.0, 1.5] {
                let lull: Double? = nil
                let r = try Self.leeBowRun(Self.settings(.boxes, .headerAndLull, header: header, lull: lull, tau: tau))
                print(String(format: "LEE-BOW header %.1f deg, lull %@, tau %.2f s: half the height lost by %.2f s, half the speed by %.2f s; DMG lost 5 s %.3f L, 20 s %.3f L (%+.0f%% of the box)",
                             header, lull.map { String(format: "%.2f", $0) } ?? "class", tau, r.heightHalf, r.speedHalf,
                             r.lost(at: 5), r.lost20, (r.lost20 / box.lost20 - 1) * 100))
            }
        }
        print(String(format: "LEE-BOW box: half the speed lost by %.2f s", box.speedHalf))
        #expect(headed.heightHalf <= headed.speedHalf, "height first: \(headed.heightHalf) s against \(headed.speedHalf) s")
        #expect(box.height.allSatisfy { abs($0) < 1e-3 }, "the box takes only speed")
    }

    // MARK: 10. Cost

    /// `Race.step` at 16 boats with each setting (run it in release: `swift test -c release -Xswiftc -enable-testing
    /// --filter WakeRibbonsTests.costAt16Boats`; host numbers, the ratio is the finding).
    @Test func costAt16Boats() {
        let combos: [ShadowSettings] = [ShadowSettings(), Self.settings(.ribbons), Self.settings(.both),
                                        Self.settings(.boxes, .headerAndLull), Self.settings(.ribbons, .headerAndLull)]
        let clock = ContinuousClock()
        let ticks = 30 * Race.tickRate
        for s in combos {
            let race = testRace(seats: Array(repeating: .human, count: 16), prestartSeconds: 60, seed: 172)
            race.shadowSettings = s
            var maxPoints = 0
            let start = clock.now
            for _ in 0..<ticks {
                race.step()
                maxPoints = max(maxPoints, race.wake?.pointCount ?? 0)
            }
            let d = start.duration(to: clock.now)
            let ms = (Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15) / Double(ticks)
            let bytes = maxPoints * MemoryLayout<R.Point>.stride + (race.wake == nil ? 0 : 16 * 8)
                + (s.backwindModel == .box ? 0 : 16 * 8)
            print(String(format: "COST 16 boats %@/%@: %.4f ms/tick; up to %d points, %d B wake + header state",
                         s.shadowModel.rawValue, s.backwindModel.rawValue, ms, maxPoints, bytes))
        }
    }
}
