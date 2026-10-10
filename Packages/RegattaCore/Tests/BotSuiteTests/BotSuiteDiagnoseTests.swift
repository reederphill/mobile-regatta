import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// `regatta-botsuite --diagnose` (#471): the rules that name a cause, on records written out by hand; the observer's
/// bookkeeping, on a race it is fed the events of; and that watching a race changes neither the race nor the rest of
/// the report.
@Suite struct BotSuiteDiagnoseTests {
    // MARK: - Late starters

    /// A late start that meets every cause at once, and where she was at the gun.
    static func lateForEveryReason(startSeconds: Double? = 12) -> StartObservation {
        var start = StartObservation(startSeconds: startSeconds)
        start.penaltySeconds = 8
        start.ocs = true
        start.ironsSeconds = 5
        start.cannotFetchSeconds = 4
        start.onPortAtTwentySeconds = true
        start.lateTurns = 1
        start.keepingClearSeconds = 6
        start.atGun = .init(metresBelowLine: 4, targetSpeed: 4)
        return start
    }

    /// Each cause in the re-trace's priority order: with the causes before it taken away one by one, the next names
    /// the start.
    @Test func lateCauseIsTheFirstInThePriorityOrder() {
        var start = Self.lateForEveryReason()
        let remove: [(LateCause, (inout StartObservation) -> Void)] = [
            (.penalty, { $0.penaltySeconds = 0 }),
            (.ocs, { $0.ocs = false }),
            (.irons, { $0.ironsSeconds = 3.9 }),
            (.cannotFetchPin, { $0.cannotFetchSeconds = 2.9 }),
            (.port, { $0.onPortAtTwentySeconds = false }),
            (.lateTurn, { $0.lateTurns = 0 }),
            (.keepingClear, { $0.keepingClearSeconds = 2.9 }),
            // 4 m off at 4 m/s is a second from the line: slow. 40 m off is ten: deep.
            (.slow, { $0.atGun = .init(metresBelowLine: 40, targetSpeed: 4) }),
            (.deep, { $0.atGun = nil }),
        ]
        var seen: [LateCause] = []
        for (cause, next) in remove {
            #expect(LateCause.of(start) == cause)
            seen.append(cause)
            next(&start)
        }
        #expect(LateCause.of(start) == .other)
        #expect(seen + [.other] == LateCause.allCases, "the cases are declared in the priority order")
    }

    @Test func lateCauseThresholds() {
        // On time, whatever else she did: no cause.
        #expect(LateCause.of(Self.lateForEveryReason(startSeconds: 3)) == nil)
        #expect(LateCause.of(Self.lateForEveryReason(startSeconds: 3.1)) == .penalty)
        // A boat that never started has a cause too.
        #expect(LateCause.of(Self.lateForEveryReason(startSeconds: nil)) == .penalty)

        // A penalty: 3 s owing a turn, or any time owing one with a pre-start penalty unserved 30 s before the gun.
        var start = StartObservation(startSeconds: 20)
        start.atGun = .init(metresBelowLine: 60, targetSpeed: 4)
        start.penaltySeconds = 2.9
        #expect(LateCause.of(start) == .deep)
        start.preStartPenaltyUnserved = true
        #expect(LateCause.of(start) == .penalty)
        start.penaltySeconds = 0
        #expect(LateCause.of(start) == .deep, "served before the window opened: not what made her late")
        start.preStartPenaltyUnserved = false
        start.penaltySeconds = 3
        #expect(LateCause.of(start) == .penalty)

        // Slow against deep: within 5 s of the line at her target speed, a stopped boat's taken as 0.5 m/s.
        start.penaltySeconds = 0
        start.atGun = .init(metresBelowLine: 20, targetSpeed: 4)
        #expect(LateCause.of(start) == .slow)
        start.atGun = .init(metresBelowLine: 20.1, targetSpeed: 4)
        #expect(LateCause.of(start) == .deep)
        start.atGun = .init(metresBelowLine: 2.4, targetSpeed: 0)
        #expect(LateCause.of(start) == .slow)
        start.atGun = .init(metresBelowLine: 2.6, targetSpeed: 0)
        #expect(LateCause.of(start) == .deep)
    }

