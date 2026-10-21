import Testing
import RegattaCore
@testable import RegattaBots

/// #276: a live bot's named start strategies (`BotBrain+StartStrategy.swift`): the chooser, `boatEnd`, and that every
/// other bot keeps today's plan (`starboardHold`). The bot suite measures them over many fleets (`BotStartSuiteTests`'s
/// start-strategy rows); these follow single bots.
@Suite struct BotStartStrategyTests {
    /// A live bot set on the committee end and liking the boat end, with no weaknesses (no misread of the line's bias):
    /// she chooses `boatEnd` in open water.
    static func boatEndPilot(seat: Int, _ race: Race) -> BotConductTests.Pilot {
        var pilot = BotConductTests.Pilot(seat: seat, plannedTack: .starboard, race: race, helm: false)
        var style = BotConductTests.skill1
        style.startSpot = 0.85
        style.boatEndDraw = 1
        let weaknesses = BotWeaknesses.none(skill: 1)
        pilot.brain = BotBrain(style: style, seed: UInt64(seat + 1), weaknesses: weaknesses)
        pilot.brain.tactics = Tactics(profile: nil, skill: BotTier.national.skillBand.lowerBound, style: style, weaknesses: weaknesses)
        pilot.brain.plannedTack = .starboard
        pilot.steerByHand()
        return pilot
    }

