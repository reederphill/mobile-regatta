@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// `regatta-botsuite --scenario overtake` (#530): a scripted boat sails the player's part, slow, and live bots come up
/// astern of her.
@Suite struct OvertakeScenarioTests {
    private func options(_ arguments: [String]) throws -> BotSuiteOptions {
        try BotSuiteOptions(arguments: ["--scenario", "overtake"] + arguments)
    }

    private func cell(seed: UInt64 = 1, phase: OvertakePhase = .beat, tack: OvertakeTack = .starboard, current: Bool = false,
                      astern: Double = 4, across: Double = 0, fleetSize: Int = 2, control: Bool = false) -> OvertakeCell {
        OvertakeCell(seed: seed, layout: OvertakeLayout(phase: phase, tack: tack, current: current, astern: astern, across: across,
                                                        fleetSize: fleetSize, control: control),
                     tierMix: .national)
    }

    /// A boat's offset from her in her frame at the placement, hull lengths: ahead along her heading, and to windward.
    private func offset(_ boat: Boat, from her: Boat, length: Double) -> (ahead: Double, windward: Double) {
        let frame = OvertakeScenario.frame(heading: her.heading, tack: her.tack)
        let offset = boat.position - her.position
        return (offset.dot(frame.forward) / length, offset.dot(frame.windward) / length)
    }

    // MARK: determinism

    /// The same options sail the same races, one job or four; a race with a current and one without place the boats
    /// alike about her.
    @Test func sameOptionsSailTheSameRaces() throws {
        let small = try options(["--seeds", "1", "--overtake-phase", "beat", "--overtake-tack", "starboard",
                                 "--overtake-astern", "2"])
        var serialOptions = small, parallelOptions = small
        serialOptions.jobs = 1
        parallelOptions.jobs = 4
        let serial = try OvertakeScenario.run(serialOptions)
        let again = try OvertakeScenario.run(serialOptions)
        let parallel = try OvertakeScenario.run(parallelOptions)
        #expect(serial.races.count == 2 * 3, "with and without a current, three offsets across")
        #expect(serial.races == again.races)
        #expect(serial.races == parallel.races)
        #expect(try serial.jsonData() == parallel.jsonData())
        for phase in OvertakePhase.allCases {
            let wet = try OvertakeScenario.placedRace(cell(phase: phase, current: true, across: 1)).race
            let dry = try OvertakeScenario.placedRace(cell(phase: phase, current: false, across: 1)).race
            let length = dry.boatClass.hull.length
            let a = offset(wet.boats[1], from: wet.boats[0], length: length)
            let b = offset(dry.boats[1], from: dry.boats[0], length: length)
            #expect(abs(a.ahead - b.ahead) < 1e-9 && abs(a.windward - b.windward) < 1e-9, "\(phase)")
        }
    }

    // MARK: placement