    // MARK: - Penalty episodes

    @Test func penaltyPhaseIsThePreStartUntilSheStarts() {
        #expect(PenaltyPhase.at(tick: -1, status: .prestart, leg: 0, legs: 5) == .preStart)
        #expect(PenaltyPhase.at(tick: 90, status: .prestart, leg: 0, legs: 5) == .preStart)
        #expect(PenaltyPhase.at(tick: 90, status: .ocs, leg: 0, legs: 5) == .preStart)
        #expect(PenaltyPhase.at(tick: 90, status: .racing, leg: 0, legs: 5) == .firstBeat)
        #expect(PenaltyPhase.at(tick: 90, status: .racing, leg: 1, legs: 5) == .laterLegs)
        #expect(PenaltyPhase.at(tick: 90, status: .racing, leg: 3, legs: 5) == .laterLegs)
        #expect(PenaltyPhase.at(tick: 90, status: .racing, leg: 4, legs: 5) == .lastLeg)
    }

    @Test func resetCauseReadsHerRudderAndTheBoatsRoundHer() {
        func cause(rudder: Double, degreesIn: Double = 120, heldOver: Bool = true, nearest: Double = 10, direction: Double = 1) -> ResetCause {
            ResetCause.of(ResetObservation(rudder: rudder, direction: direction, degreesIn: degreesIn, heldOver: heldOver,
                                           nearestBoatLengths: nearest))
        }
        // Hard over the other way: for a boat within three lengths, else her own reversal. Either way round.
        #expect(cause(rudder: -1, nearest: 3) == .gaveUpForBoat)
        #expect(cause(rudder: -1, nearest: 3.1) == .reversed)
        #expect(cause(rudder: 0.7, nearest: 1, direction: -1) == .gaveUpForBoat)
        #expect(cause(rudder: 0.5, direction: -1) == .reversed)
        // Part rudder against it, or a turn she was never turning (30° of sailing started it): steering a course.
        #expect(cause(rudder: -0.4, nearest: 1) == .steeredOff)
        #expect(cause(rudder: -1, degreesIn: 45, heldOver: false, nearest: 1) == .steeredOff)
        #expect(cause(rudder: -1, degreesIn: 45, heldOver: true, nearest: 1) == .gaveUpForBoat)
        #expect(cause(rudder: -1, degreesIn: 60, heldOver: false) == .reversed)
        // Her rudder not against it: centred she had let go; still over, her heading went back anyway.
        #expect(cause(rudder: 0, nearest: 1) == .letGo)
        #expect(cause(rudder: 0.7, nearest: 1) == .other)
        #expect(cause(rudder: -0.7, direction: -1) == .other)
    }

    // MARK: - Non-finishers

    @Test func nonFinishCauseIsTheFirstThatHolds() {
        func finish(_ status: BoatStatus, _ edit: (inout FinishObservation) -> Void = { _ in }) -> NonFinishCause? {
            var finish = FinishObservation(status: status)
            finish.metresToGo = 150
            finish.metresMadeInLast90Seconds = 200
            edit(&finish)
            return NonFinishCause.of(finish)
        }
        #expect(finish(.finished) { $0.turnsServed = 4 } == nil)
        #expect(finish(.dsq) { $0.missedPenalty = true; $0.turnsServed = 4 } == .missedPenalty)
        #expect(finish(.dsq) == .other)
        #expect(finish(.prestart) { $0.turnsServed = 2 } == .other, "never started")
        #expect(finish(.ocs) == .other)
        // Sailing when the window closed: by the turns she had served.
        #expect(finish(.racing) == .noTurns)
        #expect(finish(.racing) { $0.turnsServed = 1 } == .afterOneOrTwoTurns)
        #expect(finish(.racing) { $0.turnsServed = 2 } == .afterOneOrTwoTurns)
        #expect(finish(.racing) { $0.turnsServed = 3 } == .afterThreeTurns)
        // Not out long enough to say she stalled: by her turns.
        #expect(finish(.racing) { $0.metresMadeInLast90Seconds = nil; $0.edgeSeconds = 60 } == .noTurns)
        // Stalled, under 30 m in her last 90 s: stuck at the edge or by what she touched, else other. Before her turns.
        #expect(finish(.racing) { $0.metresMadeInLast90Seconds = 29; $0.edgeSeconds = 10; $0.turnsServed = 5 } == .stuck)
        #expect(finish(.racing) { $0.metresMadeInLast90Seconds = 29; $0.touchedLate = true } == .stuck)
        #expect(finish(.racing) { $0.metresMadeInLast90Seconds = 29; $0.edgeSeconds = 9; $0.turnsServed = 5 } == .other)
        #expect(finish(.racing) { $0.metresMadeInLast90Seconds = 30; $0.edgeSeconds = 60; $0.turnsServed = 5 } == .afterThreeTurns)
    }

