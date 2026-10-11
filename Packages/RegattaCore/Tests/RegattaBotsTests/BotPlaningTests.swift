import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #462: bots on skiff@9, the class a bad gybe, a run too deep and a lull take off the plane.
@Suite struct BotPlaningTests {
    static let skiffNine = try! BoatClassFile.bundled(id: "skiff", version: 9)

    /// What a fleet's planing came to over a race on `boatClass`.
    struct Planing {
        /// Decisions racing off the wind, and those where what she reckons (`Senses.planing`) is what her boat does.
        var decisions = 0
        var agreeing = 0
        /// Seconds racing off the wind in a wind that planes, and off the plane, summed over the fleet.
        var running = 0.0
        var off = 0.0
        var finished = 0
    }

    static func planing(seed: UInt64, boatClass: BoatClassFile, seconds: Int) throws -> Planing {
        let race = try BotHelmTests.race(seed: seed, boatClass: boatClass)
        var controllers = allBots(race)
        var result = Planing()
        let tuning = try #require(race.boatClass.planing)
        for _ in 0..<(seconds * Race.tickRate) where !race.isOver {
            controllers.drive(race)
            for (seat, boat) in race.boats.enumerated() {
                guard boat.status == .racing, boat.penaltyTurnsOwed == 0, boat.twa >= deg2rad(100) else { continue }
                if let driver = controllers[seat].driver, driver.decides(atTick: race.tick) {
                    result.decisions += 1
                    if driver.brain.senses.planing == boat.isPlaning { result.agreeing += 1 }
                }
                guard race.boatClass.polar.bestDownwind(tws: boat.polarWindSpeed(in: race.boatClass)).speed >= tuning.onSpeed else { continue }
                result.running += Race.dt
                if !boat.isPlaning { result.off += Race.dt }
            }
            race.step()
        }
        result.finished = race.boats.filter { $0.status == .finished }.count
        return result
    }

    /// "She knows when she is off": what a bot reckons of her planing is the class's rule, with her rudder and her
    /// polar, so on skiff@9 it is what her boat does at nearly every decision (she decides every third tick, and the
    /// rule's only memory is whether she was planing: a miss corrects itself within a second or two).
    @Test func botKnowsWhenSheIsOffThePlane() throws {
        for seed in [UInt64(462), 3] {
            let seen = try Self.planing(seed: seed, boatClass: Self.skiffNine, seconds: 700)
            let share = Double(seen.agreeing) / Double(max(seen.decisions, 1))
            print("BOTPLANING senses seed \(seed): \(seen.agreeing)/\(seen.decisions) = \(share); off \(seen.off / max(seen.running, 1)) of \(seen.running) s; finished \(seen.finished)")
            #expect(seen.decisions > 2000)
            #expect(share >= 0.97, "seed \(seed): \(share)")
        }
    }

    // MARK: - One bot, one fall

