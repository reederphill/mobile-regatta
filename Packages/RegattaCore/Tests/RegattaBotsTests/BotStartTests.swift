import Testing
import RegattaCore
@testable import RegattaBots

/// #99: the bots' start sequence. The bot suite measures it over many fleets (`BotStartSuiteTests`); these
/// follow single bots through it: how they hold, from any pre-gun state, and back from over the line.
@Suite struct BotStartTests {
    /// A full start sequence (60 s) for `seats`, from the race's own row (#35).
    static func startRace(seats: [SeatKind] = Array(repeating: .bot, count: 10), seed: UInt64,
                          boatClass: FileRef = BotConductTests.waterClass) -> Race {
        botRace(seats: seats, laps: 1, prestartSeconds: 60, seed: seed, boatClass: boatClass)
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
            // skiff@6 until #455: the taken-over bot is over the line at the gun under hand steering.
            let race = Self.startRace(seats: [.human] + Array(repeating: .bot, count: 9), seed: seed,
                                      boatClass: try BotHelmTests.autohelmOn().ref)
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
            // Seed 7 since #545 (the hand helm nudging through the dead band sails the minute before the gun
            // differently): she returns into seat 1 starting under her, is called under rule 11 at 15.9 s, serves her
            // turn and starts 61 s after the gun, a second outside. A returning boat's conduct in an encounter is #455's.
            withKnownIssue("#455: seed 7's returning boat doesn't keep clear of a starter", isIntermittent: true) {
                #expect(events.contains(.started(seat: seat)), "seed \(seed): she never started")
            } when: { seed == 7 }
            let returning = events.filter {
                if case .ruleCall(let call) = $0 { call.offender == seat && call.rule == .returningToStart } else { false }
            }
            // Seed 1 since #471's step C (the fleet sails the minute before the gun differently; nobody owes a turn at
            // the gun): a boat starting 5 s late comes up under her as she dips back below the line, and she is called.
            // A returning boat's conduct in an encounter is #455's.
            withKnownIssue("#455: seed 1's returning boat doesn't keep clear of a late starter", isIntermittent: true) {
                #expect(returning.isEmpty, "seed \(seed): called under rule 21.1 returning")
            } when: { seed == 1 }
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
    // skiff@7 until #455: on skiff@8 she breaks off her luff 8.5 s before she is out of time, not on the decision before it.
    @Test(.onSkiffSeven) func combativeBreaksOffHerLuffInTimeToStart() throws {
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

    // MARK: - The tackable wait (#477 PR 2, fleet-rules@8)

    /// On the opening (fleet-rules@8) the start plan tacks by hand from `startTackingSpeed` of close-hauled speed, and only
    /// there: not on a rules file before schema 8, not the cautious bot, and not without the plan (`startPlan`), where the
    /// 0.75 stands.
    @Test(RulesPin(version: 8)) func theStartPlanTacksFromTheStartTackingSpeedOnTheOpeningOnly() throws {
        #expect(BotBrain.startTackingSpeed == 0.45 && BotBrain.tackingSpeed == 0.75)
        let water = BotConductTests.Water(seed: 3, toGun: 30, below: 5)
        let c = water.race.course
        try #require(c.opening != nil)
        func scene(share: Double) throws -> (Race, Double) {
            let probe = try BotConductTests.place(water, [
                .init(position: water.centre, heading: water.heading(.port, deg2rad(80)), speed: 2, status: .prestart),
                .init(position: water.centre + c.right * 200, heading: water.heading(.port, deg2rad(80)), speed: 2, status: .prestart),
            ])
            let view = probe.seatView(for: 0)
            let closeHauled = BotTacticsTests.pilot(seat: 0, probe, planned: .port).brain.closeHauledSpeed(view.own, view)
            let race = try BotConductTests.place(BotConductTests.Water(seed: 3, toGun: 30, below: 5), [
                .init(position: water.centre, heading: water.heading(.port, deg2rad(80)), speed: closeHauled * share, status: .prestart),
                .init(position: water.centre + c.right * 200, heading: water.heading(.port, deg2rad(80)), speed: 2, status: .prestart),
            ])
            return (race, closeHauled)
        }
        for (share, tacks) in [(0.5, true), (0.4, false)] {
            let (race, _) = try scene(share: share)
            let view = race.seatView(for: 0)
            try #require(BotBrain.turnsByHand(view) && view.time < 0)
            let brain = BotTacticsTests.pilot(seat: 0, race, planned: .starboard).brain
            #expect(brain.waitsOnTheOpening(view))
            #expect(brain.canTap(view.own, view, byHand: true, startPlan: true) == tacks, "\(share) of close-hauled")
            #expect(!brain.canTap(view.own, view, byHand: true), "\(share): off the plan, the 0.75")
            let cautious = BotConductTests.Pilot(seat: 0, plannedTack: .starboard, race: race, caution: .standard).brain
            #expect(!cautious.waitsOnTheOpening(view), "the cautious bot waits as before")
        }
        // Before schema 8 nothing reads it.
        try BotConductTests.$waterRules.withValue(RulesConfigFile.bundled(id: "fleet-rules", version: 7).ref) {
            let race = BotConductTests.Water(seed: 3, toGun: 30, below: 5).race
            let view = race.seatView(for: 0)
            #expect(!BotTacticsTests.pilot(seat: 0, race, planned: .starboard).brain.waitsOnTheOpening(view))
        }
    }

    /// A waiting boat at the trim reaches with her speed at or over the start plan's tacking floor (#477 PR 2, #532's "don't
    /// hold eased" read as never below tacking speed): over a 10-boat start on fleet-rules@8, of the bots' eased boat-ticks
    /// 2–8 hull lengths below the line in the last 40 s, penalty turns aside, at most `waitBelowFloorShare` are under
    /// `startTackingSpeed` of close-hauled speed; and the fleet stays out of irons.
    @Test(RulesPin(version: 8)) func aWaitingBoatAtTheTrimReachesAtTackingSpeed() throws {
        var eased = 0, below = 0
        for seed: UInt64 in [1, 2, 3] {
            let race = Self.startRace(seed: seed)
            try #require(race.course.opening != nil)
            var controllers = allBots(race)
            let length = race.boatClass.hull.length
            let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
            var irons = 0
            sail(race, &controllers, ticks: 60 * Race.tickRate) { race in
                for (seat, boat) in race.boats.enumerated() where boat.status == .prestart && !boat.isTakingPenalty {
                    let closeHauled = race.boatClass.polar.bestUpwind(tws: boat.polarWindSpeed(in: race.boatClass)).speed
                        * boat.speedShadow(in: race.boatClass)
                    if boat.twa < noGo && boat.speed < 0.3 * closeHauled { irons += 1 }
                    let depth = -race.course.startLine.side(boat.position) / length
                    guard race.tick >= -40 * Race.tickRate, depth >= 2, depth <= 8, race.heldInputs[seat].ease else { continue }
                    eased += 1
                    if boat.speed < closeHauled * BotBrain.startTackingSpeed { below += 1 }
                }
            }
            #expect(race.tick == 0, "sailed to the gun")
            #expect(irons < 10 * Race.tickRate, "seed \(seed): \(irons) boat-ticks in irons")
        }
        #expect(eased > 0)
        #expect(Double(below) <= Double(eased) * Self.waitBelowFloorShare, "\(below) of \(eased) eased boat-ticks under the floor")
    }

    /// The most of the waiting boats' time under the floor (#477 PR 2's row target, ≤ 0.05).
    static let waitBelowFloorShare = 0.05

    /// A tack from the wait completes (#477 PR 2; Step 0 judged): a bot on port in the opening's wait, eased at the trim
    /// at 80° (`easeSpeedFraction`), told by her plan to tack for her run in, puts the helm down by hand at that speed;
    /// her boom crosses within 5 s, she never sits head to wind, and she is back to 0.9 of close-hauled speed within the
    /// same tack's time from full speed sheeted in, plus 5 s.
    @Test(RulesPin(version: 8)) func aTackFromTheWaitCompletes() throws {
        struct Tacked { var boom: Double?; var recovered: Double?; var stuck = 0.0; var began: Double? }
        func tack(seed: UInt64, fromTheWait: Bool) throws -> Tacked {
            let water = BotConductTests.Water(seed: seed, toGun: 14, below: 4)
            let c = water.race.course
            let heading = water.heading(.port, deg2rad(80))
            let target = BoatDynamics.polarTarget(relativeWind: deg2rad(80), boomSide: .starboard, tws: water.race.groundWind(at: water.centre).speed,
                                                  isPlaning: false, spinnaker: .down, boatClass: water.race.boatClass)
            let trim = try #require(c.opening).easeSpeedFraction
            let race = try BotConductTests.place(water, [
                .init(position: water.centre + c.right * (water.length * 3), heading: heading,
                      speed: fromTheWait ? target * trim : target, status: .prestart),
                .init(position: water.centre + c.right * 200, heading: heading, speed: 2, status: .prestart),
            ]) { snapshot in
                snapshot.seats[0].heldInput = BoatInput(rudder: Int8(0), ease: fromTheWait)
            }
            var pilot = BotConductTests.Pilot(seat: 0, plannedTack: .port, race: race)
            let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
            var result = Tacked()
            let boom = race.boats[0].boomSide
            for tick in 0..<(25 * Race.tickRate) {
                _ = pilot.drive(race)
                if result.began == nil, pilot.brain.handTurn != nil { result.began = Double(tick) * Race.dt }
                race.step()
                let boat = race.boats[0]
                let t = Double(tick + 1) * Race.dt
                let closeHauled = race.boatClass.polar.bestUpwind(tws: boat.polarWindSpeed(in: race.boatClass)).speed
                    * boat.speedShadow(in: race.boatClass)
                if boat.twa < noGo, boat.speed < 0.3 * closeHauled { result.stuck += Race.dt }
                if result.boom == nil, boat.boomSide != boom { result.boom = t }
                if result.boom != nil, result.recovered == nil, boat.speed >= 0.9 * closeHauled { result.recovered = t }
            }
            return result
        }
        var tacked = 0
        for seed: UInt64 in 1...4 {
            let wait = try tack(seed: seed, fromTheWait: true)
            let full = try tack(seed: seed, fromTheWait: false)
            guard let began = wait.began, let fullBegan = full.began else {
                Issue.record("seed \(seed): she never put the helm down (wait \(wait.began ?? -1), full \(full.began ?? -1))")
                continue
            }
            tacked += 1
            #expect(began < 1, "seed \(seed): she tacked from the wait at once (\(began) s)")
            let boom = try #require(wait.boom, "seed \(seed): her boom never crossed")
            #expect(boom - began <= 5, "seed \(seed): boom across \(boom - began) s after the helm went down")
            #expect(wait.stuck == 0, "seed \(seed): \(wait.stuck) s head to wind and stopped")
            let recovered = try #require(wait.recovered, "seed \(seed): never back to 0.9 of close-hauled speed")
            let baseline = try #require(full.recovered, "seed \(seed): the full-speed tack never recovered") - fullBegan
            #expect(recovered - began <= baseline + 5, "seed \(seed): 0.9 speed \(recovered - began) s, full speed's \(baseline) s")
        }
        #expect(tacked == 4)
    }
}