    /// "Starboard boat-end": alone in open water, 60 s before the gun mid-line and 6 lengths below it, she chooses the
    /// boat end, is close to the committee boat 10 s before the gun, not over the line at the gun, and starts within 3 s
    /// of it, on the plan she chose or, the pin end read favoured late, on today's plan by its named abort.
    @Test func boatEndReachesTheLineAtTheGun() throws {
        for seed: UInt64 in [1, 2, 3, 4] {
            let water = BotConductTests.Water(seed: seed, toGun: 60, below: 6)
            let c = water.race.course
            let race = try BotConductTests.place(water, [
                BotConductTests.Placement(position: water.centre, heading: water.heading(.starboard, deg2rad(45)), speed: 2,
                                          status: .prestart),
                BotConductTests.Placement(position: water.centre + c.right * 400, heading: water.heading(.port, deg2rad(45)),
                                          speed: 2, status: .prestart),
            ])
            var pilot = Self.boatEndPilot(seat: 0, race)
            var plans: [StartStrategy] = []
            var started: Int?
            var nearBoat: Double?
            while race.tick < 10 * Race.tickRate, !race.isOver {
                _ = pilot.drive(race)
                race.step()
                if let plan = pilot.brain.startStrategy?.plan, plans.last != plan { plans.append(plan) }
                if race.tick == -10 * Race.tickRate {
                    nearBoat = (race.boats[0].position - c.startLine.committee.position).length / water.length
                }
                if race.tick == 0 {
                    #expect(race.boats[0].status == .prestart, "seed \(seed): over the line at the gun")
                }
                if started == nil, race.boats[0].status == .racing { started = race.tick }
            }
            // Seed 3 reads the pin end favoured late (`readEndLate`) and leaves the boat end on its named abort.
            let abort = pilot.brain.startStrategy?.abort
            #expect(plans == [.boatEnd] || (plans == [.boatEnd, .starboardHold] && abort == .endNotHers),
                    "seed \(seed): sailed \(plans), \(String(describing: abort))")
            #expect((nearBoat ?? .infinity) <= 5, "seed \(seed): \(nearBoat ?? -1) lengths from the committee boat at T-10")
            #expect(started.map { $0 <= 3 * Race.tickRate } == true, "seed \(seed): started at tick \(started ?? -1)")
        }
    }

    /// The chooser chooses once and keeps to it: in a fleet of live bots, every bot has chosen by the gun, a plan is
    /// chosen again only on a named abort and never back to the plan it left, and the same race chooses the same. A
    /// takeover chooses fresh, at her first decision.
    @Test func chooserIsDeterministicAndSticky() throws {
        func choices(seed: UInt64) -> [[StartChoice]] {
            let race = BotStartTests.startRace(seed: seed)
            var controllers = allBots(race)
            var seen = Array(repeating: [StartChoice](), count: race.boats.count)
            for _ in 0..<(60 * Race.tickRate) where !race.isOver {
                controllers.drive(race)
                race.step()
                for seat in race.boats.indices {
                    guard let choice = controllers[seat].driver?.brain.startStrategy else { continue }
                    if seen[seat].last != choice { seen[seat].append(choice) }
                }
            }
            return seen
        }
        for seed: UInt64 in [1, 2, 3] {
            let seen = choices(seed: seed)
            #expect(seen == choices(seed: seed), "seed \(seed): the same race chose alike")
            for (seat, list) in seen.enumerated() {
                #expect(!list.isEmpty, "seed \(seed) seat \(seat): never chose")
                #expect(list.first.map { $0.time >= -BotBrain.chooseFromSeconds && $0.abort == nil } == true,
                        "seed \(seed) seat \(seat): first choice \(String(describing: list.first))")
                // Within a plan only its own state moves (`leftForTheBoat`); a new plan comes with its abort.
                let plans = list.map(\.plan).reduce(into: [StartStrategy]()) { if $0.last != $1 { $0.append($1) } }
                for (index, choice) in list.enumerated().dropFirst() where choice.plan != list[index - 1].plan {
                    #expect(choice.abort != nil, "seed \(seed) seat \(seat): switched without an abort")
                }
                #expect(Set(plans).count == plans.count, "seed \(seed) seat \(seat): went back to a plan: \(plans)")
            }
        }

        // A takeover at T−30 chooses fresh at her first decision, whatever the bot she replaces had chosen.
        let race = BotStartTests.startRace(seed: 2)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: 30 * Race.tickRate)
        let before = try #require(controllers[0].driver?.brain.startStrategy)
        controllers.takeOver(seat: 0, driver: try #require(controllers[0].driver))
        #expect(controllers[0].driver?.brain.startStrategy == before, "nothing changes until she decides")
        var fresh: StartChoice?
        for _ in 0..<BotDriver.decisionInterval {
            controllers.drive(race)
            race.step()
            if fresh == nil, let choice = controllers[0].driver?.brain.startStrategy, choice.time != before.time { fresh = choice }
        }
        #expect(fresh.map { $0.time > before.time && $0.abort == nil } == true, "took over: \(String(describing: fresh))")
    }

    /// Profiles and the cautious bot keep today's plan (T3): they choose nothing, read no end late and sail no other
    /// spot, so the parity, skillGap and funPass mixes sail as before #276. A live bot in the same fleet chooses.
    @Test func profilesAndCautiousKeepTodaysPlan() throws {
        for profile in BotProfile.allCases {
            let race = BotStartTests.startRace(seed: 3)
            var controllers = SeatControllers(race.boats.indices.map { seat in
                .bot(seat == 0 ? BotDriver(seat: seat, raceSeed: race.setup.raceSeed)
                               : BotDriver(seat: seat, raceSeed: race.setup.raceSeed, profile: profile))
            })
            controllers.takeOver(seat: 1, raceSeed: race.setup.raceSeed, cautious: true)
            sail(race, &controllers, ticks: 60 * Race.tickRate - 1)
            for seat in race.boats.indices.dropFirst() {
                let brain = try #require(controllers[seat].driver?.brain)
                #expect(!brain.isLive && brain.startStrategy == nil && brain.lateEndSpot == nil && brain.strategySpot == nil,
                        "\(profile) seat \(seat): \(String(describing: brain.startStrategy))")
                #expect(controllers[seat].driver?.startStrategyAtGun == nil)
            }
            let live = try #require(controllers[0].driver)
            #expect(live.brain.isLive && live.startStrategyAtGun != nil, "\(profile): the live bot chose")
        }
    }
}
