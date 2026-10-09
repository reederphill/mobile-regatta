import Testing
import RegattaCore
@testable import RegattaBots

/// #99: the bots' start sequence. The bot suite measures it over many fleets (`BotStartSuiteTests`); these
/// follow single bots through it: how they hold, from any pre-gun state, and back from over the line.
@Suite struct BotStartTests {
    /// A full start sequence (60 s) for `seats`, from the race's own row (#35).
    static func startRace(seats: [SeatKind] = Array(repeating: .bot, count: 10), seed: UInt64) -> Race {
        botRace(seats: seats, laps: 1, prestartSeconds: 60, seed: seed)
    }

    /// Holding before the gun, a bot lets the sheets out rather than luffing into the no-go zone to wait: when
    /// she eases she is on a wind angle outside it, the autohelm holding it with her rudder centred (#231), and
    /// she is never stalled in irons there (#219: letting go in the no-go bears her away to the groove). The rudder
    /// centred is the three fleets' share together (#366): how much one fleet steers while it holds is its crowd's (seed
    /// 1's was 52 % before a 0.99 National bot set up at the favoured end, and 48 % after).
    @Test func botsHoldWithEaseOutsideTheNoGo() throws {
        var allEased = 0, allCentred = 0
        let race0HoldsCentred = Self.startRace(seed: 1).boatClass.steering.autohelm.holdsWhenCentred
        for seed: UInt64 in [1, 2, 3] {
            let race = Self.startRace(seed: seed)
            var controllers = allBots(race)
            let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
            var eased = 0, easedInNoGo = 0, easedCentred = 0, irons = 0
            sail(race, &controllers, ticks: 60 * Race.tickRate) { race in
                for (seat, boat) in race.boats.enumerated() where race.tick > -60 * Race.tickRate + Race.tickRate {
                    if race.heldInputs[seat].ease {
                        eased += 1
                        if boat.twa < noGo { easedInNoGo += 1 }
                        if race.heldInputs[seat].rudder == 0 { easedCentred += 1 }
                    }
                    if boat.twa < noGo && boat.speed < 0.5 && !boat.isTakingPenalty { irons += 1 }
                }
            }
            #expect(race.tick == 0, "sailed to the gun")
            #expect(eased > 10 * 10 * Race.tickRate, "seed \(seed): the fleet held with Ease for \(eased) boat-ticks")
            #expect(Double(easedInNoGo) < Double(eased) * 0.01, "seed \(seed): \(easedInNoGo) of \(eased) eased ticks in the no-go")
            allEased += eased
            allCentred += easedCentred
            #expect(irons < 10 * Race.tickRate, "seed \(seed): \(irons) boat-ticks in irons")
        }
        // A centred rudder holds heading only on a class whose autohelm does (skiff@6); skiff@7 holds by hand (#437).
        if race0HoldsCentred {
            #expect(Double(allCentred) > Double(allEased) * 0.5, "rudder centred for \(allCentred) of \(allEased)")
        }
    }

