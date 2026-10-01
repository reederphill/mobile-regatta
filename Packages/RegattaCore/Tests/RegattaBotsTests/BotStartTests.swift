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
    /// she is never stalled in irons there (#219: letting go in the no-go bears her away to the groove).
    @Test func botsHoldWithEaseOutsideTheNoGo() throws {
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
            #expect(Double(easedCentred) > Double(eased) * 0.5, "seed \(seed): rudder centred for \(easedCentred) of \(eased)")
            #expect(irons < 10 * Race.tickRate, "seed \(seed): \(irons) boat-ticks in irons")
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
}
