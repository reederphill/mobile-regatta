import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #435: bots steer by hand as well as their skill lets them (`HandSteering`, in `BotHelm`), when the class's autohelm
/// doesn't hold a centred rudder.
@Suite struct BotHandSteeringTests {
    static let club = BotTier.club.skill(at: 0.5)
    static let national = BotTier.national.skill(at: 0.5)

    /// Each seat's position every second for `seconds` of a seeded race of `seats` bots sailing `boatClass`, each seat's
    /// bot `driver(seat, raceSeed)`.
    static func track(seed: UInt64, boatClass: BoatClassFile, seconds: Int, seats: Int = 2,
                      driver: (Int, RaceSeed) -> BotDriver) throws -> [[Vec2]] {
        let race = try BotHelmTests.race(seed: seed, boatClass: boatClass, seats: seats)
        var controllers = SeatControllers(race.boats.indices.map { .bot(driver($0, race.setup.raceSeed)) })
        var track: [[Vec2]] = []
        sail(race, &controllers, ticks: seconds * Race.tickRate) { race in
            if race.tick % Race.tickRate == 0 { track.append(race.boats.map(\.position)) }
        }
        return track
    }

    /// A two-seat race sailing `boatClass` in `wind` (by tick), the same everywhere, in a ten minute start sequence: seat 0 at
    /// the race area's centre at `sailingAngle` on port boom at the polar's speed, the rudder centred and no
    /// autohelm; seat 1 far from her.
    static func scriptedRace(boatClass: BoatClassFile, sailingAngle: Double,
                             wind: @escaping (Int) -> GroundWind) throws -> Race {
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(boatClass)
        let setup = try RaceSetup(raceSeed: RaceSeed(3), seats: [.bot, .bot], laps: 1,
                                  startSequenceTicks: 600 * Race.tickRate, boatClass: boatClass.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: WindSeed(3)),
                            current: CurrentField(current: nil, tideStateAtGun: 0), wind: wind)
        race.step()
        var snapshot = race.exportSnapshot()
        // Inside the race area, which a boat outside of owes a penalty for, and is disqualified for not serving.
        let area = race.course.raceArea
        var boat = snapshot.seats[0].boat
        boat.position = area.centre
        boat.rudder = 0
        boat.desiredRudder = 0
        boat.autohelm = nil
        boat.boomSide = .port
        boat.heading = wrapAngle(boat.windDirection - BoomSide.port.windSign * sailingAngle)
        boat.speed = race.boatClass.polar.speed(twa: sailingAngle, tws: boat.windSpeed)
        snapshot.seats[0].boat = boat
        snapshot.seats[0].heldInput = .neutral
        snapshot.seats[1].boat.position = area.centre + race.course.right * area.halfWidth * 0.8
        try race.importSnapshot(snapshot)
        return race
    }

    /// Seat 0 held by `helm` alone, her brain always centring the rudder, for `seconds`; `each` sees her boat each tick.
    static func hold(_ race: Race, _ helm: inout BotHelm, seconds: Double, each: (Boat) -> Void = { _ in }) {
        for _ in 0..<Int(seconds * Double(Race.tickRate)) {
            if race.tick.isMultiple(of: BotDriver.decisionInterval) {
                race.apply(helm.input(BoatInput.neutral, race.seatView(for: 0)), seat: 0, atTick: race.tick + 1)
            }
            race.step()
            each(race.boats[0])
        }
    }

    /// The app's bot for `seat` (a Mixed fleet's draw, `BotDriver(seat:raceSeed:)`), but steering by hand as `hands`
    /// does: her brain sails exactly as hers.
    static func steering(like hands: BotWeaknesses) -> (Int, RaceSeed) -> BotDriver {
        { seat, raceSeed in
            let skill = BotTier.mixedFleetDraw(seed: botSeed(raceSeed: raceSeed, seat: seat)).skill
            return BotDriver(seat: seat, raceSeed: raceSeed, skill: skill,
                             weaknesses: BotWeaknesses(skill: skill).steering(like: hands))
        }
    }

    /// Skill 1.0 steers by hand perfectly: none of the three, so with the autohelm off she sails `BotHelm`'s own track,
    /// within #434's tolerance of the autohelm's (seed 5's two bots, five minutes: the start, a beat and a run; 2 hull
    /// lengths at worst, 1 on average). Club hand steering on the same bots leaves that track; with the autohelm on,
    /// hand steering is never felt and the race is today's to the bit.
    @Test func skillOneMatchesAutohelm() throws {
        let top = BotWeaknesses(skill: 1)
        #expect(top.shiftLag == 0 && top.wander == 0 && top.overshoot == 0)
        #expect(BotWeaknesses.none(skill: 0.9).shiftLag == 0 && BotWeaknesses.none(skill: 0.9).wander == 0)
        for seat in 0..<4 {
            #expect(HandSteering(top, seed: botSeed(raceSeed: RaceSeed(5), seat: seat)).isPerfect)
            #expect(!HandSteering(BotWeaknesses(skill: 0.9), seed: botSeed(raceSeed: RaceSeed(5), seat: seat)).isPerfect)
        }

        let seed: UInt64 = 5
        let off = try BotHelmTests.skiff(holds: false)
        let autohelm = try Self.track(seed: seed, boatClass: RaceFiles.defaults.boatClass, seconds: 300) { seat, raceSeed in
            BotDriver(seat: seat, raceSeed: raceSeed)
        }
        let perfect = try Self.track(seed: seed, boatClass: off, seconds: 300, driver: Self.steering(like: top))
        #expect(perfect.count == autohelm.count)
        let hull = RaceFiles.defaults.boatClass.content.hull.length
        var worst = 0.0
        var total = 0.0
        for (a, b) in zip(autohelm, perfect) {
            for (p, q) in zip(a, b) {
                let d = (p - q).length / hull
                worst = max(worst, d)
                total += d
            }
        }
        #expect(worst < 2, "a perfect hand strayed \(worst) hull lengths from the autohelm's track")
        #expect(total / Double(autohelm.count * 2) < 1)

        let club = try Self.track(seed: seed, boatClass: off, seconds: 120, driver: Self.steering(like: .clubHandSteering))
        #expect(club != Array(perfect.prefix(club.count)), "Club hand steering sailed the perfect hand's track")
        let clubOnAutohelm = try Self.track(seed: seed, boatClass: RaceFiles.defaults.boatClass, seconds: 120,
                                            driver: Self.steering(like: .clubHandSteering))
        #expect(clubOnAutohelm == Array(autohelm.prefix(clubOnAutohelm.count)))
    }

    /// Seconds after a 10° shift at 20 s until seat 0, held on a reach by a helm with `weaknesses`' shift lag (and no
    /// wander or overshoot, which would blur it), has turned 5° with it.
    static func turnDelay(_ weaknesses: BotWeaknesses, shift: Double) throws -> Double {
        let shiftTick = 20 * Race.tickRate
        let race = try scriptedRace(boatClass: BotHelmTests.skiff(holds: false), sailingAngle: deg2rad(70)) { tick in
            GroundWind(direction: tick < shiftTick ? 0 : shift, speed: metresPerSecond(knots: 10))
        }
        var hand = BotWeaknesses.none(skill: 1)
        hand.shiftLag = weaknesses.shiftLag
        var helm = BotHelm(hand: HandSteering(hand, seed: 7))
        hold(race, &helm, seconds: Double(shiftTick - race.tick) / Double(Race.tickRate))
        let before = race.boats[0].heading
        var turned: Double?
        let start = race.tick
        hold(race, &helm, seconds: 8) { boat in
            if turned == nil, abs(wrapAngle(boat.heading - before)) >= deg2rad(5) {
                turned = Double(race.tick - start) / Double(Race.tickRate)
            }
        }
        return try #require(turned, "she never turned with the shift")
    }

    /// Club re-aims to a scripted shift later than National, which re-aims later than a perfect hand: her lag grows with
    /// her skill deficit (≈ 2.1 s at Club's centre, ≈ 0.4 s at National's).
    @Test func lagScalesWithSkill() throws {
        let club = BotWeaknesses(skill: Self.club)
        let national = BotWeaknesses(skill: Self.national)
        #expect(abs(club.shiftLag - 4 * (1 - Self.club)) < 1e-9)
        #expect(club.shiftLag > national.shiftLag && national.shiftLag > 0)
        for shift in [deg2rad(10), deg2rad(-10)] {
            let perfect = try Self.turnDelay(.none(skill: 1), shift: shift)
            let nationalDelay = try Self.turnDelay(national, shift: shift)
            let clubDelay = try Self.turnDelay(club, shift: shift)
            #expect(perfect <= nationalDelay, "perfect \(perfect) s, National \(nationalDelay) s")
            #expect(clubDelay - nationalDelay > 1, "Club \(clubDelay) s, National \(nationalDelay) s")
            #expect(clubDelay >= club.shiftLag, "Club turned \(clubDelay) s after the shift, inside her lag")
        }
    }

    /// Wander is her seed's: the same seed wanders the same way, seeds wander differently (period in 20…40 s), never past
    /// her skill's amplitude; held on a reach in a steady wind her angle drifts about her aim by about that and no more.
    @Test func wanderIsSeededAndBounded() throws {
        let club = BotWeaknesses(skill: Self.club)
        #expect(abs(club.wander - HandSteeringTable.wanderScale * (1 - Self.club)) < 1e-9)
        let hands = (1...12).map { HandSteering(club, seed: botSeed(raceSeed: RaceSeed(9), seat: $0)) }
        #expect(hands[0] == HandSteering(club, seed: botSeed(raceSeed: RaceSeed(9), seat: 1)))
        #expect(Set(hands.map(\.wanderPeriod)).count == hands.count)
        for hand in hands {
            #expect(HandSteeringTable.wanderPeriod.contains(hand.wanderPeriod))
            let samples = (0..<(120 * Race.tickRate)).map(hand.wander(atTick:))
            #expect(samples.allSatisfy { abs($0) <= club.wander })
            #expect(samples.map(abs).max()! > 0.95 * club.wander)
        }
        #expect(hands[0].wander(atTick: 300) != hands[1].wander(atTick: 300))
        #expect(HandSteering(BotWeaknesses(skill: 1), seed: 1).wander(atTick: 300) == 0)

        // Held by hand in a steady breeze: about her aim by her wander, and no further.
        let aim = deg2rad(70)
        let race = try Self.scriptedRace(boatClass: BotHelmTests.skiff(holds: false), sailingAngle: aim) { _ in
            GroundWind(direction: 0, speed: metresPerSecond(knots: 10))
        }
        var helm = BotHelm(hand: HandSteering(BotWeaknesses.none(skill: 1).steering(like: club), seed: 11))
        var worst = 0.0
        Self.hold(race, &helm, seconds: 45) { boat in worst = max(worst, abs(wrapAngle(boat.sailingAngle - aim))) }
        #expect(worst <= club.wander + deg2rad(0.5), "she wandered \(rad2deg(worst))° off her aim")
        #expect(worst >= 0.5 * club.wander, "she wandered only \(rad2deg(worst))°")
    }

    /// A re-aim while her last overshoot still decays carries what's left of it on (#435 review), never past her overshoot
    /// (#435 fix round): two 2° shifts half a second apart each take her her whole overshoot past the wind, however small
    /// the shift, the second on top of what's left of the first, and it all decays back to her aim.
    @Test func reAimCarriesTheDecayingOvershoot() throws {
        let firstTick = 20 * Race.tickRate
        let secondTick = firstTick + Race.tickRate / 2
        let race = try Self.scriptedRace(boatClass: BotHelmTests.skiff(holds: false), sailingAngle: deg2rad(70)) { tick in
            GroundWind(direction: tick < firstTick ? 0 : deg2rad(tick < secondTick ? 2 : 4), speed: metresPerSecond(knots: 10))
        }
        let cap = deg2rad(5)
        let hand = HandSteering(shiftLag: 0, wander: 0, wanderPeriod: 30, wanderPhase: 0, overshoot: cap)
        var steered: HandSteering.SteeredWind?
        var reAims: [(before: Double, after: Double)] = []
        var lastOffset = 0.0
        var offset = 0.0
        while race.tick < firstTick + 6 * Race.tickRate {
            let own = race.seatView(for: 0).own
            let previous = steered
            let wind = hand.steer(&steered, own: own, tick: race.tick)
            offset = wrapAngle(wind.direction - steered!.direction)
            if let previous, steered!.overshootTick == race.tick, previous.overshootTick != race.tick {
                reAims.append((before: lastOffset, after: offset))
            }
            lastOffset = offset
            race.step()
        }
        #expect(reAims.count >= 2)
        for reAim in reAims {
            // What was left goes on into the new overshoot, the way the wind swung, up to her overshoot: all of it.
            #expect(reAim.after >= reAim.before - 1e-12)
            #expect(abs(reAim.after - cap) < 1e-12, "a re-aim to a 2° shift overshot by \(rad2deg(reAim.after))°")
        }
        #expect(abs(offset) < 1e-12, "her overshoot never decayed")
    }

    /// Seconds `hand` loses against a perfect hand over `seconds`, held on her groove upwind or down (the autohelm's snap
    /// takes it) on starboard tack, through the race area's centre, in 10 knots shifting ±6° over 50 s and ±3° over 13 s
    /// and puffing ±12% over 31 s, or `steady`; averaged over four seeds of her wander.
    static func loss(_ hand: BotWeaknesses, upwind: Bool, seconds: Double, steady: Bool) throws -> Double {
        let boatClass = try BotHelmTests.skiff(holds: false)
        let tws = metresPerSecond(knots: 10)
        let polar = boatClass.content.polar
        let angle = upwind ? polar.bestUpwind(tws: tws).twa : polar.bestDownwind(tws: tws).twa
        func made(_ weaknesses: BotWeaknesses, seed: UInt64) throws -> Double {
            let race = try scriptedRace(boatClass: boatClass, sailingAngle: angle) { tick in
                if steady { return GroundWind(direction: 0, speed: tws) }
                let t = Double(tick) / Double(Race.tickRate)
                return GroundWind(direction: deg2rad(6) * Foundation.sin(2 * .pi * t / 50) + deg2rad(3) * Foundation.sin(2 * .pi * t / 13),
                                  speed: tws * (1 + 0.12 * Foundation.sin(2 * .pi * t / 31)))
            }
            // Started so that she sails through the race area's centre and never meets its edge.
            var snapshot = race.exportSnapshot()
            let boat = snapshot.seats[0].boat
            snapshot.seats[0].boat.position = race.course.raceArea.centre
                - Vec2.heading(boat.heading) * boat.speed * 1.1 * (seconds + 10) / 2
            try race.importSnapshot(snapshot)
            var helm = BotHelm(hand: HandSteering(weaknesses, seed: seed))
            hold(race, &helm, seconds: 10)
            let start = race.boats[0].position
            hold(race, &helm, seconds: seconds)
            let end = race.boats[0]
            #expect(end.status == .prestart && race.course.isInRaceArea(end.position),
                    "she left the race area: \(end.status) at \(end.position - race.course.raceArea.centre), \(end.speed) m/s")
            return (end.position - start).dot(.heading(0))
        }
        var lost = 0.0
        let seeds: [UInt64] = [1, 2, 3, 4]
        for seed in seeds {
            let perfect = try made(.none(skill: 1), seed: seed)
            lost += (perfect - (try made(BotWeaknesses.none(skill: 1).steering(like: hand), seed: seed))) / perfect * seconds
        }
        return lost / Double(seeds.count)
    }

    /// Steering by hand costs time on every leg (#435 fix round): held on the groove in a shifty, puffy breeze and in a
    /// steady one, Club hand steering loses time against a perfect hand upwind and down, and National less. Her shift
    /// lag alone would pay in the shifty breeze, in the skiff's momentum (it gains speed in 2.5 s and loses it over 10, so
    /// a lagged heading sails a short foot-then-pinch); her whole overshoot on every re-aim and her wander make her
    /// imperfection cost.
    @Test func clubHandLosesTimeOnABeatAndARun() throws {
        let national = BotWeaknesses(skill: Self.national)
        for steady in [false, true] {
            let beat = try Self.loss(.clubHandSteering, upwind: true, seconds: 60, steady: steady)
            let run = try Self.loss(.clubHandSteering, upwind: false, seconds: 40, steady: steady)
            #expect(beat > 1, "Club lost \(beat) s in a 60 s beat (steady: \(steady))")
            #expect(run > 1, "Club lost \(run) s in a 40 s run (steady: \(steady))")
            let nationalBeat = try Self.loss(national, upwind: true, seconds: 60, steady: steady)
            let nationalRun = try Self.loss(national, upwind: false, seconds: 40, steady: steady)
            #expect(nationalBeat < beat && nationalRun < run,
                    "National lost \(nationalBeat) s a beat and \(nationalRun) s a run; Club \(beat) s and \(run) s")
            print("HAND-STEERING-LOSS steady=\(steady) club beat \(beat) run \(run) national beat \(nationalBeat) run \(nationalRun)")
        }
    }
}