    // MARK: - The observer

    static func cell(seed: UInt64 = 5, fleetSize: Int = 2, tierMix: TierMix = .national) -> BotRaceCell {
        BotMatrix(seeds: [seed], fleetSizes: [fleetSize], tierMixes: [tierMix], laps: 1, capSecondsAfterGun: 240).cells[0]
    }

    /// A scripted race: two boats nobody steers, and the observer fed the events of a start and of two penalty
    /// episodes at set ticks. What it makes of them doesn't move when the bots do.
    @Test func observerKeepsTheEpisodesAndTheStartsItIsTold() throws {
        let cell = Self.cell()
        let setup = try BotRaceHarness.raceSetup(for: cell)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        let rate = Race.tickRate
        // Seconds after the gun, by seat 0 unless said: a mark touch before the gun opens an episode; 30° in, given
        // up, in again; a second touch stacks; both turns served. Then a touch after her start, served unannounced.
        let script: [Int: [RaceEvent.Kind]] = [
            -30 * rate: [.markTouch(seat: 0, mark: "pin")],
            -28 * rate: [.penaltyStarted(seat: 0)],
            -26 * rate: [.penaltyReset(seat: 0)],
            -25 * rate: [.penaltyStarted(seat: 0)],
            -24 * rate: [.markTouch(seat: 0, mark: "pin")],
            -15 * rate: [.penaltyServed(seat: 0)],
            -10 * rate: [.tacked(seat: 0), .gybed(seat: 0)],
            0: [.ocsNotice(recipient: 0)],
            2 * rate: [.penaltyServed(seat: 0), .started(seat: 1)],
            12 * rate: [.started(seat: 0)],
            20 * rate: [.markTouch(seat: 0, mark: "windward")],
            31 * rate: [.penaltyServed(seat: 0)],
        ]
        var observer = RaceObserver(race: race)
        while race.tick < 40 * rate {
            race.step()
            _ = race.drainEvents()
            observer.record(race, events: (script[race.tick] ?? []).map { RaceEvent(tick: race.tick, kind: $0) })
            // The script is all that happens to seat 0: the race itself leaves her alone (seat 1, adrift, it may not).
            try #require(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .prestart,
                         "seat 0 was called or moved on at \(race.tick): script another seed")
        }
        let boats = observer.boats(of: race, tiers: [.national, .club])
        #expect(boats.map(\.tier) == [.national, .club])

        let first = try #require(boats[0].episodes.first)
        #expect(boats[0].episodes.count == 2)
        #expect(boats[0].turnsOwed == 3)
        #expect(first.phase == .preStart)
        #expect(first.callSeconds == -30)
        #expect(first.calls == 2)
        #expect(first.turnsServed == 2)
        #expect(first.outcome == .served)
        #expect(first.secondsToStarted == 2, "to the first 30° in, not the one after she gave it up")
        #expect(first.secondsTurning == 30)
        #expect(first.turnSeconds == [15, 17], "each turn from its clock: the call, then the turn before served")
        // Nobody steers: her rudder is centred when the turn is given up.
        #expect(first.resets == [.letGo: 1])
        let second = boats[0].episodes[1]
        // The race never started her (nobody sails her over the line), so the race's phase is still the pre-start.
        #expect(second.phase == .preStart)
        #expect(second.callSeconds == 20)
        #expect(second.calls == 1 && second.turnsServed == 1)
        #expect(second.secondsToStarted == 11 && second.secondsTurning == 0, "served without the 30° announced")
        #expect(second.turnSeconds == [11])
        #expect(boats[1].episodes.isEmpty && boats[1].turnsOwed == 0)

