import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #276: a live bot's start strategy (`BotBrain+StartStrategy.swift`): the chooser, the late end read, and that every
/// other bot keeps today's plan (`starboardHold`). The bot suite measures them over many fleets (`BotStartSuiteTests`'s
/// start-strategy rows); these follow single bots.
@Suite struct BotStartStrategyTests {
    /// The chooser chooses at her first decision from T−45 and remembers it: in a fleet of live bots every bot chooses
    /// then, again only on a named abort (`StartStrategyAbort`), and the same race chooses the same. A takeover (`adopt`) clears it, and she chooses fresh at her
    /// first decision.
    @Test func chooserIsDeterministicAndSticky() throws {
        let window = Double(BotDriver.decisionInterval) / Double(Race.tickRate)
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
                // Chosen again only on a named abort, and never back to the plan it left.
                #expect(!list.isEmpty && list.dropFirst().allSatisfy { $0.abort != nil }, "seed \(seed) seat \(seat): chose \(list)")
                #expect(zip(list, list.dropFirst()).allSatisfy { $0.plan != $1.plan }, "seed \(seed) seat \(seat): chose \(list)")
                let time = list.first?.time ?? -.infinity
                #expect(time >= -BotBrain.chooseFromSeconds && time < -BotBrain.chooseFromSeconds + window,
                        "seed \(seed) seat \(seat): chose at \(time)")
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
        #expect(fresh.map { $0.time > before.time } == true, "took over: \(String(describing: fresh))")
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
                #expect(!brain.isLive && brain.startStrategy == nil && brain.lateEndSpot == nil,
                        "\(profile) seat \(seat): \(String(describing: brain.startStrategy))")
                #expect(controllers[seat].driver?.startStrategyAtGun == nil)
                #expect(controllers[seat].driver?.lateEndShiftAsked == nil)
            }
            let live = try #require(controllers[0].driver)
            #expect(live.brain.isLive && live.startStrategyAtGun != nil, "\(profile): the live bot chose")
        }
    }

    /// "Read the end late" (G4): a live bot alone below the line, the wind she reads scripted to a 10° bias either way,
    /// reads nothing at T−20; at T−15 she moves her spot towards the favoured end, no further than she still reaches
    /// (`lateEndReach`), and towards the pin she does move. The tactician, who reads the bias throughout, is unaffected.
    @Test func lateEndReadMovesTheSpotWithinReach() throws {
        for bias in [-10.0, 10.0] {
            for seed: UInt64 in [1, 2, 3] {
                let water = BotConductTests.Water(seed: seed, toGun: 20, below: 6)
                let c = water.race.course
                // Below and to the right of her spot, so her hold course on starboard lands on the line either side of it.
                let race = try BotConductTests.place(water, [
                    BotConductTests.Placement(position: water.centre + c.right * (water.length * 4),
                                              heading: water.heading(.starboard, deg2rad(50)), speed: 2, status: .prestart),
                    BotConductTests.Placement(position: water.centre + c.right * 400, heading: water.heading(.port, deg2rad(45)),
                                              speed: 2, status: .prestart),
                ])
                let line = c.startLine
                let along = (line.committee.position - line.pin.position).normalized
                // The wind direction she reads: the one nearest the race's whose bias to the line is `bias`.
                let square = atan2(along.x, along.y)
                let turn = Double.pi / 2 - deg2rad(bias)
                let scripted = [square + turn, square - turn].min { abs(wrapAngle($0 - water.wind)) < abs(wrapAngle($1 - water.wind)) }!

                func pilot(tactician: Bool) -> BotConductTests.Pilot {
                    var pilot = BotConductTests.Pilot(seat: 0, plannedTack: .starboard, race: race,
                                                      weaknesses: .none(skill: 1), helm: false)
                    pilot.brain.tactics.startsAtFavouredEnd = tactician
                    return pilot
                }
                var live = pilot(tactician: false), tactician = pilot(tactician: true)
                func read(_ pilot: inout BotConductTests.Pilot) -> SeatView {
                    let view = race.seatView(for: 0)
                    pilot.brain.senses.direction = scripted
                    pilot.brain.readLineBias(view.own, view)
                    pilot.brain.readEndLate(view.own, view)
                    return view
                }

                #expect(race.tick == -20 * Race.tickRate)
                _ = read(&live)
                _ = read(&tactician)
                #expect(live.brain.lateEndSpot == nil, "bias \(bias) seed \(seed): read before T-15")
                for _ in 0..<(5 * Race.tickRate) { race.step() }

                let view = read(&live)
                _ = read(&tactician)
                let base = live.brain.styleSpotOnLine
                let spot = try #require(live.brain.lateEndSpot, "bias \(bias) seed \(seed): no read at T-15")
                let reach = live.brain.lateEndReach(view.own, view, base: base, pinward: bias < 0)
                let label = "bias \(bias) seed \(seed): spot \(base) -> \(spot), reach \(reach)"
                #expect(abs(spot - base) <= reach + 1e-9, "\(label)")
                if bias < 0 {
                    #expect(reach > 0 && spot < base, "\(label)")
                } else {
                    #expect(spot >= base, "\(label)")
                }
                #expect(abs(live.brain.lateEndAsk?.shift ?? 0) >= abs(spot - base), "\(label): asked less than moved")

                #expect(tactician.brain.lateEndSpot == nil && tactician.brain.lateEndAsk == nil, "bias \(bias) seed \(seed)")
                let favoured = try #require(tactician.brain.favouredEndSpot)
                #expect(tactician.brain.spotOnLine == favoured)
                #expect((favoured - tactician.brain.style.startSpot) * bias > 0, "bias \(bias) seed \(seed): tactician at \(favoured)")
            }
        }
    }

    /// The scripted fleet's size: a line and race area of a 10-boat fleet's (the start suite's); she sails alone, the
    /// others placed well clear and left unsteered.
    static let scriptedFleet = 10

    /// One live bot in open water sailing the boat end from T−45 (`StartChoice` set before her first decision, so the
    /// chooser leaves it), on starboard 5 L below and 4 L right of the middle of the line, her style's spot 0.85: on
    /// `conditions` at seed `seed`, her start (ticks after the gun), whether she was over at the gun, her speed at the
    /// gun of close-hauled in the wind there, the plans she sailed, the wind in knots, and whether the boat end was
    /// feasible at her first decision (`isFeasible`).
    static func sailBoatEnd(conditions id: String, seed: UInt64) throws
        -> (start: Int?, overAtGun: Bool, speed: Double, plans: [StartStrategy], knots: Double, feasible: Bool) {
        let conditions = try ConditionsFile.bundled(id: id, version: 7)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .bot, count: Self.scriptedFleet), laps: 1,
                                  startSequenceTicks: 55 * Race.tickRate, boatClass: BotConductTests.waterClass,
                                  venue: venue.ref, conditions: conditions.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
        for _ in 0..<(10 * Race.tickRate) { race.step() }
        let c = race.course
        let length = race.boatClass.hull.length
        let at = c.startLine.centre - c.upwind * (length * 5) + c.right * (length * 4)
        let wind = race.groundWind(at: at)
        let polar = race.boatClass.polar
        var snapshot = race.exportSnapshot()
        for seat in 0..<Self.scriptedFleet {
            let heading = wind.direction - polar.bestUpwind(tws: wind.speed).twa
            snapshot.seats[seat].boat.position = seat == 0 ? at : at + c.right * 400 - c.upwind * (20 * Double(seat))
            snapshot.seats[seat].boat.heading = heading
            snapshot.seats[seat].boat.speed = 2
            snapshot.seats[seat].boat.boomSide = wrapAngle(wind.direction - heading) >= 0 ? .port : .starboard
            snapshot.seats[seat].boat.autohelm = Autohelm(target: .angle(abs(wrapAngle(wind.direction - heading))))
        }
        try race.importSnapshot(snapshot)
        var pilot = BotConductTests.Pilot(seat: 0, plannedTack: .starboard, race: race, weaknesses: .none(skill: 1), helm: false)
        var style = pilot.brain.style
        style.startSpot = 0.85
        pilot.brain = BotBrain(style: style, seed: 1, weaknesses: .none(skill: 1))
        pilot.brain.tactics = Tactics(profile: nil, skill: BotTier.national.skillBand.lowerBound, style: style,
                                      weaknesses: pilot.brain.weaknesses)
        pilot.brain.plannedTack = .starboard
        let first = race.seatView(for: 0)
        let feasible = pilot.brain.isFeasible(.boatEnd, first.own, first)
        pilot.brain.startStrategy = StartChoice(plan: .boatEnd, time: -45)
        pilot.steerByHand()
        var plans: [StartStrategy] = [.boatEnd]
        var start: Int?
        var over = false
        var speed = 0.0
        while race.tick < 10 * Race.tickRate, !race.isOver {
            _ = pilot.drive(race)
            race.step()
            if let sailed = pilot.brain.startStrategy?.plan, plans.last != sailed { plans.append(sailed) }
            if race.tick == 0 {
                let boat = race.boats[0]
                over = boat.status != .prestart
                speed = boat.speed / polar.bestUpwind(tws: race.groundWind(at: boat.position).speed).speed
            }
            if start == nil, race.boats[0].status == .racing { start = race.tick }
        }
        return (start, over, speed, plans, knots(metresPerSecond: wind.speed), feasible)
    }

    /// "Starboard boat-end" (owner G1′), sailed alone in open water from T−45 on light, classic and gusty winds (about 6
    /// to 20 kn on skiff@9): feasible, on the line within 3 s of the gun and not over it, on her plan throughout.
    @Test func boatEndReachesTheLineAtTheGun() throws {
        var lines: [String] = []
        var failures = 0
        for id in ["light-and-patchy", "classic-oscillating", "gusty-offshore"] {
            for seed: UInt64 in 1...4 {
                let r = try Self.sailBoatEnd(conditions: id, seed: seed)
                let ok = r.feasible && !r.overAtGun && (r.start.map { $0 <= 3 * Race.tickRate } ?? false) && r.plans == [.boatEnd]
                if !ok { failures += 1 }
                lines.append(String(format: "%@ s%d %.1f kn: feasible %@, start %@ s, over %@, speed %.2f, plans %@", id, seed,
                                    r.knots, "\(r.feasible)",
                                    r.start.map { String(format: "%.1f", Double($0) / Double(Race.tickRate)) } ?? "-",
                                    "\(r.overAtGun)", r.speed, "\(r.plans.map(\.rawValue))"))
            }
        }
        #expect(failures == 0, "\(lines.joined(separator: "\n"))")
    }
}