    /// Each bot on her tack, close-hauled, its slot astern of her and its offset across; she is on the beat a second
    /// after the gun, or below the line's middle before it; everyone inside the race area.
    @Test(arguments: OvertakePhase.allCases)
    func botsArePlacedAsternOfHer(phase: OvertakePhase) throws {
        for tack in OvertakeTack.allCases {
            for current in [true, false] {
                for astern in OvertakeScenario.defaultAstern {
                    for across in OvertakeScenario.defaultAcross {
                        // Before the gun the race area ends one line length below the line: room for one bot.
                        let size = phase == .beat ? 3 : 2
                        let cell = cell(phase: phase, tack: tack, current: current, astern: astern, across: across, fleetSize: size)
                        let (race, _, poses) = try OvertakeScenario.placedRace(cell)
                        let length = race.boatClass.hull.length
                        let boats = race.boats
                        let her = boats[0]
                        let up = race.boatClass.polar.bestUpwind(tws: race.groundWind(at: her.position).speed)
                        #expect(boats.count == size && poses.count == size)
                        for (seat, boat) in boats.enumerated() {
                            #expect(boat.tack == tack.tack)
                            #expect(boat.status == (phase == .beat ? .racing : .prestart) && boat.legIndex == 0)
                            #expect(abs(boat.heading - her.heading) < 1e-9)
                            #expect(race.course.raceArea.inset(boat.position) >= length, "seat \(seat) inside the area")
                            // Nothing owed from the unsteered sail to the placement (on the beat they touch in most races).
                            #expect(boat.penaltyTurnsOwed == 0 && boat.penaltyClockTick == nil && !race.isGhost(seat: seat))
                            guard seat > 0 else { continue }
                            let (ahead, windward) = offset(boat, from: her, length: length)
                            #expect(abs(ahead + astern + OvertakeScenario.slotSpacing * Double(seat - 1)) < 1e-9)
                            #expect(abs(windward - across) < 1e-9)
                        }
                        #expect(race.incidents.incidents.isEmpty && race.incidents.contacts.isEmpty, "no incident carried over")
                        // Close-hauled at the polar's best angle, as the placement read the wind.
                        #expect(abs(poses[0].twa - up.twa) < 0.05)
                        switch phase {
                        case .beat:
                            #expect(race.tick == Race.tickRate, "a second after the gun")
                            #expect(abs(her.speed / boats[1].speed - OvertakeScenario.targetShare) < 1e-9, "the bots at the polar's speed")
                        case .prestart:
                            #expect(race.tick == -OvertakeScenario.prestartLead * Race.tickRate)
                            // The current carries her, stalled, onto her spot below the line's middle by the gun.
                            let spot = OvertakeScenario.prestartSpot(course: race.course, forward: her.forward, length: length)
                            #expect(race.course.startLine.side(spot) < 0 && abs(race.course.startLine.side(spot)
                                + OvertakeScenario.prestartDepth * length) < 1e-6, "below the line")
                            #expect((spot - race.course.startLine.centre).dot(her.forward) < 0, "she sails towards the middle")
                            let drift = race.current.sample(spot, tick: race.tick) * Double(OvertakeScenario.prestartLead)
                            #expect((her.position + drift - spot).length < 1e-9)
                            #expect(current || her.position == spot)
                            #expect(her.speed == 0)
                        }
                    }
                }
            }
        }
    }

    /// The control puts her `controlAbeam` lengths across the course from her place, on the side the bots sail away
    /// from; the bots stay where they were.
    @Test(arguments: OvertakePhase.allCases)
    func theControlPutsHerFarAcrossTheCourse(phase: OvertakePhase) throws {
        for tack in OvertakeTack.allCases {
            let plain = try OvertakeScenario.placedRace(cell(phase: phase, tack: tack)).race
            let control = try OvertakeScenario.placedRace(cell(phase: phase, tack: tack, control: true)).race
            let length = plain.boatClass.hull.length
            #expect((control.boats[1].position - plain.boats[1].position).length < 1e-9)
            let moved = control.boats[0].position - plain.boats[0].position
            #expect(abs(moved.length - OvertakeScenario.controlAbeam * length) < 1e-9)
            #expect(abs(moved.dot(control.course.upwind)) < 1e-9, "straight across the course")
            #expect(moved.dot(control.boats[1].forward) < 0, "on the side the bots sail away from")
        }
    }

    /// A prestart race whose bots would start outside the race area (it ends a line length below the line) is left
    /// out and counted; a beat that can't be placed is a setup error.
    @Test func anUnplaceableRaceIsLeftOutBeforeTheGun() throws {
        #expect(throws: OvertakeUnplaced.self) { try OvertakeScenario.placedRace(cell(phase: .prestart, astern: 30)) }
        #expect(throws: PackScenarioError.self) { try OvertakeScenario.placedRace(cell(phase: .beat, astern: 300)) }
        var small = try options(["--seeds", "1", "--overtake-phase", "prestart", "--overtake-tack", "port",
                                 "--overtake-current", "without", "--overtake-astern", "30", "--overtake-astern", "2"])
        small.jobs = 1
        let report = try OvertakeScenario.run(small)
        #expect(report.unplaced.count == 3 && report.unplaced.allSatisfy { $0.layout.astern == 30 })
        #expect(report.races.count == 3 && report.races.allSatisfy { $0.layout.astern == 2 })
        #expect(report.lines[0].contains("3 not placed (50.0 % of all, 50.0 % of prestart"))
        #expect(report.unplacedShare == 0.5 && report.unplacedPrestartShare == 0.5)
    }

    /// The control's measures are read against a phantom of her where she would have been: the bot starts 4 lengths
    /// astern of it, so it comes no further than that, though she is 30 lengths away.
    @Test func theControlMeasuresAgainstAPhantom() throws {
        let race = try OvertakeScenario.sail(cell(control: true))
        let bot = try #require(race.bots.first)
        #expect(bot.closestApproach <= 4 + 1e-6 && bot.contacts == 0)
        #expect(race.layout.control)
    }

    // MARK: the scripted boat

    /// On the beat she holds 60-70 % of the polar for at least 90 % of the ticks after a 5 s settle, and her angle.
    @Test func theScriptedBoatHoldsHerSpeedShare() throws {
        let race = try OvertakeScenario.sail(cell())
        let inBand = try #require(race.herInBandShare)
        #expect(inBand >= 0.9, "in the band \(inBand) of the ticks, \(String(describing: race.herShareMin))...\(String(describing: race.herShareMax))")
        #expect(abs((race.herShareMean ?? 0) - OvertakeScenario.targetShare) < 0.03)
        #expect((race.herEasedShare ?? 0) > 0 && (race.herEasedShare ?? 1) < 1, "she eases and sheets in")
        #expect(race.ticks == OvertakeScenario.beatSeconds * Race.tickRate)
    }

    /// She holds her close-hauled angle by hand on the beat: her sailing angle stays near the placed one.
    @Test func theScriptedBoatHoldsHerAngle() throws {
        let (race, setup, poses) = try OvertakeScenario.placedRace(cell())
        var helm = ScriptedHelm(angle: poses[0].twa, eased: false, line: race.course.startLine,
                                hullLength: race.boatClass.hull.length)
        var controllers = SeatControllers([.human, .bot(TierMix.national.driver(seat: 1, raceSeed: setup.raceSeed).takingOver())])
        var worst = 0.0
        for _ in 0..<(20 * Race.tickRate) {
            _ = race.apply(helm.input(for: race.boats[0], boatClass: race.boatClass, secondsToGun: 0), seat: 0, atTick: race.tick + 1)
            controllers.drive(race)
            race.step()
            _ = race.drainEvents()
            worst = max(worst, abs(race.boats[0].sailingAngle - poses[0].twa))
        }
        #expect(worst < deg2rad(3), "off her angle by \(rad2deg(worst))°")
    }

    /// Before the gun she holds below the line and is never over it at the gun; after it she starts and sails on.
    @Test func theScriptedBoatHoldsBelowTheLine() throws {
        for tack in OvertakeTack.allCases {
            for current in [true, false] {
                let race = try OvertakeScenario.sail(cell(phase: .prestart, tack: tack, current: current))
                #expect(!race.herOCS, "\(tack) current \(current)")
                #expect((race.herShareMean ?? 0) > 0.5, "she started and sailed the beat")
                #expect(race.ticks == (OvertakeScenario.prestartLead + OvertakeScenario.afterGunSeconds) * Race.tickRate)
            }
        }
    }

    /// Owner (#530 c): a call on her stands, but she is never disqualified for the turn she never sails, and she stays
    /// a full rules participant: the bot's seat view gives her right of way as the race's rules relation does, every
    /// tick, and never a ghost. Seed 11, National, her stalled on port before the gun: a bot meets her there,
    /// and she is called. (Seed 1 until #537: there the bot now turns away from her, stalled, and nothing is called.)
    @Test func herPenaltiesAreWaivedAndTheBotsSeeHerRights() throws {
        let cell = OvertakeCell(seed: 11, layout: OvertakeLayout(phase: .prestart, tack: .port, current: false, astern: 4,
                                                                across: 1, fleetSize: 2, control: false), tierMix: .national)
        var ticks = 0, mismatches = 0, ghosts = 0, herKeepsClear = 0
        let result = try OvertakeScenario.sail(cell) { race, _ in
            ticks += 1
            let her = try? #require(race.seatView(for: 1).others.first { $0.seat == 0 })
            if her?.isGhost != false || race.isGhost(seat: 0) { ghosts += 1 }
            let relation = race.rightOfWay(1, 0)
            if relation == nil || her?.rightOfWay != relation { mismatches += 1 }
            if relation?.keepClear == 0 { herKeepsClear += 1 }
        }
        #expect(ticks > 0 && ghosts == 0 && mismatches == 0)
        #expect(herKeepsClear > 0, "she is the keep-clear boat to a starboard bot")
        #expect(try #require(result.bots.first).callsOnHer >= 1)
        #expect(result.herPenaltiesWaived >= 1 && !result.herDSQ)
    }

    // MARK: the probe

    /// The measures on a hand-built sequence: contacts and calls by pair, the closest approach, where the pass was
    /// chosen (a wander under 10° doesn't count), when the bot was clear ahead, and on which side.
    @Test func theProbeMeasuresAHandBuiltCase() throws {
        let hull = try OvertakeScenario.placedRace(cell()).race.boatClass.hull
        let length = hull.length
        // Her on starboard tack heading north: windward is east (+x). Seat 1 comes up astern; seat 2 is far off.
        func boat(_ id: Int, _ x: Double, _ y: Double, heading degrees: Double = 0) -> Boat {
            Boat(id: id, isPlayer: false, colorIndex: id, position: Vec2(x, y), heading: deg2rad(degrees), speed: 2, boomSide: .port)
        }
        let start = 100
        var probe = OvertakeProbe(seats: 3, hull: hull, startTick: start)
        var tick = start
        func step(_ bot: Boat, events: [RaceEvent.Kind] = []) {
            tick += 1
            probe.record(boats: [boat(0, 0, 0), bot, boat(2, 400, 0)], events: events.map { RaceEvent(tick: tick, kind: $0) },
                         tick: tick)
        }
        // Six lengths astern, wandering 5° for 3 s: no pass chosen.
        for _ in 0..<(3 * Race.tickRate) { step(boat(1, 0, -6 * length, heading: 5)) }
        #expect(probe.records[1].passChosen == nil)
        // A 15° turn to windward held 1 s, then straightened: still none.
        for _ in 0..<Race.tickRate { step(boat(1, 0, -6 * length, heading: 15)) }
        step(boat(1, 0, -6 * length))
        #expect(probe.records[1].passChosen == nil)
        // Five lengths astern, turned 12° to leeward and held 2 s: the pass was chosen at five lengths, to leeward.
        for i in 0..<(2 * Race.tickRate) { step(boat(1, -Double(i) * 0.01, -5 * length, heading: -12)) }
        let chosen = try #require(probe.records[1].passChosen)
        #expect(abs(chosen.lengths - 5) < 1e-9 && chosen.side == .leeward)
        // Alongside to leeward, 0.8 lengths off, with a contact and the calls: one on the bot (rule 12, she its victim),
        // one on her (she the offender), and a bot-bot call and contact that stay out of the pair.
        step(boat(1, -0.8 * length, 0), events: [
            .contact(SeatPair(0, 1)), .contact(SeatPair(1, 2)),
            .ruleCall(call(rule: .clearAstern, offender: 1, victim: 0)),
            .ruleCall(call(rule: .windwardLeeward, offender: 0, victim: 1)),
            .ruleCall(call(rule: .clearAstern, offender: 2, victim: 1)),
        ])
        // Clear ahead, to leeward, ten seconds from the placement's tick... once tick reaches it.
        // Touched again before separating: a repeat contact, counted in the contacts and apart.
        tick += 1
        probe.record(boats: [boat(0, 0, 0), boat(1, -0.8 * length, 0), boat(2, 400, 0)],
                     events: [RaceEvent(tick: tick, kind: .contact(SeatPair(0, 1)))], tick: tick, repeatContacts: [SeatPair(0, 1)])
        while tick < start + 10 * Race.tickRate - 1 { step(boat(1, -1.2 * length, 0)) }
        step(boat(1, -1.2 * length, 2 * length))
        let result = probe.result(seat: 1, tier: "national")
        #expect(result.contacts == 2 && result.repeatContacts == 1)
        #expect(result.callsByRule == ["12": 1] && result.callsOnHer == 1)
        #expect(probe.botBotContacts == 1 && probe.botBotCalls == 1)
        #expect(abs(result.closestApproach - 0.8) < 1e-9)
        #expect(result.passChosenLengths == 5 && result.passChosenSide == .leeward)
        #expect(result.clearAheadSeconds == 10)
        #expect(result.outcome == .passedLeeward)
        // Seat 2, far off and never past her, is still astern... of nothing: never clear ahead, no pass.
        let far = probe.result(seat: 2, tier: "national")
        #expect(far.passChosenLengths == nil && far.contacts == 0 && far.calls == 0)
    }

    /// A tack while clear astern is a pass chosen on the spot, side `tack`, and the outcome is tacked away: never a pass.
    @Test func aTackIsATackAwayNotAPass() throws {
        let hull = try OvertakeScenario.placedRace(cell()).race.boatClass.hull
        let length = hull.length
        var probe = OvertakeProbe(seats: 2, hull: hull, startTick: 0)
        let her = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 2, boomSide: .port)
        let tacked = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(0, -3 * length), heading: deg2rad(-90), speed: 2,
                          boomSide: .starboard)
        probe.record(boats: [her, tacked], events: [], tick: 1)
        let ahead = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(0, 3 * length), heading: deg2rad(-90), speed: 2,
                         boomSide: .starboard)
        probe.record(boats: [her, ahead], events: [], tick: 2)
        let result = probe.result(seat: 1, tier: "club")
        #expect(result.passChosenSide == .tack && abs((result.passChosenLengths ?? 0) - 3) < 1e-9)
        #expect(result.outcome == .tackedAway && result.clearAheadSeconds == nil)
    }

    private func call(rule: RacingRule, offender: Int, victim: Int) -> RuleCall {
        RuleCall(incidentId: 1, tick: 0, rule: rule, offender: offender, victim: victim, leg: 0, turnsOwed: 1,
                 startDeadlineTick: nil, completeDeadlineTick: nil)
    }

    // MARK: the report

    /// The rows pool the bots: per 100 bots, the tails of the closest approach, and the control apart.
    @Test func theRowsPoolTheBots() throws {
        func bot(_ closest: Double, contacts: Int = 0, calls: [String: Int] = [:], chosen: Double? = nil, clear: Double? = nil,
                 outcome: OvertakeOutcome = .stillAstern) -> OvertakeBotResult {
            OvertakeBotResult(seat: 1, tier: "national", contacts: contacts, callsByRule: calls, callsOnHer: 0, closestApproach: closest,
                              passChosenLengths: chosen, passChosenSide: chosen == nil ? nil : .windward, clearAheadSeconds: clear,
                              outcome: outcome, dirtySeconds: 1)
        }
        func race(_ bot: OvertakeBotResult, control: Bool = false) -> OvertakeRaceResult {
            OvertakeRaceResult(seed: 1, layout: OvertakeLayout(phase: .beat, tack: .port, current: false, astern: 2, across: 0,
                                                               control: control),
                               tierMix: .national, tideStateAtGun: nil, ticks: 1, bots: [bot], botBotContacts: 0, botBotCalls: 0,
                               herShareMean: 0.65, herShareMin: 0.6, herShareMax: 0.7, herInBandShare: 1, herEasedShare: 0.5,
                               herOCS: false)
        }
        let report = OvertakeReport(races: [
            race(bot(0.5, contacts: 1, calls: ["12": 1], chosen: 2, clear: 10, outcome: .passedWindward)),
            race(bot(1.2, calls: ["11": 1, "15": 1], chosen: 4, clear: 30, outcome: .passedLeeward)),
            race(bot(3.0)), race(bot(5.0)),
            race(bot(40), control: true),
        ])
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.group, $0) })
        let all = try #require(rows["all"])
        #expect(all.races == 4 && all.bots == 4)
        #expect(all.contactsPer100 == 25 && all.r12Per100 == 25 && all.r11Per100 == 25 && all.otherCallsPer100 == 25)
        #expect(all.closestMin == 0.5 && all.closestUnder1 == 1 && all.closestUnder13 == 2)
        #expect(all.passChosenShare == 0.5 && all.passChosenMedian == 3 && all.passChosenBySide == ["windward": 2])
        #expect(all.clearedShare == 0.5 && all.clearAheadMedian == 20 && all.clearAheadMax == 30)
        #expect(all.outcomeShares["passedWindward"] == 0.25 && all.outcomeShares["stillAstern"] == 0.5)
        #expect(rows["control all"]?.bots == 1 && rows["control all"]?.closestMin == 40)
        #expect(rows["beat astern 2"]?.bots == 4 && rows["beat tier national"]?.bots == 4)
        #expect(report.lines.count == 2 + report.rows.count)
        #expect(try JSONDecoder().decode(OvertakeReport.self, from: report.jsonData()) == report)
    }

    // MARK: usage

    @Test func badUsageExitsTwo() throws {
        for refused in [["--matrix", "m.json"], ["--thresholds", "t.json"], ["--profile-mix", "live"], ["--laps", "1"], ["--diagnose"],
                        ["--pack-offset", "0"], ["--pack-current", "with"], ["--pack-above", "50"], ["--fleet-size", "1"],
                        ["--overtake-phase", "reach"], ["--overtake-tack", "both-ways"], ["--overtake-current", "sometimes"],
                        ["--overtake-astern", "-2"]] {
            #expect(throws: BotSuiteError.self, "\(refused)") { try options(refused) }
            #expect(BotSuiteCommand.main(arguments: ["--scenario", "overtake"] + refused) == 2, "\(refused)")
        }
        // The overtake flags need the overtake scenario.
        for flags in [["--overtake-phase", "beat"], ["--overtake-tack", "port"], ["--overtake-current", "with"],
                      ["--overtake-astern", "2"], ["--overtake-control"]] {
            #expect(BotSuiteCommand.main(arguments: flags) == 2, "\(flags)")
            #expect(BotSuiteCommand.main(arguments: ["--scenario", "pack"] + flags) == 2, "\(flags)")
        }
        // The parsed flags.
        let parsed = try options(["--overtake-phase", "both", "--overtake-tack", "port", "--overtake-current", "without",
                                  "--overtake-astern", "3", "--overtake-astern", "5", "--overtake-control", "--fleet-size", "2"])
        #expect(parsed.overtakePhases == OvertakePhase.allCases && parsed.overtakeTacks == [.port])
        #expect(parsed.overtakeCurrent == .without && parsed.overtakeAstern == [3, 5] && parsed.overtakeControl)
        #expect(OvertakeScenario.layouts(parsed).count == 2 * 2 * 1 * 2 * 3, "control, phases, tack, current, astern, across")
        // The default sweep: 72 layouts.
        #expect(OvertakeScenario.layouts(try options([])).count == 72)
    }

    /// No thresholds: a sailed run exits 0, and writes its JSON.
    @Test func aSailedRunExitsZero() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overtake-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let status = BotSuiteCommand.main(arguments: ["--scenario", "overtake", "--seeds", "1", "--overtake-phase", "beat",
                                                      "--overtake-tack", "port", "--overtake-current", "without",
                                                      "--overtake-astern", "4", "--jobs", "1", "--json", file.path])
        #expect(status == 0)
        let report = try JSONDecoder().decode(OvertakeReport.self, from: Data(contentsOf: file))
        #expect(report.scenario == "overtake" && report.races.count == 3 && report.rows.first?.group == "all")
    }
}