        #expect(boats[0].start.startSeconds == 12)
        #expect(boats[0].start.ocs)
        #expect(boats[0].start.preStartPenaltyUnserved, "served 2 s after the gun")
        #expect(boats[0].start.lateTurns == 2, "a tack and a gybe inside the last 20 s")
        // The race itself never owed her a turn (the events were scripted), so no penalty seconds: OCS is her cause.
        #expect(boats[0].start.penaltySeconds == 0)
        #expect(LateCause.of(boats[0].start) == .ocs)
        #expect(boats[0].start.atGun != nil)
        // Seat 1 has only her start: seat 0's events are seat 0's.
        #expect(boats[1].start.startSeconds == 2)
        #expect(boats[1].start.lateTurns == 0)
        #expect(!boats[1].start.ocs && !boats[1].start.preStartPenaltyUnserved)
        #expect(LateCause.of(boats[1].start) == nil)

        // She never finished: nobody sailed her.
        #expect(boats[0].finish.status == .prestart && boats[0].finish.metresToGo > 0)
        #expect(NonFinishCause.of(boats[0].finish) == .other, "never started, as the race has it")
        #expect(boats[0].finish.turnsServed == 3 && boats[1].finish.turnsServed == 0)
        #expect(boats[0].finish.touchedLate && !boats[1].finish.touchedLate)
        #expect(boats[0].finish.metresMadeInLast90Seconds != nil, "100 s on the water")
    }

    /// A race's digest after `seconds` from the gun, its bots sailing it, with a `RaceObserver` watching or not.
    static func digest(boatClass: BoatClassFile, seed: UInt64, seconds: Int, observed: Bool) throws -> (digest: UInt64, boats: [BoatDiagnosis]) {
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(boatClass)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .bot, count: 8), laps: 1,
                                  boatClass: boatClass.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: seed)))
        var controllers = SeatControllers(setup: setup)
        var observer = observed ? RaceObserver(race: race) : nil
        while !race.isOver && race.tick < seconds * Race.tickRate {
            controllers.drive(race)
            race.step()
            let events = race.drainEvents()
            observer?.record(race, events: events)
        }
        let tiers = Array(repeating: BotTier.national, count: race.boats.count)
        return (race.digest(), observer?.boats(of: race, tiers: tiers) ?? [])
    }

    /// The observer only reads: a race on skiff@8 (the default class, turned by hand) and on skiff@7 (the tap and the
    /// roll, whose bots stay bit-identical, `BotHandTackTests.skiffSevenBotsAreBitIdentical`) has the same digest
    /// watched or not.
    @Test(arguments: [7, 8]) func observingLeavesTheRaceBitIdentical(version: Int) throws {
        let boatClass = try BoatClassFile.bundled(id: "skiff", version: version)
        let plain = try Self.digest(boatClass: boatClass, seed: 471, seconds: 150, observed: false)
        let watched = try Self.digest(boatClass: boatClass, seed: 471, seconds: 150, observed: true)
        #expect(watched.digest == plain.digest)
        #expect(watched.boats.count == 8)
        #expect(watched.boats.contains { $0.start.startSeconds != nil }, "the observer saw the race it watched")
    }

    // MARK: - The report

    /// Off by default, and with it on the report gains its `diagnose` key and nothing else changes: the races, the
    /// summaries and the gate are the same bytes, and the text is the same lines with the tables after them.
    @Test func diagnoseAddsItsTablesAndChangesNothingElse() throws {
        let matrix = BotMatrix(seeds: [5, 6], fleetSizes: [5], tierMixes: [.mixed, .national], laps: 1, capSecondsAfterGun: 240)
        let plain = try BotSuite.run(matrix, thresholds: unmissableThresholds())
        let diagnosed = try BotSuite.run(matrix, thresholds: unmissableThresholds(), diagnose: true)
        #expect(plain.diagnose == nil)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: plain.jsonData()) as? [String: Any])
        #expect(plainJSON["diagnose"] == nil, "no key without the flag")

        var stripped = diagnosed
        stripped.diagnose = nil
        #expect(try jsonWithoutTimings(stripped) == jsonWithoutTimings(plain))
        #expect(diagnosed.passed == plain.passed && diagnosed.breaches == plain.breaches)
        // The tick line carries the run's timings; every other line is the same, and the tables follow.
        func untimed(_ lines: [String]) -> [String] { lines.filter { !$0.hasPrefix("tick:") } }
        let summary = try #require(diagnosed.diagnose)
        #expect(untimed(diagnosed.lines) == untimed(plain.lines) + summary.lines)
        #expect(summary.lines.first?.hasPrefix("diagnose: 4 races") == true)

        // The JSON's shape: the seven keys, each table's rows in their fixed order.
        let json = try #require(JSONSerialization.jsonObject(with: diagnosed.jsonData()) as? [String: Any])
        let diagnose = try #require(json["diagnose"] as? [String: Any])
        #expect(Set(diagnose.keys) == ["races", "starts", "lateStarters", "penaltyEpisodes", "penaltiesOwed", "preStartCalls",
                                       "nonFinishers"])
        let boats = diagnosed.races.flatMap(\.seats)
        let tiers = [DiagnoseSummary.all] + BotTier.allCases.filter { tier in boats.contains { $0.tier == tier } }.map(\.rawValue)
        #expect(tiers.count >= 2)
        #expect(summary.races == 4)
        #expect(summary.starts.map(\.tier) == tiers)
        #expect(summary.penaltiesOwed.map(\.tier) == tiers)
        #expect(summary.preStartCalls.map(\.tier) == tiers)
        let lateCauses = LateCause.allCases.map(\.rawValue) + [DiagnoseSummary.all]
        #expect(summary.lateStarters.map(\.cause) == Array(repeating: lateCauses, count: 2 * tiers.count).flatMap { $0 })
        #expect(summary.lateStarters.map(\.overSeconds) == [5, 10].flatMap { Array(repeating: $0, count: tiers.count * lateCauses.count) })
        let phases = [DiagnoseSummary.all] + PenaltyPhase.allCases.map(\.rawValue)
        #expect(summary.penaltyEpisodes.map(\.phase) == Array(repeating: phases, count: tiers.count).flatMap { $0 })
        #expect(summary.penaltyEpisodes.map(\.tier) == tiers.flatMap { Array(repeating: $0, count: phases.count) })
        #expect(summary.penaltyEpisodes.allSatisfy { Set($0.resetsPerEpisodeByCause.keys) == Set(ResetCause.allCases.map(\.rawValue)) })
        let finishCauses = NonFinishCause.allCases.map(\.rawValue) + [DiagnoseSummary.all]
        #expect(summary.nonFinishers.map(\.cause) == Array(repeating: finishCauses, count: tiers.count).flatMap { $0 })
        let episodeRow = try #require((diagnose["penaltyEpisodes"] as? [[String: Any]])?.first)
        #expect(Set(episodeRow.keys).isSuperset(of: ["tier", "phase", "episodes", "served", "disqualified", "open", "oneTurnEpisodes",
                                                     "resetsPerEpisode", "resetsPerEpisodeByCause", "stackedShare", "turnsServed",
                                                     "slowTurnShare"]))

        // The tables agree with the report's own counts of the same races.
        let all = try #require(summary.starts.first)
        #expect(all.boats == boats.count)
        let started = boats.compactMap(\.startSeconds)
        #expect(all.neverStarted == boats.count - started.count)
        let onTime: Double = Double(started.filter { $0 <= 3 }.count) / Double(boats.count)
        #expect(all.onTimeShare == onTime)
        for over in [5, 10] {
            let late = boats.filter { ($0.startSeconds ?? .infinity) > Double(over) }.count
            let rows = summary.lateStarters.filter { $0.overSeconds == over && $0.tier == DiagnoseSummary.all }
            let byCause: Int = rows.dropLast().map(\.boats).reduce(0, +)
            #expect(rows.last?.boats == late)
            #expect(byCause == late, "one cause a late boat")
        }
        let unfinished = boats.filter { !$0.finished }.count
        let finishRows = summary.nonFinishers.filter { $0.tier == DiagnoseSummary.all }
        let unfinishedByCause: Int = finishRows.dropLast().map(\.boats).reduce(0, +)
        #expect(finishRows.last?.boats == unfinished)
        #expect(unfinishedByCause == unfinished)
        let calls = try #require(summary.preStartCalls.first)
        let tableCalls: Int = calls.calls.values.reduce(0, +)
        let seatCalls: Int = boats.flatMap(\.preStartCallsByRule.values).reduce(0, +)
        #expect(tableCalls == seatCalls)
        let episodes = try #require(summary.penaltyEpisodes.first)
        let outcomes: Int = episodes.served + episodes.disqualified + episodes.open
        #expect(episodes.episodes == outcomes)
        let byPhase: Int = summary.penaltyEpisodes.filter { $0.tier == DiagnoseSummary.all }.dropFirst().map(\.episodes).reduce(0, +)
        #expect(byPhase == episodes.episodes)
    }

    /// The harness's diagnosed run is its plain run, seat for seat, and the observer's starts are the tally's.
    @Test func diagnosedRunIsThePlainRun() throws {
        let cell = Self.cell(seed: 7, fleetSize: 10)
        let plain = try BotRaceHarness.run(cell)
        let (result, diagnosis) = try BotRaceHarness.runDiagnosed(cell)
        #expect(result.seats == plain.seats)
        #expect(result.raceSeconds == plain.raceSeconds)
        #expect(diagnosis.cell == cell)
        #expect(diagnosis.boats.map(\.start.startSeconds) == plain.seats.map(\.startSeconds))
        #expect(diagnosis.boats.map(\.tier) == plain.seats.map(\.tier))
        for (boat, seat) in zip(diagnosis.boats, plain.seats) {
            #expect((NonFinishCause.of(boat.finish) == nil) == seat.finished)
            let calls: Int = boat.episodes.map(\.calls).reduce(0, +)
            let served: Int = boat.episodes.map(\.turnsServed).reduce(0, +)
            let given: Int = seat.foulsAsOffender + seat.markContacts
            #expect(boat.turnsOwed <= given)
            #expect(calls == boat.turnsOwed)
            #expect(boat.finish.turnsServed == served)
            #expect(boat.episodes.allSatisfy { $0.turnsServed <= $0.calls && $0.turnSeconds.count == $0.turnsServed })
        }
    }

    #if os(macOS) || os(Linux)
    @Test func diagnoseFlagPrintsTheTablesAfterTheGate() throws {
        #expect(try !BotSuiteOptions(arguments: []).diagnose)
        #expect(try BotSuiteOptions(arguments: ["--diagnose"]).diagnose)
        let arguments = ["--seeds", "1", "--fleet-size", "2", "--tier-mix", "national", "--profile-mix", "live", "--laps", "1"]
        let plain = try botsuite(arguments)
        let diagnosed = try botsuite(arguments + ["--diagnose"])
        #expect(!plain.stdout.contains("diagnose"))
        #expect(diagnosed.status == plain.status)
        let lines = diagnosed.stdout.split(separator: "\n").map(String.init)
        let gate = try #require(lines.firstIndex { $0.hasPrefix("gate:") })
        let tables = try #require(lines.firstIndex { $0.hasPrefix("diagnose:") })
        #expect(tables > gate)
        for heading in ["late starters, more than 5 s", "late starters, more than 10 s", "penalty episodes", "pre-start calls a boat by rule",
                        "non-finishers by cause"] {
            #expect(lines.contains { $0.hasPrefix(heading) }, "\(heading)")
        }
    }
    #endif
}