    /// Seat 0 alone on `boatClass` (skiff@9) on seed `seed`'s water, running on starboard with the spinnaker up,
    /// `deep` radians deeper than her groove, on the plane or just off it, at `speed` of her groove's speed; a
    /// groove-only bot (the baseline's tactics, no weaknesses) turning at `handling`. `edit` the snapshot further.
    static func runner(seed: UInt64, planing: Bool, speed: Double = 1, deep: Double = 0, handling: Double,
                       boatClass: BoatClassFile = skiffNine, edit: (inout WorldSnapshot) -> Void = { _ in })
        throws -> (race: Race, hand: BotHandTackTests.Hand, water: BotConductTests.Water) {
        let water = BotConductTests.$waterClass.withValue(boatClass.ref) { BotConductTests.Water(seed: seed, running: true) }
        let heading = water.heading(.starboard, water.down.twa + deep)
        let race = try BotConductTests.place(water, [
            .init(position: water.centre + water.race.course.upwind.rightPerp * 25, heading: heading, speed: water.down.speed * speed),
            .init(position: water.centre + Vec2.heading(water.wind).rightPerp * 400, heading: water.run(.starboard),
                  speed: water.down.speed),
        ]) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 0
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = nil
            snapshot.seats[0].boat.isPlaning = planing
            snapshot.seats[0].boat.spinnaker = .up
            edit(&snapshot)
        }
        var hand = BotHandTackTests.Hand(seat: 0, race: race, handling: handling)
        hand.brain.senses.planing = planing
        return (race, hand, water)
    }

    struct Recovery {
        var knots: Double
        /// Seconds until she is planing again, and until she is back within 5° of her groove on the plane; nil: never.
        var backOn: Double?
        var onGroove: Double?
        /// The highest she luffed above her groove, degrees, and her falls after she was first back on.
        var luffed = 0.0
        var fallsAgain = 0
    }

    /// A bot just off the plane on her groove (`speed` of her target speed), sailed `seconds`.
    static func recovery(seed: UInt64, handling: Double, speed: Double = 0.6, seconds: Double = 18) throws -> Recovery {
        var (race, hand, _) = try runner(seed: seed, planing: false, speed: speed, handling: handling)
        var result = Recovery(knots: knots(metresPerSecond: race.groundWind(at: race.boats[0].position).speed))
        var was = false
        for tick in 0..<Int(seconds * Double(Race.tickRate)) {
            hand.drive(race)
            race.step()
            let boat = race.boats[0]
            let t = Double(tick + 1) * Race.dt
            let tws = boat.polarWindSpeed(in: race.boatClass)
            let groove = race.boatClass.polar.bestDownwind(tws: tws)
            result.luffed = max(result.luffed, rad2deg(groove.twa - boat.twa))
            if boat.isPlaning, result.backOn == nil { result.backOn = t }
            if was, !boat.isPlaning { result.fallsAgain += 1 }
            if boat.isPlaning, result.onGroove == nil, abs(groove.twa - boat.twa) < deg2rad(5), result.backOn != nil { result.onGroove = t }
            was = boat.isPlaning
        }
        return result
    }

    /// "Head up to plane after a drop", every bot: off the plane on her groove at 60 % of her speed, in 9 to 13 kn, a
    /// groove-only bot (the baseline's tactics, which never re-planed before #462) luffs, is planing again in seconds,
    /// and is back on her groove up to speed without dropping off again. Her handling is how soon: the top draw in 4.6
    /// to 10.5 s (the class's own time from a standstill start off the plane: 4.5 s at 10 kn, 6.4 s at 14), Club's
    /// centre in 7.1 to 11.7 s, the floor of Club's band in 8.6 to 13.5 s.
    @Test func fallenBotHeadsUpAndPlanesAgain() throws {
        var means: [Double] = []
        for (handling, within) in [(1.0, 12.0), (0.55, 13.5), (0.3, 15.5)] {
            var total = 0.0
            for seed in UInt64(1)...6 {
                let r = try Self.recovery(seed: seed, handling: handling)
                print("BOTPLANING recovery h=\(handling) seed \(seed) \((r.knots * 10).rounded() / 10) kn: back on \(r.backOn ?? -1) s, on her groove \(r.onGroove ?? -1) s, luffed \(Int(r.luffed))°, fell again \(r.fallsAgain)")
                let backOn = try #require(r.backOn, "h \(handling), seed \(seed): never back on the plane")
                #expect(backOn <= within, "h \(handling), seed \(seed): back on after \(backOn) s")
                #expect(r.luffed >= 8, "h \(handling), seed \(seed): she luffed \(r.luffed)°")
                let onGroove = try #require(r.onGroove, "h \(handling), seed \(seed): never back on her groove")
                #expect(onGroove > backOn && onGroove <= within + 5, "h \(handling), seed \(seed): on her groove after \(onGroove) s")
                #expect(r.fallsAgain == 0, "h \(handling), seed \(seed): fell off again")
                total += backOn
            }
            means.append(total / 6)
        }
        #expect(means[0] + 1 < means[1] && means[1] + 1 < means[2], "mean seconds back on by handling: \(means)")
    }

    /// The decision's view for `hand`'s seat, taken in as her brain takes it in.
    static func seen(_ race: Race, _ hand: inout BotHandTackTests.Hand) -> SeatView {
        let view = hand.helm.view(race.seatView(for: 0))
        hand.brain.observe(view.own, view)
        return view
    }

    /// Everything here is behind "the class has the new planing rule": skiff@9 has it, skiff@8 and older do not.
    @Test func onlyAClassWithTheNewRuleIsSailedThisWay() throws {
        #expect(BotBrain.hasPlaningRule(Self.skiffNine.content))
        for version in 1...8 {
            #expect(!BotBrain.hasPlaningRule(try BoatClassFile.bundled(id: "skiff", version: version).content), "skiff@\(version)")
        }
        // On skiff@8 a groove-only bot off the plane is not headed up, and a deep aim is sailed as asked.
        var (race, hand, _) = try Self.runner(seed: 3, planing: false, speed: 0.6, handling: 1, boatClass: BotHandTackTests.skiffEight)
        let view = Self.seen(race, &hand)
        let deep = Aim(angle: view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa + deg2rad(15), tack: .starboard)
        #expect(hand.brain.downwindAim(view.own, view, aim: deep) == deep)
        #expect(hand.brain.replane == nil)
    }

    /// "Keep the wind in her sails": planing in her groove, asked for an angle 15° deeper (a groove she misses, a
    /// mark below her), she sails no deeper than leaves her half a knot of apparent wind over the class's floor at
    /// her polar speed; 4° deeper than the groove she sails as asked. A bot who reads the lulls, faster than her
    /// polar for the wind she has (the wind has dropped under her), heads up above her groove; one who does not,
    /// sails on.
    @Test func deepAimIsHeldToWhatPlanes() throws {
        for seed in UInt64(1)...6 {
            var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: 1)
            let view = Self.seen(race, &hand)
            let tws = view.own.polarWindSpeed
            let polar = view.boatClass.polar, groove = polar.bestDownwind(tws: tws)
            let floor = try #require(view.boatClass.planing?.apparentWind)
            let held = hand.brain.downwindAim(view.own, view, aim: Aim(angle: groove.twa + deg2rad(15), tack: .starboard))
            let apparent = BoatClass.PlaningTuning.apparentWindSpeed(twa: held.angle, speed: polar.speed(twa: held.angle, tws: tws), tws: tws)
            print("BOTPLANING floor seed \(seed) \(knots(metresPerSecond: tws)) kn: asked \(rad2deg(groove.twa) + 15)°, sails \(rad2deg(held.angle))°, apparent \(knots(metresPerSecond: apparent)) kn")
            #expect(held.angle < groove.twa + deg2rad(12) && held.angle >= groove.twa, "seed \(seed): \(rad2deg(held.angle))°")
            #expect(apparent >= floor.offSpeed(tws: tws) + PlaningTable.floorMargin - 0.05, "seed \(seed): \(apparent) m/s")
            let little = Aim(angle: groove.twa + deg2rad(4), tack: .starboard)
            #expect(hand.brain.downwindAim(view.own, view, aim: little) == little, "seed \(seed)")
        }
        // The wind has dropped by two fifths under her: her groove still reads the wind before (its running average),
        // and the groove she is asked for is that wind's, deeper than planes in the wind she has now.
        var (race, hand, _) = try Self.runner(seed: 3, planing: true, handling: 1)
        let view = Self.seen(race, &hand)
        let before = view.own.polarWindSpeed / 0.6
        hand.brain.senses.grooveWind = before
        let groove = Aim.groove(.downwind, tack: .starboard, angle: view.boatClass.polar.bestDownwind(tws: before).twa)
        #expect(hand.brain.downwindAim(view.own, view, aim: groove) == groove, "she does not read the lulls")
        hand.brain.tactics.heatsUpInLulls = true
        let heated = hand.brain.downwindAim(view.own, view, aim: groove)
        print("BOTPLANING lull: groove \(rad2deg(groove.angle))°, heated \(rad2deg(heated.angle))°")
        #expect(heated.angle <= groove.angle - deg2rad(1.5), "\(rad2deg(heated.angle))°")
    }

    /// "The kite goes soft, she heads up": planing deeper than her groove with the rudder centred (where her hand's
    /// wander takes her), her apparent wind 0.4 kn over what the class drops her off at, she luffs from
    /// where she is, 6° a decision, steering whatever her hand holds, and stays on the plane. In her groove she sails
    /// on.
    @Test func softKiteLuffsHerFromWhereSheIs() throws {
        for seed in UInt64(1)...6 {
            // How deep leaves her that: read off this water's wind.
            var deep = 0.0
            do {
                var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: 1)
                let view = Self.seen(race, &hand)
                let tws = view.own.polarWindSpeed
                let floor = try #require(view.boatClass.planing?.apparentWind).offSpeed(tws: tws)
                while BoatClass.PlaningTuning.apparentWindSpeed(twa: view.own.twa + deep, speed: view.own.speed, tws: tws)
                    > floor + metresPerSecond(knots: 0.4) { deep += deg2rad(0.25) }
            }
            var (race, hand, _) = try Self.runner(seed: seed, planing: true, deep: deep, handling: 1)
            let view = Self.seen(race, &hand)
            #expect(hand.brain.senses.planing)
            let groove = view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa
            let luff = hand.brain.downwindAim(view.own, view, aim: .groove(.downwind, tack: .starboard, angle: groove))
            #expect(luff.insists, "seed \(seed)")
            #expect(abs(luff.angle - min(groove, groove + deep - PlaningTable.luffStep)) < deg2rad(0.5), "seed \(seed): \(rad2deg(luff.angle))°")
            var off = 0.0
            for _ in 0..<(8 * Race.tickRate) {
                hand.drive(race)
                race.step()
                if !race.boats[0].isPlaning { off += Race.dt }
            }
            let twa = race.boats[0].twa, now = race.boatClass.polar.bestDownwind(tws: race.boats[0].polarWindSpeed(in: race.boatClass)).twa
            print("BOTPLANING reflex seed \(seed): \(rad2deg(deep))° deep, off \(off) s, after 8 s \(rad2deg(twa - now))° off her groove")
            #expect(deep > deg2rad(5), "seed \(seed): \(rad2deg(deep))°")
            // Seed 2's wind is building under her as she luffs: a quarter of a second off, and on again.
            #expect(off <= (seed == 2 ? 0.5 : 0), "seed \(seed): off the plane \(off) s")
            #expect(abs(twa - now) < deg2rad(6), "seed \(seed): \(rad2deg(twa - now))° off her groove")
        }
        var (race, hand, _) = try Self.runner(seed: 3, planing: true, handling: 1)
        let view = Self.seen(race, &hand)
        let groove = Aim.groove(.downwind, tack: .starboard, angle: view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa)
        #expect(hand.brain.downwindAim(view.own, view, aim: groove) == groove)
    }

    /// "Bear away gently": planing on a reach, asked for an angle 30° deeper, a good helm bears away with the rudder
    /// she gybes with (30 %), a poor one with all of it; off the plane, and on skiff@8, with all the helm gives.
    @Test func planingSheBearsAwayWithHerGybesRudder() throws {
        func rudder(handling: Double, planing: Bool, boatClass: BoatClassFile = Self.skiffNine) throws -> Double {
            var (race, hand, _) = try Self.runner(seed: 3, planing: planing, deep: deg2rad(-30), handling: handling, boatClass: boatClass)
            let view = Self.seen(race, &hand)
            hand.brain.senses.planing = planing
            let groove = view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa
            return abs(hand.brain.helm(view.own, to: Aim(angle: groove, tack: .starboard), view).rudderValue)
        }
        #expect(abs(try rudder(handling: 1, planing: true) - HandTackTable.gybeFraction.good) < 0.01)
        #expect(abs(try rudder(handling: 0.5, planing: true) - HandTackTable.gybeFraction(handling: 0.5)) < 0.01)
        #expect(try rudder(handling: 0.2, planing: true) > 0.99)
        #expect(try rudder(handling: 1, planing: false) > 0.99)
        #expect(try rudder(handling: 1, planing: true, boatClass: BotHandTackTests.skiffEight) > 0.99)
    }

    /// `hand`'s bot with the hand steering of `handling` (its wander, lag and overshoot; `Hand`'s own has none): her
    /// brain reckons with it, and her helm steers by it if `steers`.
    static func wandering(_ hand: inout BotHandTackTests.Hand, _ race: Race, handling: Double, steers: Bool = false, seed: UInt64 = 1) {
        var brain = BotBrain(style: BotConductTests.skill1, profile: .baseline, seed: seed,
                             weaknesses: BotWeaknesses(skill: 1, handling: handling))
        brain.tactics.headerThreshold = nil
        brain.tactics.downwindShiftThreshold = nil
        brain.tactics.corridor = 100
        brain.plannedTack = race.boats[0].tack
        brain.laylineError = (race.boats[0].legIndex, .pi / 3)
        brain.senses = hand.brain.senses
        hand.brain = brain
        if steers { hand.helm = BotHelm(hand: HandSteering(brain.weaknesses, seed: seed)) }
    }

    /// "Inside her own hand" (bots err on the side of caution): planing in her groove, a perfect hand sails the groove
    /// she is asked for; the poorer her handling the further above it she aims, by what her hand wanders: 1.6 of her
    /// wander running deeper than her aim she still has the apparent wind the class planes on and half a knot. It is
    /// the same angle when her hand has carried her deep of it. On skiff@8 she sails as asked.
    @Test func sheAimsInsideHerOwnHand() throws {
        for seed in UInt64(1)...6 {
            var hotter: [Double] = []
            for handling in [1.0, 0.8, 0.55, 0.35] {
                var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: handling)
                Self.wandering(&hand, race, handling: handling)
                let view = Self.seen(race, &hand)
                let tws = view.own.polarWindSpeed
                let polar = view.boatClass.polar
                let groove = Aim.groove(.downwind, tack: .starboard, angle: polar.bestDownwind(tws: tws).twa)
                let sailed = hand.brain.downwindAim(view.own, view, aim: groove)
                hotter.append(rad2deg(groove.angle - sailed.angle))
                let wander = PlaningTable.handMargin * hand.brain.weaknesses.wander * HandSteeringTable.downwindWander
                let deep = min(sailed.angle + wander, .pi)
                let apparent = BoatClass.PlaningTuning.apparentWindSpeed(twa: deep, speed: polar.speed(twa: deep, tws: tws), tws: tws)
                let floor = try #require(view.boatClass.planing?.apparentWind)
                #expect(apparent >= floor.offSpeed(tws: tws) + PlaningTable.floorMargin - 0.05, "seed \(seed), h \(handling): \(apparent) m/s")
                if handling == 1 { #expect(sailed == groove, "seed \(seed)") }
                // Her hand has carried her 7° deep: the same aim.
                var (deepRace, deepHand, _) = try Self.runner(seed: seed, planing: true, deep: deg2rad(7), handling: handling)
                Self.wandering(&deepHand, deepRace, handling: handling)
                let deepView = Self.seen(deepRace, &deepHand)
                let again = deepHand.brain.downwindAim(deepView.own, deepView, aim: groove)
                if !again.insists { #expect(abs(again.angle - sailed.angle) < deg2rad(0.01), "seed \(seed), h \(handling): \(rad2deg(again.angle))° deep, \(rad2deg(sailed.angle))° in her groove") }
            }
            print("BOTPLANING own hand seed \(seed): above her groove by handling 1 / 0.8 / 0.55 / 0.35: \(hotter.map { ($0 * 10).rounded() / 10 })°")
            #expect(hotter[0] == 0 && hotter[1] <= hotter[2] && hotter[2] <= hotter[3], "seed \(seed): \(hotter)")
            #expect(hotter[1] <= 3, "seed \(seed): a good hand \(hotter[1])° above her groove")
            #expect(hotter[2] >= 2 && hotter[3] >= hotter[2] + 3, "seed \(seed): \(hotter)")
        }
        var (race, hand, _) = try Self.runner(seed: 3, planing: true, handling: 0.35, boatClass: BotHandTackTests.skiffEight)
        Self.wandering(&hand, race, handling: 0.35)
        let view = Self.seen(race, &hand)
        let groove = Aim.groove(.downwind, tack: .starboard, angle: view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa)
        #expect(hand.brain.downwindAim(view.own, view, aim: groove) == groove)
    }

    /// And sailed: a Club helm (handling 0.45), her hand wandering as a Club hand does, runs 20 s on the plane (to
    /// where she turns for her mark) without leaving it.
    @Test func clubHandStaysOnThePlaneDownTheRun() throws {
        var total = 0.0
        for seed in UInt64(1)...6 {
            var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: 0.45)
            Self.wandering(&hand, race, handling: 0.45, steers: true, seed: seed)
            var off = 0.0, deepest = 0.0
            for _ in 0..<(20 * Race.tickRate) {
                hand.drive(race)
                race.step()
                let boat = race.boats[0]
                if !boat.isPlaning { off += Race.dt }
                deepest = max(deepest, rad2deg(boat.twa - race.boatClass.polar.bestDownwind(tws: boat.polarWindSpeed(in: race.boatClass)).twa))
            }
            print("BOTPLANING club run seed \(seed): off the plane \(off) s of 20, deepest \(deepest)° past her groove")
            total += off
        }
        #expect(total <= 1, "off the plane \(total) s of 120")
    }

    /// "Come down as she gathers speed": round the windward mark at 55 % of her speed, 30° above her groove, asked
    /// for a mark dead downwind (or a groove she misses 25° deep), she aims no deeper than she is, well above her
    /// groove, in five waters of six (before the caution round: never more than 40° above what she was asked, 137°,
    /// where she fell; in the sixth, 14 kn, she has the speed to plane dead downwind); sailed on, she comes down to
    /// her groove without leaving the plane.
    @Test func slowSheComesDownAsSheGathersSpeed() throws {
        var held = 0
        for seed in UInt64(1)...6 {
            var (race, hand, _) = try Self.runner(seed: seed, planing: true, speed: 0.55, deep: deg2rad(-30), handling: 0.55)
            let view = Self.seen(race, &hand)
            let groove = view.boatClass.polar.bestDownwind(tws: view.own.polarWindSpeed).twa
            let sailed = hand.brain.downwindAim(view.own, view, aim: Aim(angle: deg2rad(177), tack: .starboard))
            print("BOTPLANING come down seed \(seed): groove \(rad2deg(groove))°, at \(rad2deg(view.own.twa))°, asked 177°, aims \(rad2deg(sailed.angle))°")
            if sailed.angle <= view.own.twa + deg2rad(2) { held += 1 }
            var off = 0.0
            for _ in 0..<(20 * Race.tickRate) {
                hand.drive(race)
                race.step()
                if !race.boats[0].isPlaning { off += Race.dt }
            }
            let boat = race.boats[0]
            let now = race.boatClass.polar.bestDownwind(tws: boat.polarWindSpeed(in: race.boatClass)).twa
            print("BOTPLANING come down seed \(seed): off \(off) s, after 20 s \(rad2deg(boat.twa - now))° off her groove")
            #expect(off == 0, "seed \(seed): off the plane \(off) s")
            // Down to her groove, or past it for her mark (seed 2's is close below her).
            #expect(now - boat.twa < deg2rad(2), "seed \(seed): \(rad2deg(boat.twa - now))° off her groove")
        }
        #expect(held >= 5, "held above her groove in \(held) waters of 6")
    }

    /// "A gybe within her skill": racing on skiff@9 a helm who would slam (handling 0.3: all the rudder) gybes on half
    /// of it, a wider arc that keeps her on the plane; a good helm on her own 30 %. A flubbed gybe is still cranked
    /// hard over past her groove, and falls. On skiff@8 the poor helm slams as ever.
    @Test func poorHelmGybesWithinHerSkill() throws {
        struct Gybe { var fraction = 0.0, flubbed = false, fell = false, gybed = false }
        func gybe(seed: UInt64, handling: Double, boatClass: BoatClassFile = Self.skiffNine) throws -> Gybe {
            var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: handling, boatClass: boatClass)
            hand.brain = { var brain = hand.brain; brain.handTurnRng = SplitMix64(seed: seed, stream: BotBrain.handTurnStream); return brain }()
            var result = Gybe()
            let from = race.boats[0].boomSide
            for tick in 0..<(12 * Race.tickRate) {
                if tick == 2 * Race.tickRate { hand.brain.plannedTack = race.boats[0].tack.other }
                hand.drive(race)
                if let turn = hand.brain.handTurn, !turn.isTack {
                    result.fraction = turn.fraction
                    result.flubbed = turn.overSteer > 0
                }
                race.step()
                if race.boats[0].boomSide != from { result.gybed = true }
                if !race.boats[0].isPlaning { result.fell = true }
            }
            return result
        }
        var clean = 0, flubbed = 0
        for seed in UInt64(1)...12 {
            let poor = try gybe(seed: seed, handling: 0.3)
            print("BOTPLANING gybe seed \(seed) h 0.3: rudder \(poor.fraction), flubbed \(poor.flubbed), fell \(poor.fell)")
            #expect(poor.gybed, "seed \(seed)")
            if poor.flubbed {
                flubbed += 1
                #expect(poor.fraction == HandTackTable.gybeFraction.poor && poor.fell, "seed \(seed): a flubbed gybe at \(poor.fraction), fell \(poor.fell)")
            } else {
                clean += 1
                #expect(poor.fraction == PlaningTable.safeGybe, "seed \(seed): \(poor.fraction)")
                #expect(!poor.fell, "seed \(seed): fell off the plane in a gybe on half rudder")
            }
            let good = try gybe(seed: seed, handling: 1)
            #expect(good.fraction == HandTackTable.gybeFraction.good && !good.fell && good.gybed, "seed \(seed): \(good)")
        }
        #expect(clean >= 6 && flubbed >= 1, "\(clean) clean, \(flubbed) flubbed")
        let eight = try gybe(seed: 1, handling: 0.3, boatClass: BotHandTackTests.skiffEight)
        #expect(eight.flubbed || eight.fraction == HandTackTable.gybeFraction.poor, "skiff@8: \(eight.fraction)")
    }

    /// Penalty circles from the plane (#462: gybe first she drops off it on skiff@9): a bot planing on her run, owed a
    /// turn, turns it at 70 % rudder inside the rules' deadline on skiff@9 as on skiff@8, in about the seconds she
    /// reckons a turn takes her and less (`penaltyTurnSeconds`, which her mark-hold and start-first conditions read,
    /// #471: 23 to 25 s reckoned, 11 to 12 s sailed, in 10 to 14 kn the same to the tick on both classes: she luffs
    /// out of her run into the turn, and is off the plane on either before she gybes).
    @Test func penaltyTurnFromThePlaneHoldsItsDeadline() throws {
        var seconds: [[Double]] = [[], []]
        for (index, boatClass) in [BotHandTackTests.skiffEight, Self.skiffNine].enumerated() {
            for seed in UInt64(1)...6 {
                var (race, hand, _) = try Self.runner(seed: seed, planing: true, handling: 0.5, boatClass: boatClass) { snapshot in
                    snapshot.seats[0].boat.penaltyTurnsOwed = 1
                    snapshot.seats[0].boat.penaltyProgress = 0
                    snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
                }
                let view = race.seatView(for: 0)
                let reckoned = hand.brain.penaltyTurnSeconds(view.own, view)
                let start = race.time
                var kinds: [RaceEvent.Kind] = []
                for _ in 0..<(60 * Race.tickRate) where race.boats[0].penaltyTurnsOwed > 0 && race.boats[0].status == .racing {
                    hand.drive(race)
                    race.step()
                    kinds += race.drainEvents().map(\.kind)
                }
                let took = race.time - start
                print("BOTPLANING penalty skiff@\(boatClass.version) seed \(seed): served in \(took) s, reckoned \(reckoned) s, \(race.boats[0].status)")
                #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .racing, "skiff@\(boatClass.version), seed \(seed)")
                #expect(!kinds.contains { if case .penaltyReset = $0 { true } else { false } }, "skiff@\(boatClass.version), seed \(seed): gave the turn up")
                #expect(took <= reckoned, "skiff@\(boatClass.version), seed \(seed): \(took) s against \(reckoned) s reckoned")
                seconds[index].append(took)
            }
        }
        let mean = seconds.map { $0.reduce(0, +) / Double($0.count) }
        print("BOTPLANING penalty mean: skiff@8 \(mean[0]) s, skiff@9 \(mean[1]) s; worst \(seconds.map { $0.max()! })")
        #expect(mean[1] <= mean[0] + 1, "\(mean)")
        #expect(seconds[1].max()! < 15, "the rules give her 40 s")
    }

    /// A whole race on skiff@9: every boat gybes by her rudder alone, none sits in irons, the fleet finishes, and off
    /// the wind in a wind that planes it is on the plane most of the time (off it 46 % and 64 % of the time on these
    /// two seeds before the bots headed up after a fall).
    @Test func fleetPlanesThroughARaceOnSkiffNine() throws {
        for seed in [UInt64(462), 3] {
            let seen = try Self.planing(seed: seed, boatClass: Self.skiffNine, seconds: 900)
            let off = seen.off / max(seen.running, 1)
            print("BOTPLANING fleet seed \(seed): off the plane \(off) of \(seen.running) s, finished \(seen.finished)")
            #expect(off < 0.35, "seed \(seed): off the plane \(off) of her running")
            #expect(seen.finished >= 4, "seed \(seed): \(seen.finished) finished")
        }
        let fleet = try BotHandTackTests.fleet(seed: 459, seconds: 900, boatClass: Self.skiffNine)
        print("BOTPLANING fleet 900 s: tacks \(fleet.tacks) gybes \(fleet.gybes) stuck \(fleet.stuck.map { ($0 * 10).rounded() / 10 }) finished \(fleet.finished)")
        #expect(fleet.gybes.allSatisfy { $0 >= 1 }, "gybes by boat: \(fleet.gybes)")
        #expect(fleet.stuck.allSatisfy { $0 <= 10 }, "seconds in irons by boat: \(fleet.stuck)")
        #expect(fleet.tackGybeTaps == 0)
        #expect(fleet.finished >= fleet.tacks.count / 2, "\(fleet.finished) finished")
    }

    /// A probe, not a test: every fall off the plane in all-bot races on skiff@9, with what the boat and her bot were
    /// doing. Prints only with REGATTA_PLANING_PROBE set.
    @Test func probeFalls() throws {
        guard ProcessInfo.processInfo.environment["REGATTA_PLANING_PROBE"] != nil else { return }
        var lines: [String: [String]] = [:]
        for seed in UInt64(1)...6 {
            let race = try BotHelmTests.race(seed: seed, boatClass: Self.skiffNine)
            var controllers = allBots(race)
            var was = race.boats.map(\.isPlaning)
            var legs = race.boats.map { ($0.legIndex, race.tick) }
            var gybed = Array(repeating: -10_000, count: race.boats.count)
            var booms = race.boats.map(\.boomSide)
            let tuning = try #require(race.boatClass.planing)
            for _ in 0..<(900 * Race.tickRate) where !race.isOver {
                controllers.drive(race)
                race.step()
                for (seat, boat) in race.boats.enumerated() {
                    defer { was[seat] = boat.isPlaning; booms[seat] = boat.boomSide }
                    if boat.legIndex != legs[seat].0 { legs[seat] = (boat.legIndex, race.tick) }
                    if boat.boomSide != booms[seat] { gybed[seat] = race.tick }
                    guard was[seat], !boat.isPlaning, boat.status == .racing, boat.penaltyTurnsOwed == 0, boat.twa >= deg2rad(100) else { continue }
                    let tws = boat.polarWindSpeed(in: race.boatClass)
                    let groove = race.boatClass.polar.bestDownwind(tws: tws)
                    guard groove.speed >= tuning.onSpeed else { continue }
                    let brain = controllers[seat].driver!.brain
                    let aws = BoatClass.PlaningTuning.apparentWindSpeed(twa: boat.twa, speed: boat.speed, tws: tws)
                    let sinceLeg = Double(race.tick - legs[seat].1) / 30, sinceGybe = Double(race.tick - gybed[seat]) / 30
                    let floor = abs(boat.rudder) <= 0.2 && aws < tuning.apparentWind!.offSpeed(tws: tws)
                    let kind = sinceGybe < 8 ? "gybe" : sinceLeg < 15 ? "rounding" : floor ? "floor" : "slow"
                    func r(_ x: Double) -> Double { (x * 10).rounded() / 10 }
                    let k = knots(metresPerSecond: 1)
                    lines[kind, default: []].append("s\(seed)#\(seat) h\(r(brain.turnHandling)) leg\(boat.legIndex)+\(r(sinceLeg))s gybe+\(r(min(sinceGybe, 99)))s twa \(Int(rad2deg(boat.twa)))/\(Int(rad2deg(groove.twa))) \(r(boat.speed * k))/\(r(race.boatClass.polar.speed(twa: boat.twa, tws: tws) * k))kn tws \(r(tws * k)) gw \(r((brain.senses.grooveWind ?? 0) * k)) aws \(r(aws * k)) rud \(r(boat.rudder)) sh \(r(boat.speedShadow(in: race.boatClass))) turn \(brain.handTurn != nil) repl \(brain.replane != nil) aim \(Int(rad2deg(brain.planingAimed.asked)))>\(Int(rad2deg(brain.planingAimed.sailed))) \(r(Double(race.tick) / 30 - brain.planingAimed.time))s ago st \(boat.roundingStage) sens \(brain.senses.planing) d \(Int((race.course.targetPosition(for: race.course.legs[boat.legIndex]) - boat.position).length))m")
                }
            }
        }
        for (kind, all) in lines.sorted(by: { $0.key < $1.key }) {
            print("PROBE \(kind): \(all.count)")
            for line in all.prefix(9) { print("PROBE   ", line) }
        }
    }
}