    /// Works from any pre-gun state (#19's takeover): a boat helmed at random for the first half of the sequence,
    /// wherever that leaves her (stalled, past an end of the line, pinned on the race area's edge), then handed to
    /// a bot, is below the line at the gun and starts: a bot at the fleet's normal draw taking a seat given away
    /// (`.bot`, #16, #35) within 30 s of the gun, or the cautious bot taking a dropped player's (#104, `.dropped`)
    /// within `cautiousStartSeconds`.
    @Test(arguments: [false, true])
    func aBotTakingOverBeforeTheGunStarts(cautious: Bool) throws {
        for seed: UInt64 in 1...12 {
            let race = Self.startRace(seats: [.human] + Array(repeating: .bot, count: 9), seed: seed)
            // The takeover alone: the fleet around her sails without weaknesses, as the scenario was written for
            // (#99). Line-bias misreads (#102) move where the fleet holds: on seed 9 she then reached the pin end
            // early, luffing to keep clear of a boat to leeward, and was over at the gun.
            var controllers = SeatControllers([.human] + (1..<race.boats.count).map { seat in
                let style = BotDriver(seat: seat, raceSeed: race.setup.raceSeed).style
                return .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed, style: style, weaknesses: .none(skill: style.skill)))
            })
            var rng = SplitMix64(seed: seed)
            var step = 0
            sail(race, &controllers, ticks: 30 * Race.tickRate) { race in
                if step % 45 == 0 {
                    race.apply(BoatInput(rudder: Int8(rng.int(in: -100...100)), ease: rng.bool()), seat: 0, atTick: race.tick + 1)
                }
                step += 1
            }
            controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: cautious)
            var started: Int?
            sail(race, &controllers, ticks: 90 * Race.tickRate) { race in
                if race.tick == 0 {
                    #expect(race.boats[0].status == .prestart, "seed \(seed) cautious \(cautious): over the line at the gun")
                }
                if started == nil, race.boats[0].status == .racing { started = race.tick }
            }
            let within = cautious ? Self.cautiousStartSeconds : 30
            #expect(started.map { $0 <= within * Race.tickRate } == true,
                    "seed \(seed) cautious \(cautious): started at tick \(started ?? -1)")
        }
    }

    /// Seconds after the gun by which the cautious bot taking a seat over before it has started (#104, placeholder): she
    /// is Club's bottom skill, keeps clear of every boat and waits off an end of the line until the gun (`hangBackAim`), so
    /// she starts late (seeds 1…12: 15–31 s after the gun, seed 3 latest).
    static let cautiousStartSeconds = 60

    /// OCS detection and return (#9 rule 21.1, #85): a bot a little over the line at the gun, beating up it
    /// among the boats starting, is told she's OCS, runs back below the line keeping clear of them as a returning
    /// boat must, and starts.
    @Test func anOCSBotReturnsKeepingClearAndStarts() throws {
        for seed: UInt64 in 1...12 {
            let race = Self.startRace(seats: Array(repeating: .bot, count: 3), seed: seed)
            // The return alone: bots whose line-bias misreads (#102) don't move the fleet about the line from where
            // the scenario was written for.
            var controllers = SeatControllers(race.boats.indices.map { seat in
                let style = BotDriver(seat: seat, raceSeed: race.setup.raceSeed).style
                return .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed, style: style, weaknesses: .none(skill: style.skill)))
            })
            sail(race, &controllers, ticks: 59 * Race.tickRate)
            // A second before the gun, put a boat that owes no penalty a metre and a half over the line where she
            // is, close-hauled on starboard.
            let seat = try #require(race.boats.indices.first { race.boats[$0].penaltyTurnsOwed == 0 && !race.boats[$0].isTakingPenalty })
            let line = race.course.startLine
            var snapshot = race.exportSnapshot()
            let position = race.boats[seat].position
            snapshot.seats[seat].boat.position = position + race.course.upwind * (1.5 - line.side(position))
            snapshot.seats[seat].boat.heading = race.seatView(for: seat).own.windDirection - deg2rad(45)
            snapshot.seats[seat].boat.boomSide = .port
            snapshot.seats[seat].boat.speed = 3
            try race.importSnapshot(snapshot)
            var events: [RaceEvent.Kind] = []
            sail(race, &controllers, ticks: 60 * Race.tickRate) { race in
                events += race.drainEvents().map(\.kind)
            }
            #expect(events.contains(.ocsNotice(recipient: seat)), "seed \(seed): no OCS notice")
            #expect(events.contains(.cleared(seat: seat)), "seed \(seed): she never cleared")
            #expect(events.contains(.started(seat: seat)), "seed \(seed): she never started")
            let returning = events.filter {
                if case .ruleCall(let call) = $0 { call.offender == seat && call.rule == .returningToStart } else { false }
            }
            #expect(returning.isEmpty, "seed \(seed): called under rule 21.1 returning")
        }
    }

    /// #350: with less time to the gun than a tack takes, close below the start line and level with it between its
    /// ends, she is set up where she is (`BotBrain.isSetUpWhereSheIs`), and her spot's bearing is clamped to where she
    /// holds, waits or goes from (`startAim`). Beyond an end, or deeper, or earlier, she isn't: a boat as close below the
    /// line but beyond its pin end still sails to her setup point (`toSetup`).
    @Test func setUpWhereSheIsOnlyCloseBelowTheLineBetweenItsEnds() throws {
        func placed(toGun: Int, below: Double, beyondPin: Double?) throws -> (brain: BotBrain, view: SeatView) {
            let water = BotConductTests.Water(seed: 1, toGun: toGun, below: below)
            let line = water.race.course.startLine
            let direction = (line.committee.position - line.pin.position).normalized
            let position = beyondPin.map {
                line.pin.position - direction * (water.length * $0) - water.race.course.upwind * (water.length * below)
            } ?? water.centre
            let heading = water.heading(.starboard, deg2rad(90))
            let race = try BotConductTests.place(water, [
                .init(position: position, heading: heading, speed: 2, status: .prestart),
                .init(position: water.centre - water.race.course.upwind * 200, heading: heading, speed: 2, status: .prestart),
            ])
            return (BotBrain(style: BotConductTests.skill1), race.seatView(for: 0))
        }
        func setUp(_ placed: (brain: BotBrain, view: SeatView)) -> Bool {
            placed.brain.isSetUpWhereSheIs(placed.view.own, placed.view, arrival: placed.brain.startArrival(placed.view))
        }
        #expect(setUp(try placed(toGun: 2, below: 1, beyondPin: nil)), "close below the line between its ends")
        #expect(!setUp(try placed(toGun: 2, below: 3, beyondPin: nil)), "three lengths below it")
        #expect(!setUp(try placed(toGun: 8, below: 1, beyondPin: nil)), "with time for a tack")
        let beyond = try placed(toGun: 2, below: 1, beyondPin: 3)
        #expect(!setUp(beyond), "beyond the pin end")
        let b = beyond.view.own
        let hold = BotBrain.holdAngle(beyond.view)
        let arrival = beyond.brain.startArrival(beyond.view)
        var aiming = beyond.brain, setting = beyond.brain
        let spot = setting.reachableSpot(b, beyond.view, hold: hold, arrival: arrival)
        #expect(aiming.startAim(b, beyond.view) == setting.toSetup(b, beyond.view, spot: spot, hold: hold, arrival: arrival),
                "beyond the pin end she sails to her setup point")
    }

    // MARK: - Fighting for her spot (#337)

    /// #337 acceptance (start): the windward boat of #280's scene, luffed to her floor and still not clear of the
    /// leeward boat (`BotBrain.startLuff`), holds her ground from further out the more combative she is
    /// (`FleetTactics.startHoldsGroundScale`): 25 s before the gun the typical bot still eases and drops astern and
    /// a combative one holds; 15 s before it the typical one holds and a mild one still drops astern. She stays the
    /// keep-clear boat throughout (the luff is hers, away from the leeward boat).
    @Test func holdsHerGroundLongerTheMoreCombative() throws {
        func dropsAstern(_ engagement: Double, toGun: Int) throws -> Bool {
            let race = try BotConductTests.prestartWindwardLeeward(seed: 3, toGun: toGun, leeward: deg2rad(32),
                                                                   windward: deg2rad(36), abeam: 0.9)
            let view = race.seatView(for: 1)
            #expect(view.others.first?.rightOfWay?.keepClear == 1, "she is the keep-clear boat")
            var brain = BotTacticsTests.pilot(seat: 1, race, engagement: engagement, planned: .starboard).brain
            brain.observe(view.own, view)
            return brain.startLuff(view.own, view, desired: view.own.heading, lookahead: 3).dropsAstern
        }
        let floor = BotBrain.FleetTactics.engagementFloor
        #expect(try dropsAstern(0.5, toGun: 25))
        #expect(try !dropsAstern(1, toGun: 25))
        #expect(try !dropsAstern(0.5, toGun: 15))
        #expect(try dropsAstern(floor, toGun: 15))
    }

    /// #337 acceptance (start, the owner 2026-10-08: combative bots luff harder before the start when they hold the
    /// right of way, never without it): the leeward boat 40 s before the gun, a windward boat a length and a half
    /// abeam that must keep clear of her (rule 11). A combative bot luffs her (rudder towards the wind, at the hunter's
    /// rate); the fleet's typical one holds her course (#101); the combative one eases her luff off for her start
    /// (`FleetTactics.startLuffUntilScale`), and never luffs as the windward boat, without the right of way. Sailed
    /// out against a typical windward bot, no rule call on her.
    @Test func combativeLuffsAWindwardBoatBeforeTheStart() throws {
        func luffing(_ engagement: Double, seat: Int = 0, toGun: Int = 40) throws -> BoatInput? {
            let race = try BotConductTests.prestartWindwardLeeward(seed: 3, toGun: toGun, leeward: deg2rad(45),
                                                                   windward: deg2rad(45), abeam: 1.5)
            // A second on, the rules have them overlapped (rule 11).
            for _ in 0..<Race.tickRate { race.step() }
            let view = race.seatView(for: seat)
            #expect(view.others.first?.rightOfWay == RightOfWay(keepClear: 1, rule: .windwardLeeward))
            var brain = BotTacticsTests.pilot(seat: seat, race, engagement: engagement, planned: .starboard).brain
            brain.observe(view.own, view)
            return brain.startLuffing(view.own, view, .neutral, desired: view.own.heading)
        }
        let combative = try #require(try luffing(1), "combative, she luffs")
        #expect(combative.rudderValue > 0, "a luff on starboard turns her to starboard: \(combative.rudderValue)")
        #expect(try luffing(0.5) == nil, "typical, she holds her course")
        #expect(try luffing(1, toGun: 5) == nil, "4 s before the gun she has eased her luff off")
        #expect(try luffing(1, seat: 1) == nil, "as the windward boat she has no luff to take")

        for seed: UInt64 in [3, 7, 13] {
            let race = try BotConductTests.prestartWindwardLeeward(seed: seed, toGun: 40, leeward: deg2rad(45),
                                                                   windward: deg2rad(45), abeam: 1.5)
            let sailed = BotTacticsTests.sail(race, BotTacticsTests.pilot(seat: 0, race, engagement: 1, planned: .starboard),
                                              seconds: 10, others: [BotTacticsTests.pilot(seat: 1, race, engagement: 0.5,
                                                                                            planned: .starboard)])
            // Never a call on her: her luff is within rule 16.1's rate. The windward boat may be called under rule 11
            // (the owner: more calls at the combative end), as a player squeezed there would be.
            let calls = BotConductTests.calls(sailed.kinds)
            #expect(!calls.contains { $0.hasSuffix(" on 0") }, "seed \(seed): \(calls)")
        }
    }

    /// #337 (owner 2026-10-08: "luff with time to spare"): `combativeLuffsAWindwardBoatBeforeTheStart`'s scene, `below`
    /// hull lengths below the middle of the line `toGun` seconds before the gun, sailed out against a typical windward bot
    /// to `after` seconds past it: the times the combative leeward boat luffed, the first her approach to her own spot
    /// (`secondsToSpot`) and `luffSpareSeconds` no longer fit in the time to the gun, and when she started (nil: not by
    /// then) and whether she was over at the gun; times from the gun.
    static func luffingOut(seed: UInt64, toGun: Int, below: Double, after: Double = 30) throws
        -> (luffs: [Double], outOfTime: Double?, brokeOff: Double?, started: Double?, ocs: Bool, until: Double) {
        let water = BotConductTests.Water(seed: seed, toGun: toGun, below: below)
        let heading = water.heading(.starboard, deg2rad(45))
        let forward = Vec2.heading(heading)
        let race = try BotConductTests.place(water, [
            BotConductTests.Placement(position: water.centre, heading: heading, speed: 2, status: .prestart),
            BotConductTests.Placement(position: water.centre + forward.rightPerp * water.length * 1.5, heading: heading,
                                      speed: 2, status: .prestart),
        ])
        var luffer = BotTacticsTests.pilot(seat: 0, race, engagement: 1, planned: .starboard)
        var windward = BotTacticsTests.pilot(seat: 1, race, engagement: 0.5, planned: .starboard)
        let until = try #require(luffer.brain.tactics.startLuffUntil)
        var luffs: [Double] = [], outOfTime: Double?, brokeOff: Double?, started: Double?, ocs = false
        while race.seatView(for: 0).time < after, !race.isOver, started == nil {
            let view = race.seatView(for: 0)
            if let decision = luffer.drive(race) {
                if outOfTime == nil, luffer.brain.secondsToSpot(view.own, view, hold: BotBrain.holdAngle(view)) + BotBrain.luffSpareSeconds >= -view.time {
                    outOfTime = view.time
                }
                if decision.startLuff { luffs.append(view.time) }
                if brokeOff == nil, luffer.brain.brokeOffStartLuff { brokeOff = view.time }
            }
            _ = windward.drive(race)
            race.step()
            for event in race.drainEvents() {
                if case .started(seat: 0) = event.kind { started = race.seatView(for: 0).time }
                if case .ocsNotice(recipient: 0) = event.kind { ocs = true }
            }
        }
        return (luffs, outOfTime, brokeOff, started, ocs, until)
    }

    /// #337 (owner 2026-10-08: "luff with time to spare"): seed 36's scene (re-picked from 13 for hand steering, #437: the
    /// windward boat sails off in most seeds before her time runs out, and the luff ends early) 50 s before the gun, five lengths below the
    /// line: the combative leeward boat luffs the windward one while her approach to her own spot and
    /// `luffSpareSeconds` fit in the time to the gun, breaks off as soon as they don't (still well before her ease,
    /// `startLuffUntil`), and starts on time.
    @Test func combativeBreaksOffHerLuffInTimeToStart() throws {
        let sailed = try Self.luffingOut(seed: 36, toGun: 50, below: 5)
        let outOfTime = try #require(sailed.outOfTime, "her time ran out before the gun")
        #expect(-outOfTime > sailed.until + 10, "out of time \(-outOfTime) s before the gun, her ease \(sailed.until) s")
        #expect(sailed.luffs.contains { $0 < outOfTime - 10 }, "she luffed with time to spare")
        let last = try #require(sailed.luffs.last)
        #expect(outOfTime - last < Double(BotDriver.decisionInterval) / Double(Race.tickRate) + 1e-9,
                "she luffed until her time ran out (last luff \(last) s, out of time \(outOfTime) s): it broke her luff off")
        #expect(!sailed.luffs.contains { $0 >= outOfTime }, "and not once it had")
        // #337 review: the break-off is latched (`brokeOffStartLuff`) the decision her time runs out: she luffs no more
        // before her start, though bearing away to her plan wins time back.
        let brokeOff = try #require(sailed.brokeOff, "her break-off latched")
        #expect(abs(brokeOff - outOfTime) < 1e-9, "latched \(brokeOff) s, out of time \(outOfTime) s")
        #expect(!sailed.ocs)
        let started = try #require(sailed.started, "she started")
        #expect(started <= 3, "on time: \(started) s after the gun")
    }

    /// #337 review: once she has broken a pre-start luff off for want of time (`brokeOffStartLuff`), a combative bot
    /// luffs no more before her start, with time to spare again or not: `combativeLuffsAWindwardBoatBeforeTheStart`'s
    /// scene, 40 s before the gun.
    @Test func aBrokenOffLuffStaysBrokenOff() throws {
        let race = try BotConductTests.prestartWindwardLeeward(seed: 3, toGun: 40, leeward: deg2rad(45),
                                                               windward: deg2rad(45), abeam: 1.5)
        for _ in 0..<Race.tickRate { race.step() }
        let view = race.seatView(for: 0)
        var brain = BotTacticsTests.pilot(seat: 0, race, engagement: 1, planned: .starboard).brain
        brain.observe(view.own, view)
        #expect(brain.hasTimeToSpare(view.own, view))
        #expect(brain.startLuffing(view.own, view, .neutral, desired: view.own.heading) != nil, "she luffs")
        brain.brokeOffStartLuff = true
        #expect(brain.startLuffing(view.own, view, .neutral, desired: view.own.heading) == nil, "broken off, she doesn't")
    }

    /// #337 review: `secondsToSpot` and `reachableSpot` reckon her approach to her spot alike (`spotApproach`): with her
    /// spot to her right, an arrival a little later than `secondsToSpot` keeps her spot, and a little earlier gives it up.
    @Test func secondsToSpotAgreesWithTheReachableSpot() throws {
        var checked = 0
        for seed: UInt64 in [3, 7, 13] {
            for below in [3.0, 6.0, 10.0] {
                for left in [4.0, 8.0, 12.0] {
                    let water = BotConductTests.Water(seed: seed, toGun: 60, below: below)
                    let c = water.race.course
                    let pinward = (c.startLine.pin.position - c.startLine.committee.position).normalized
                    let race = try BotConductTests.place(water, [
                        BotConductTests.Placement(position: water.centre + pinward * water.length * left,
                                                  heading: water.heading(.starboard, deg2rad(45)), speed: 2,
                                                  status: .prestart),
                        BotConductTests.Placement(position: water.centre + c.right * 200, heading: water.heading(.port, deg2rad(45)),
                                                  speed: 2, status: .prestart),
                    ])
                    let view = race.seatView(for: 0)
                    let brain = BotTacticsTests.pilot(seat: 0, race, engagement: 1, planned: .starboard).brain
                    let hold = BotBrain.holdAngle(view)
                    guard brain.spotApproach(view.own, view, hold: hold).across > 0 else { continue }
                    let seconds = brain.secondsToSpot(view.own, view, hold: hold)
                    let spot = brain.startPoint(view.course)
                    #expect(brain.reachableSpot(view.own, view, hold: hold, arrival: seconds + 0.05) == spot,
                            "seed \(seed), \(below) below, \(left) left: \(seconds) s keeps it")
                    #expect(brain.reachableSpot(view.own, view, hold: hold, arrival: seconds - 0.5) != spot,
                            "seed \(seed), \(below) below, \(left) left: earlier gives it up")
                    checked += 1
                }
            }
        }
        #expect(checked >= 9, "\(checked) scenes with her spot to her right")
    }
}
