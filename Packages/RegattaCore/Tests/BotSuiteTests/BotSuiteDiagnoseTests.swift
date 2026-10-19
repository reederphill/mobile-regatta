@testable import BotSuite
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
    /// episodes at set ticks. What it makes of them doesn't move when the bots do. The script is a full-circle turn's
    /// (30° in, given up, served), so the race sails fleet-rules@5, not the default (@6 since #490).
    @Test func observerKeepsTheEpisodesAndTheStartsItIsTold() throws {
        let cell = Self.cell()
        let cellSetup = try BotRaceHarness.raceSetup(for: cell)
        let setup = try RaceSetup(raceSeed: cellSetup.raceSeed, seats: cellSetup.seats, laps: cellSetup.laps,
                                  startSequenceTicks: cellSetup.startSequenceTicks, boatClass: cellSetup.boatClass,
                                  venue: cellSetup.venue, conditions: cellSetup.conditions,
                                  rulesConfiguration: RulesConfigFile.bundled(id: "fleet-rules", version: 5).ref)
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

    /// Under fleet-rules@6 (#487) the observer reads a reset as a recross (a crossing back on its tick) or a rounding's
    /// void, never as a 30° turn given up; the turn's first crossing is its start, the crossing that serves it is not a
    /// late turn, and a call made while she is taking a penalty counts as a call on a boat turning.
    @Test func observerReadsCrossingsUnderTackAndGybe() throws {
        let cell = Self.cell()
        let base = try BotRaceHarness.raceSetup(for: cell)
        let setup = try RaceSetup(simulationVersion: base.simulationVersion, raceSeed: base.raceSeed, seats: base.seats,
                                  laps: base.laps, startSequenceTicks: base.startSequenceTicks, boatClass: base.boatClass,
                                  venue: base.venue, conditions: base.conditions,
                                  rulesConfiguration: try RulesConfigFile.bundled(id: "fleet-rules", version: 6).ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        #expect(race.rules.raceFormat.penalty.turn == .tackAndGybe)
        let rate = Race.tickRate
        let script: [Int: [RaceEvent.Kind]] = [
            -30 * rate: [.markTouch(seat: 0, mark: "pin")],
            -28 * rate: [.penaltyStarted(seat: 0), .tacked(seat: 0)],
            -26 * rate: [.penaltyReset(seat: 0), .tacked(seat: 0)],
            -22 * rate: [.penaltyReset(seat: 0)],
            -21 * rate: [.penaltyStarted(seat: 0), .gybed(seat: 0)],
            -15 * rate: [.penaltyServed(seat: 0), .tacked(seat: 0)],
        ]
        var observer = RaceObserver(race: race)
        while race.tick < -10 * rate {
            race.step()
            _ = race.drainEvents()
            observer.record(race, events: (script[race.tick] ?? []).map { RaceEvent(tick: race.tick, kind: $0) })
            try #require(race.boats[0].penaltyTurnsOwed == 0, "seat 0 was called at \(race.tick): script another seed")
        }
        let boats = observer.boats(of: race, tiers: [.national, .club])
        let episode = try #require(boats[0].episodes.first)
        #expect(episode.recrosses == 1 && episode.roundingVoids == 1 && episode.resets.isEmpty)
        #expect(episode.outcome == .served && episode.turnsServed == 1)
        #expect(episode.secondsToStarted == 2 && episode.secondsTurning == 13, "started at the first crossing")
        #expect(boats[0].start.lateTurns == 0, "every crossing was the turn's: the serving one too")
        #expect(episode.callsWhileTurning == 0)
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

    /// The observer only reads: a race on skiff@9 (the default class, turned by hand, falling off the plane), on skiff@8
    /// (the default before it) and on skiff@7 (the tap and the roll, whose bots stay bit-identical,
    /// `BotHandTackTests.skiffSevenBotsAreBitIdentical`) has the same digest watched or not.
    @Test(arguments: [7, 8, 9]) func observingLeavesTheRaceBitIdentical(version: Int) throws {
        let boatClass = try BoatClassFile.bundled(id: "skiff", version: version)
        let plain = try Self.digest(boatClass: boatClass, seed: 471, seconds: 150, observed: false)
        let watched = try Self.digest(boatClass: boatClass, seed: 471, seconds: 150, observed: true)
        #expect(watched.digest == plain.digest)
        #expect(watched.boats.count == 8)
        #expect(watched.boats.contains { $0.start.startSeconds != nil }, "the observer saw the race it watched")
    }

    // MARK: - The report

    /// #462: the planing table, on skiff@9 (`--boat-class`, the class a bad gybe, a run too deep and a lull take off
    /// the plane): every tier that ran has a row, its falls split by every cause, its shares inside 0...1; and the
    /// observer still only reads.
    @Test func planingTableOnSkiffNine() throws {
        let options = try BotSuiteOptions(arguments: ["--boat-class", "skiff@9", "--seeds", "2", "--fleet-size", "5", "--tier-mix",
                                                      "mixed", "--profile-mix", "live", "--diagnose"])
        var matrix = try options.matrix()
        #expect(matrix.boatClass == "skiff@9" && matrix.cells.allSatisfy { $0.boatClass == "skiff@9" })
        matrix.venues = ["dev-venue@3"]
        matrix.conditions = ["classic-oscillating@3"]
        matrix.conditionsByVenue = [:]
        let cell = try #require(matrix.cells.first)
        #expect(try BotRaceHarness.raceSetup(for: cell).boatClass == BoatClassFile.bundled(id: "skiff", version: 9).ref)
        let report = try BotSuite.run(matrix, thresholds: unmissableThresholds(), diagnose: true)
        let summary = try #require(report.diagnose)
        let tiers = [DiagnoseSummary.all] + BotTier.allCases.filter { tier in report.races.flatMap(\.seats).contains { $0.tier == tier } }.map(\.rawValue)
        #expect(summary.planing.map(\.tier) == tiers)
        for row in summary.planing {
            #expect(row.runSeconds > 30 && row.offSeconds <= row.runSeconds && (0...1).contains(row.offShare), "\(row)")
            #expect(Set(row.fallsByCause.keys) == Set(PlaningObservation.Cause.allCases.map(\.rawValue)))
            #expect(abs(row.fallsByCause.values.reduce(0, +) - row.falls) < 1e-9, "\(row)")
            #expect(row.gybes > 0 && (0...1).contains(row.fallsPerGybe) && (0...1).contains(row.backOnShare), "\(row)")
        }
        #expect(summary.lines.contains { $0.hasPrefix("planing off the wind") })
        let nine = try BoatClassFile.bundled(id: "skiff", version: 9)
        #expect(try Self.digest(boatClass: nine, seed: 471, seconds: 150, observed: true).digest
                == Self.digest(boatClass: nine, seed: 471, seconds: 150, observed: false).digest)
        // The default class's matrix and cells name no class, and encode as before.
        let plain = try BotSuiteOptions(arguments: ["--seeds", "1"]).matrix()
        #expect(plain.boatClass == nil && plain.cells.allSatisfy { $0.boatClass == nil })
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("boatClass"))
        #expect(!String(decoding: try JSONEncoder().encode(try #require(plain.cells.first)), as: UTF8.self).contains("boatClass"))
        #expect(throws: BotSuiteError.self) { try BotSuiteOptions(arguments: ["--boat-class", "skiff@99"]).matrix() }
    }

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

        // The JSON's shape: the twelve keys (#542's pre-start scorer the last), each table's rows in their fixed order.
        let json = try #require(JSONSerialization.jsonObject(with: diagnosed.jsonData()) as? [String: Any])
        let diagnose = try #require(json["diagnose"] as? [String: Any])
        #expect(Set(diagnose.keys) == ["races", "starts", "lateStarters", "penaltyEpisodes", "penaltiesOwed", "preStartCalls",
                                       "nonFinishers", "planing", "legs", "roundings", "preGunAvoidance", "preStartScorer"])
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
        // The legs table (#462): the live mix's live bots by their two skills, each kind of leg of a one-lap course;
        // every one that started began the first beat, and those that sailed the last run to its end finished.
        let live = diagnosed.races.filter { $0.cell.profileMix == .live }.flatMap(\.seats)
            .filter { $0.profile == nil && !$0.cautious && $0.handling != nil }
        #expect(!live.isEmpty && !summary.legs.isEmpty)
        #expect(Set(summary.legs.map(\.kind)) == [LegKind.firstBeat.rawValue, LegKind.reach.rawValue, LegKind.lastRun.rawValue])
        for row in summary.legs {
            #expect(BotTier(rawValue: row.skill) != nil && BotTier(rawValue: row.hand) != nil && row.legs > 0, "\(row)")
            #expect((0...1).contains(row.completedShare) && (0...1).contains(row.turnShare) && row.turns >= row.turnShare, "\(row)")
            #expect((row.secondsBehind?.median ?? 0) >= 0 && (row.cleanLost ?? 0) >= 0 && (row.turnLost ?? 0) >= 0, "\(row)")
        }
        func legs(_ kind: LegKind) -> [DiagnoseSummary.LegRow] { summary.legs.filter { $0.kind == kind.rawValue } }
        #expect(legs(.firstBeat).map(\.boats).reduce(0, +) == live.count)
        #expect(legs(.firstBeat).allSatisfy { $0.legs <= $0.boats })
        let sailedIn = legs(.lastRun).map { (Double($0.legs) * $0.completedShare).rounded() }.reduce(0, +)
        #expect(Int(sailedIn) == live.filter(\.finished).count)
        #expect(summary.lines.contains { $0.hasPrefix("legs by tactics skill and handling") })
        // The roundings table (#511): every tier by every mark, and nothing at the gate of a one-lap course.
        let marks = [DiagnoseSummary.all] + RoundingMark.allCases.map(\.rawValue)
        #expect(summary.roundings.map(\.tier) == tiers.flatMap { Array(repeating: $0, count: marks.count) })
        #expect(summary.roundings.map(\.mark) == Array(repeating: marks, count: tiers.count).flatMap { $0 })
        #expect((summary.roundings.first?.roundings ?? 0) > 0)
        for row in summary.roundings where row.mark == RoundingMark.gate.rawValue {
            #expect(row.roundings == 0 && row.extraMean == nil && row.extra == nil && row.overshoots == nil, "\(row)")
        }
        #expect(summary.lines.contains { $0.hasPrefix("roundings by tier and mark") })
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

    // MARK: - Roundings (#511)

    /// A hand-posed track for the scorer, in a steady wind down the course's axis.
    struct Track {
        var wind: Double
        var samples: [RoundingSample] = []

        /// One sample at `point`.
        mutating func jump(_ point: Vec2, leg: Int, stage: Int = 0) {
            samples.append(RoundingSample(tick: samples.count, position: point, windDirection: wind, tws: 6, leg: leg, stage: stage))
        }

        /// `ticks` samples along the straight line from the last one to `point`; the one at `point` is on `end`'s leg
        /// and stage where given.
        mutating func sail(_ point: Vec2, ticks: Int, leg: Int, stage: Int = 0, end: (leg: Int, stage: Int)? = nil) {
            let from = samples[samples.count - 1].position
            for tick in 1...ticks {
                let last = tick == ticks
                jump(from + (point - from) * (Double(tick) / Double(ticks)), leg: last ? end?.leg ?? leg : leg,
                     stage: last ? end?.stage ?? stage : stage)
            }
        }
    }

    /// The scorer against the ideal path on hand-posed tracks, the table on hand-built roundings, and one real race.
    @Test func roundingsTableScoresAgainstTheIdealPath() throws {
        // (a) The scorer. A two-lap course: leg 0 the windward mark, 1 the offset mark, 2 the gate.
        let lapped = BotMatrix(seeds: [5], fleetSizes: [4], tierMixes: [.national], laps: 2, capSecondsAfterGun: 900).cells[0]
        let setup = try BotRaceHarness.raceSetup(for: lapped)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: lapped.seed)))
        let course = race.course, polar = race.boatClass.polar
        guard case .round(CourseLayout.gateIndex) = course.legs[2],
              case .gate(let left, let right) = course.elements[CourseLayout.gateIndex] else {
            Issue.record("leg 2 of a two-lap course is the gate")
            return
        }
        func score(_ track: Track) -> [RoundingObservation] {
            var scorer = RoundingScorer(course: course, polar: polar)
            for sample in track.samples { scorer.record(sample) }
            return scorer.observations()
        }
        let u = course.upwind, r = u.rightPerp
        let windward = course.elements[CourseLayout.windwardIndex].marks[0].position
        let beta = polar.bestUpwind(tws: 6).twa
        // From 70 m below the mark, a tack out and a tack in on the polar's best angle land 3 m to its right: the ideal.
        let entry = windward - u * 70, target = windward + r * 3
        let out = (70 / cos(beta) + 3 / sin(beta)) / 2
        let corner = entry + Vec2.heading(course.axis + beta) * out
        let done = target + u * 24, exit = done - r * 60
        /// A windward rounding: the approach by `approach` from the entry (two samples out of range before it), then
        /// the rounding and the exit straight, or each through a corner.
        func rounding(approach: [Vec2], detour: Bool = false, apex: Bool = false, dogleg: Bool = false, exitTicks: Int? = 450,
                      sailsOn: Bool = true) -> Track {
            var track = Track(wind: course.axis)
            track.jump(windward - u * 85, leg: 0)
            track.jump(windward - u * 80.5, leg: 0)
            track.jump(entry, leg: 0)
            if detour {
                track.sail(entry + r * 20, ticks: 40, leg: 0)
                track.sail(entry, ticks: 40, leg: 0)
            }
            for point in approach { track.sail(point, ticks: 200, leg: 0) }
            track.sail(target, ticks: 200, leg: 0, end: (0, 1))
            guard sailsOn else { return track }
            if apex { track.sail(target + u * 12 - r * 5, ticks: 20, leg: 0, stage: 1) }
            track.sail(done, ticks: 20, leg: 0, stage: 1, end: (1, 0))
            guard let exitTicks else { return track }
            if dogleg { track.sail(done - r * 30 + u * 40, ticks: exitTicks / 2, leg: 1) }
            track.sail(exit, ticks: exitTicks / 2, leg: 1)
            return track
        }
        let ideal = try #require(score(rounding(approach: [corner])).first)
        #expect(score(rounding(approach: [corner])).count == 1, "the offset mark's rounding was never crossed")
        #expect(ideal.mark == .windward && !ideal.wrongSide && ideal.overshootTicks == 0 && !ideal.overshoots)
        #expect(abs(ideal.approachExtra) < 1e-6 && abs(ideal.roundExtra) < 1e-6 && abs(ideal.exitExtra) < 1e-6, "\(ideal)")
        // A 20 m detour out and back, the rounding over a 5-12-13 corner, the exit over a 3-4-5 one.
        let wide = try #require(score(rounding(approach: [corner], detour: true, apex: true, dogleg: true)).first)
        #expect(abs(wide.approachExtra - 40) < 1e-6 && abs(wide.roundExtra - 2) < 1e-6 && abs(wide.exitExtra - 40) < 1e-6, "\(wide)")
        #expect(abs(wide.extraMetres - 82) < 1e-6)
        // Straight at the mark inside the laylines is shorter than the tacking cone.
        let straight = try #require(score(rounding(approach: [])).first)
        #expect(abs(straight.approachExtra - ((target - entry).length - 70 / cos(beta))) < 1e-6 && straight.approachExtra < 0)
        // Above the mark on its left before rounding it is the wrong side; on its right is not.
        #expect(score(rounding(approach: [windward - r * 8 + u * 2])).first?.wrongSide == true)
        #expect(score(rounding(approach: [windward + r * 8 + u * 2])).first?.wrongSide == false)
        // Not sailed to the leg's end: no rounding. An exit the track cuts short counts what it saw.
        #expect(score(rounding(approach: [corner], sailsOn: false)).isEmpty)
        #expect(score(rounding(approach: [corner], exitTicks: nil)).first?.exitExtra == 0)
        let cut = try #require(score(rounding(approach: [corner], dogleg: true, exitTicks: 100)).first)
        #expect(abs(cut.exitExtra - 40) < 1e-6 && abs(cut.approachExtra) < 1e-6)

        // The gate: 3 s below its line before crossing it is an overshoot, a tick less is not.
        let centre = course.targetPosition(for: course.legs[2])
        for held in [89, 90] {
            var track = Track(wind: course.axis)
            track.jump(centre + u * 50, leg: 2)
            for _ in 0..<held { track.jump(centre - u * 2, leg: 2) }
            track.jump(centre + u * 5, leg: 2)
            track.jump(centre, leg: 2, stage: 1)
            track.jump(centre - u * 10, leg: 3)
            let seen = score(track)
            #expect(seen.count == 1 && seen.first?.mark == .gate && seen.first?.wrongSide == false, "\(seen)")
            #expect(seen.first?.overshootTicks == held && seen.first?.overshoots == (held == 90), "\(seen)")
        }
        // A straight run down onto the gate's end is shorter than the gybing cone.
        let end = left.position + (right.position - left.position).normalized * 4
        var run = Track(wind: course.axis)
        run.jump(end + u * 60, leg: 2)
        run.sail(end, ticks: 300, leg: 2, end: (2, 1))
        run.jump(end - u * 5, leg: 3)
        let ran = try #require(score(run).first)
        let cone = 60 / cos(.pi - polar.bestDownwind(tws: 6).twa)
        #expect(abs(ran.approachExtra - (60 - cone)) < 1e-6 && ran.approachExtra < 0 && ran.overshootTicks == 0, "\(ran)")

        // (b) The table. National: four windward roundings (one on the wrong side) and an offset one (on the wrong
        // side too, which the table doesn't say); Club: two at the gate, one an overshoot by a tick.
        func boat(_ tier: BotTier, _ roundings: [RoundingObservation]) -> BoatDiagnosis {
            var boat = BoatDiagnosis(tier: tier, start: StartObservation(startSeconds: 1), finish: FinishObservation(status: .finished))
            boat.roundings = roundings
            return boat
        }
        func rounded(_ mark: RoundingMark, _ extra: Double, wrongSide: Bool = false, ticks: Int = 0) -> RoundingObservation {
            RoundingObservation(mark: mark, approachExtra: extra, roundExtra: 0, exitExtra: 0, wrongSide: wrongSide, overshootTicks: ticks)
        }
        let national = [rounded(.windward, 0), rounded(.windward, 10), rounded(.offset, 49.9, wrongSide: true)]
        let nationalToo = [rounded(.windward, 30, wrongSide: true), rounded(.windward, 29.9)]
        let club = [rounded(.gate, 50, ticks: 90), rounded(.gate, 120, ticks: 89)]
        let summary = DiagnoseSummary([RaceDiagnosis(cell: Self.cell(), boats: [boat(.national, national), boat(.club, club)]),
                                       RaceDiagnosis(cell: Self.cell(seed: 6), boats: [boat(.national, nationalToo)])], seats: [])
        let marks = [DiagnoseSummary.all, "windward", "offset", "gate"]
        #expect(summary.roundings.map(\.tier) == [DiagnoseSummary.all, "club", "national"].flatMap { Array(repeating: $0, count: 4) })
        #expect(summary.roundings.map(\.mark) == marks + marks + marks)
        func row(_ tier: String, _ mark: String) throws -> DiagnoseSummary.RoundingRow {
            try #require(summary.roundings.first { $0.tier == tier && $0.mark == mark })
        }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }
        let every = try row("all", "all")
        #expect(every.roundings == 7 && near(every.extraMean, 289.8 / 7) && every.extra?.median == 30 && every.extra?.p90 == 120)
        #expect(near(every.over30Share, 4.0 / 7) && near(every.over50Share, 2.0 / 7), "30 m and 50 m count")
        #expect(every.wrongSide == nil && every.overshoots == nil)
        let upwind = try row("all", "windward")
        #expect(upwind.roundings == 4 && near(upwind.extraMean, 69.9 / 4) && near(upwind.extra?.median, 19.95) && upwind.extra?.p90 == 30)
        #expect(upwind.over30Share == 0.25 && upwind.over50Share == 0 && upwind.wrongSide == 1 && upwind.overshoots == nil)
        let reach = try row("all", "offset")
        #expect(reach.roundings == 1 && reach.extraMean == 49.9 && reach.over30Share == 1 && reach.over50Share == 0)
        #expect(reach.wrongSide == nil && reach.overshoots == nil)
        let gate = try row("all", "gate")
        #expect(gate.roundings == 2 && gate.extraMean == 85 && gate.extra?.median == 85 && gate.extra?.p90 == 120)
        #expect(gate.over30Share == 1 && gate.over50Share == 1 && gate.wrongSide == nil && gate.overshoots == 1)
        #expect(try every.roundings == marks.dropFirst().map { try row("all", $0).roundings }.reduce(0, +))
        var clubGate = gate
        clubGate.tier = "club"
        #expect(try row("club", "gate") == clubGate)
        var clubAll = clubGate
        clubAll.mark = DiagnoseSummary.all
        clubAll.overshoots = nil
        #expect(try row("club", "all") == clubAll)
        let none = try row("club", "windward")
        #expect(none.roundings == 0 && none.extraMean == nil && none.extra == nil && none.over30Share == 0 && none.over50Share == 0)
        #expect(none.wrongSide == nil && none.overshoots == nil)
        #expect(try row("national", "gate").overshoots == nil && row("national", "gate").roundings == 0)
        var nationalWindward = upwind
        nationalWindward.tier = "national"
        #expect(try row("national", "windward") == nationalWindward)
        let allNational = try row("national", "all")
        #expect(allNational.roundings == 5 && near(allNational.extraMean, 119.8 / 5) && allNational.extra?.median == 29.9)
        #expect(allNational.extra?.p90 == 49.9 && allNational.over30Share == 0.4 && allNational.over50Share == 0)
        // Absent from the JSON where it says nothing.
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        let rows = try #require(json["roundings"] as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["tier", "mark", "roundings", "extraMean", "extra", "over30Share", "over50Share"])
        #expect(Set(rows[5].keys) == ["tier", "mark", "roundings", "over30Share", "over50Share"], "club at the windward mark")
        #expect(rows[1]["wrongSide"] as? Int == 1 && rows[3]["overshoots"] as? Int == 1)
        // The text: the heading, its columns, a line a row.
        let lines = summary.lines
        let heading = try #require(lines.firstIndex { $0.hasPrefix("roundings by tier and mark: extra metres a rounding") })
        #expect(lines.count == heading + 14, "the last table")
        func cells(_ line: String) -> [String] {
            line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        #expect(cells(lines[heading + 1]) == ["tier", "mark", "roundings", "mean m", "median / p90 m", ">= 30 m", ">= 50 m", "wrong side", "overshoot",
                                                "entry to end m", "entry to end s", "median / p90 s", "below the line s", "median / p90 s",
                                                "deepest m", "p90 m", "still below"])
        let unspanned = Array(repeating: "-", count: 8)
        #expect(cells(lines[heading + 2]) == ["all", "all", "7", "41.4", "30.0 / 120.0", "0.571", "0.286", "-", "-"] + unspanned)
        #expect(cells(lines[heading + 3]).suffix(12) == ["0.250", "0.000", "1 (25.0%)", "-"] + unspanned)
        #expect(cells(lines[heading + 5]) == ["all", "gate", "2", "85.0", "85.0 / 120.0", "1.000", "1.000", "-", "1 (50.0%)"] + unspanned)
        #expect(cells(lines[heading + 7]) == ["club", "windward", "0", "-", "-", "0.000", "0.000", "-", "-"] + unspanned)
        // No rounding, no table.
        let bare = DiagnoseSummary([RaceDiagnosis(cell: Self.cell(), boats: [boat(.national, [])])], seats: [])
        #expect(bare.roundings.isEmpty && !bare.lines.contains { $0.hasPrefix("roundings") })

        // (c) A real race of two laps: a finisher rounded the windward and the offset mark twice and the gate once.
        let (result, diagnosis) = try BotRaceHarness.runDiagnosed(lapped)
        #expect(result.seats.contains { $0.finished })
        let order: [RoundingMark] = [.windward, .offset, .gate, .windward, .offset]
        for (seat, boat) in zip(result.seats, diagnosis.boats) {
            if seat.finished { #expect(boat.roundings.map(\.mark) == order, "\(boat.roundings)") }
            #expect(boat.roundings.count <= order.count && boat.roundings.map(\.mark) == Array(order.prefix(boat.roundings.count)))
            for rounding in boat.roundings {
                #expect(rounding.extraMetres.isFinite && (-60...2000).contains(rounding.extraMetres), "\(rounding)")
                #expect(rounding.mark != .gate || !rounding.wrongSide)
                #expect(rounding.mark == .gate || rounding.overshootTicks == 0)
            }
        }
        let table = DiagnoseSummary([diagnosis], seats: result.seats).roundings
        #expect(table.map(\.mark) == marks + marks, "all and national")
        for row in table {
            #expect((row.wrongSide != nil) == (row.mark == "windward" && row.roundings > 0), "\(row)")
            #expect((row.overshoots != nil) == (row.mark == "gate" && row.roundings > 0), "\(row)")
            #expect((row.entryToEndSeconds != nil) == (row.mark == "gate" && row.roundings > 0), "\(row)")
            #expect((row.belowLineSeconds != nil) == (row.mark == "gate" && row.roundings > 0), "\(row)")
        }
        for rounding in diagnosis.boats.flatMap(\.roundings) {
            #expect((rounding.entryToEnd != nil) == (rounding.mark == .gate), "\(rounding)")
            #expect((rounding.belowTheLine != nil) == (rounding.mark == .gate), "\(rounding)")
            if let below = rounding.belowTheLine {
                #expect(below.seconds >= below.secondsOnLeg && below.secondsOnLeg >= 0 && below.deepest >= 0, "\(below)")
            }
            if let span = rounding.entryToEnd {
                #expect(span.metres > 0 && span.seconds > 0 && span.idealMetres > 0 && span.idealSeconds > 0, "\(span)")
            }
        }
    }

    /// The gate from entry to the leg's end (#519): the scorer on hand-posed tracks, and the table's columns.
    @Test func gateRoundingIsScoredFromEntryToTheLegsEnd() throws {
        let lapped = BotMatrix(seeds: [5], fleetSizes: [4], tierMixes: [.national], laps: 2, capSecondsAfterGun: 900).cells[0]
        let setup = try BotRaceHarness.raceSetup(for: lapped)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: lapped.seed)))
        let course = race.course, polar = race.boatClass.polar
        guard case .round(CourseLayout.gateIndex) = course.legs[2],
              case .gate(let left, let right) = course.elements[CourseLayout.gateIndex] else {
            Issue.record("leg 2 of a two-lap course is the gate")
            return
        }
        func score(_ track: Track) throws -> RoundingObservation {
            var scorer = RoundingScorer(course: course, polar: polar)
            for sample in track.samples { scorer.record(sample) }
            #expect(scorer.observations().count == 1)
            return try #require(scorer.observations().first)
        }
        let u = course.upwind, r = u.rightPerp
        let along = (right.position - left.position).normalized
        let centre = course.targetPosition(for: course.legs[2])
        let best = polar.bestDownwind(tws: 6)
        let half = Double.pi - best.twa
        let rate = Double(Race.tickRate)
        /// The ticks a boat at `speed` takes over `metres`, to the nearest.
        func ticks(_ metres: Double, at speed: Double) -> Int { Int((metres / speed * rate).rounded()) }
        // Either mark's rounding point 4 m inside it, and the leg's end 3 m outside it and 6 m below.
        let points = [left.position + along * 4, right.position - along * 4]
        let ends = [left.position - along * 3 - u * 6, right.position + along * 3 - u * 6]
        let traverse = (points[0] - centre).length
        // Round the mark: the straight line from the point to the leg's end, at the polar's speed for its angle.
        let turnMetres = (ends[0] - points[0]).length
        func turnSeconds(_ end: Int) -> Double {
            let line = ends[end] - points[end]
            return line.length / polar.speed(twa: abs(wrapAngle(line.bearing - course.axis)), tws: 6)
        }
        let turnTicks = ticks(turnMetres, at: turnMetres / turnSeconds(0))
        // One gybe out and one back on the polar's best angle, 60 m down the wind: the ideal approach to the point below.
        let board = 30 / cos(half)
        let boardTicks = ticks(board, at: best.speed)
        /// From 60 m above `above`: two samples out of range, the two gybes down to it, `along` the gate's line from
        /// there where given, then round the mark at `end`. She crosses the line at `above`.
        func rounding(above: Vec2, traverseTicks: Int? = nil, end: Int = 0) -> Track {
            var track = Track(wind: course.axis)
            track.jump(above + u * 90, leg: 2)
            track.jump(above + u * 85, leg: 2)
            track.jump(above + u * 60, leg: 2)
            track.sail(above + u * 30 + r * (30 * tan(half)), ticks: boardTicks, leg: 2)
            track.sail(above, ticks: boardTicks, leg: 2, end: (2, 1))
            if let traverseTicks { track.sail(points[end], ticks: traverseTicks, leg: 2, stage: 1) }
            track.sail(ends[end], ticks: turnTicks, leg: 2, stage: 1, end: (3, 0))
            return track
        }
        /// The ideal approach from 60 m above `above` to the left mark's point: inside the gybing cone, by hand.
        func cone(from above: Vec2) throws -> Double {
            let line = points[0] - (above + u * 60)
            try #require(abs(line.dot(r)) <= -line.dot(u) * tan(half), "the left point is inside her laylines")
            return -line.dot(u) / cos(half)
        }

        // (1) The ideal approach to the left mark's point, and round it: nothing over, to the tick.
        let ideal = try score(rounding(above: points[0]))
        let idealSpan = try #require(ideal.entryToEnd)
        #expect(ideal.mark == .gate && abs(ideal.approachExtra) < 1e-6 && abs(ideal.roundExtra) < 1e-6, "\(ideal)")
        #expect(abs(idealSpan.idealMetres - (60 / cos(half) + turnMetres)) < 1e-6, "\(idealSpan)")
        #expect(abs(idealSpan.idealSeconds - (60 / cos(half) / best.speed + turnSeconds(0))) < 1e-6, "\(idealSpan)")
        #expect(abs(idealSpan.metres - idealSpan.idealMetres) < 1e-6 && abs(idealSpan.extraMetres) < 1e-6, "\(idealSpan)")
        #expect(idealSpan.seconds == Double(2 * boardTicks + turnTicks) / rate)
        #expect(abs(idealSpan.extraSeconds) < 0.05, "half a tick a part: \(idealSpan)")

        // (2) The defect. The same two gybes down to the gate's centre, 8 s along the line to the left mark's point,
        // and round it. The rounding part is against the chord from the centre to the leg's end: a metre or two.
        // Entry to end she is the traverse over, and its 8 s.
        let crossed = try score(rounding(above: centre, traverseTicks: 240))
        let span = try #require(crossed.entryToEnd)
        let chord = (ends[0] - centre).length
        #expect(abs(crossed.roundExtra - (traverse + turnMetres - chord)) < 1e-6 && crossed.roundExtra < 0.1 * traverse, "\(crossed)")
        let approach = try cone(from: centre)
        #expect(abs(crossed.approachExtra - (60 / cos(half) - approach)) < 1e-6 && abs(crossed.approachExtra) < 0.5, "\(crossed)")
        #expect(abs(span.extraMetres - (60 / cos(half) + traverse - approach)) < 1e-6, "\(span)")
        #expect(abs(span.extraMetres - traverse) < 0.5 && traverse > 10, "the traverse, \(traverse) m: \(span)")
        #expect(abs(span.extraSeconds - (Double(2 * boardTicks + 240 + turnTicks) / rate - approach / best.speed - turnSeconds(0))) < 1e-6)
        #expect(abs(span.extraSeconds - 8) < 0.1, "\(span)")
        #expect(crossed.approachExtra + crossed.roundExtra < 0.2 * traverse, "the approach and the rounding part miss it")

        // From above the centre the left point is the better one (as soon as the right, and first). Rounding the right
        // mark instead is scored against the left one's leg end, mirrored: the same extras as (2).
        let other = try score(rounding(above: centre, traverseTicks: 240, end: 1))
        let mirrored = try #require(other.entryToEnd)
        #expect(abs(mirrored.extraMetres - span.extraMetres) < 1e-6, "\(mirrored)")
        let mirroredEnd = left.position - along * 3 - u * 6 + along * (2 * u.dot(along) * 6)
        let mirroredLine = mirroredEnd - points[0]
        let mirroredSeconds = mirroredLine.length / polar.speed(twa: abs(wrapAngle(mirroredLine.bearing - course.axis)), tws: 6)
        #expect(abs(mirrored.idealMetres - (approach + mirroredLine.length)) < 1e-6, "\(mirrored)")
        #expect(abs(mirrored.idealSeconds - (approach / best.speed + mirroredSeconds)) < 1e-6, "\(mirrored)")

        // (3) The table. Club: two gate roundings, 10 m and 4 s over and 30 m and 11 s over, and a windward one;
        // National: one at the gate, 2 m and 1 s under.
        func boat(_ tier: BotTier, _ roundings: [RoundingObservation]) -> BoatDiagnosis {
            var boat = BoatDiagnosis(tier: tier, start: StartObservation(startSeconds: 1), finish: FinishObservation(status: .finished))
            boat.roundings = roundings
            return boat
        }
        func gate(_ metres: Double, _ seconds: Double) -> RoundingObservation {
            RoundingObservation(mark: .gate, approachExtra: 1, roundExtra: 2, exitExtra: 3, entryToEnd:
                RoundingObservation.EntryToEnd(metres: 100 + metres, seconds: 20 + seconds, idealMetres: 100, idealSeconds: 20))
        }
        let upwind = RoundingObservation(mark: .windward, approachExtra: 5, roundExtra: 0, exitExtra: 0)
        let summary = DiagnoseSummary([RaceDiagnosis(cell: Self.cell(), boats: [boat(.club, [upwind, gate(10, 4), gate(30, 11)]),
                                                                                boat(.national, [gate(-2, -1)])])], seats: [])
        func row(_ tier: String, _ mark: String) throws -> DiagnoseSummary.RoundingRow {
            try #require(summary.roundings.first { $0.tier == tier && $0.mark == mark })
        }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }
        let every = try row("all", "gate")
        #expect(every.roundings == 3 && near(every.entryToEndExtraMetres, 38.0 / 3) && near(every.entryToEndExtraSeconds, 14.0 / 3))
        #expect(near(every.entryToEndSeconds?.median, 4) && near(every.entryToEndSeconds?.p90, 11))
        #expect(near(every.extraMean, 6) && every.extra?.median == 6, "the three parts as before")
        let club = try row("club", "gate")
        #expect(near(club.entryToEndExtraMetres, 20) && near(club.entryToEndExtraSeconds, 7.5))
        #expect(near(club.entryToEndSeconds?.median, 7.5) && near(club.entryToEndSeconds?.p90, 11))
        let national = try row("national", "gate")
        #expect(near(national.entryToEndExtraMetres, -2) && near(national.entryToEndExtraSeconds, -1))
        for row in summary.roundings where row.mark != "gate" {
            #expect(row.entryToEndExtraMetres == nil && row.entryToEndExtraSeconds == nil && row.entryToEndSeconds == nil, "\(row)")
        }
        // The JSON: the keys on the gate rows that have a rounding, and on no other.
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        let rows = try #require(json["roundings"] as? [[String: Any]])
        let keys: Set = ["entryToEndExtraMetres", "entryToEndExtraSeconds", "entryToEndSeconds"]
        #expect(rows.count == 12)
        for row in rows {
            #expect(Set(row.keys).intersection(keys) == (row["mark"] as? String == "gate" ? keys : []), "\(row)")
        }
        #expect(rows[3]["entryToEndExtraSeconds"] as? Double == 14.0 / 3)
        #expect((rows[3]["entryToEndSeconds"] as? [String: Double]) == ["median": 4, "p90": 11])
        // The text: three more columns (before the five below the line's), a dash off the gate.
        let lines = summary.lines
        let heading = try #require(lines.firstIndex { $0.hasPrefix("roundings by tier and mark: extra metres a rounding") })
        #expect(lines[heading].contains("entry to the leg's end") && lines[heading].contains("centre crossing"))
        func cells(_ line: String) -> [String] {
            line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        #expect(cells(lines[heading + 1]).dropLast(5).suffix(3) == ["entry to end m", "entry to end s", "median / p90 s"])
        #expect(cells(lines[heading + 2]).prefix(3) == ["all", "all", "4"] && cells(lines[heading + 2]).suffix(8) == Array(repeating: "-", count: 8))
        #expect(cells(lines[heading + 5]) == ["all", "gate", "3", "6.0", "6.0 / 6.0", "0.000", "0.000", "-", "0 (0.0%)",
                                              "12.7", "4.7", "4.0 / 11.0", "-", "-", "-", "-", "-"])
        #expect(cells(lines[heading + 9]).dropLast(5).suffix(3) == ["20.0", "7.5", "7.5 / 11.0"], "club at the gate")
        #expect(cells(lines[heading + 13]).dropLast(5).suffix(3) == ["-2.0", "-1.0", "-1.0 / -1.0"], "national at the gate")
        // A gate rounding without the span (none is scored so) leaves the row's columns empty.
        let bare = DiagnoseSummary([RaceDiagnosis(cell: Self.cell(), boats: [boat(.club, [upwind])])], seats: [])
        #expect(bare.roundings.allSatisfy { $0.entryToEndSeconds == nil && $0.entryToEndExtraMetres == nil })
    }

    /// The gate's time and depth below its line (#519): the scorer on hand-posed tracks, and the table's columns.
    @Test func gateRowsCountSecondsAndDepthBelowTheLine() throws {
        let lapped = BotMatrix(seeds: [5], fleetSizes: [4], tierMixes: [.national], laps: 2, capSecondsAfterGun: 900).cells[0]
        let setup = try BotRaceHarness.raceSetup(for: lapped)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: lapped.seed)))
        let course = race.course, polar = race.boatClass.polar
        guard case .round(CourseLayout.gateIndex) = course.legs[2],
              case .gate(let left, let right) = course.elements[CourseLayout.gateIndex] else {
            Issue.record("leg 2 of a two-lap course is the gate")
            return
        }
        func score(_ track: Track) throws -> RoundingObservation {
            var scorer = RoundingScorer(course: course, polar: polar)
            for sample in track.samples { scorer.record(sample) }
            #expect(scorer.observations().count == 1)
            return try #require(scorer.observations().first)
        }
        let along = (right.position - left.position).normalized
        var n = along.rightPerp
        if n.dot(course.upwind) < 0 { n = -n }
        let rate = Double(Race.tickRate)
        #expect(Race.tickRate == 30 && RoundingObservation.belowLine == 1 && RoundingObservation.exitSeconds == 15)
        /// `metres` along the gate's line from the left mark (under 0 outside it) and `depth` below the line's level.
        func at(_ metres: Double, _ depth: Double) -> Vec2 { left.position + along * metres - n * depth }
        /// On the gate's leg from 60 m above the line to 2 m above it, `metres` along it: 101 ticks, none below.
        func approach(_ metres: Double) -> Track {
            var track = Track(wind: course.axis)
            track.jump(at(4, -60), leg: 2)
            track.sail(at(metres, -2), ticks: 100, leg: 2)
            return track
        }
        /// From 2 m above the line 4 m inside the left mark: across it in one tick to 4 m below (the race's crossing),
        /// `turn` ticks down to the leg's end `deep` below and 3 m outside the mark, then `climb` ticks on the next
        /// leg up to 4 m below, 8 m outside, and one more to 2 m above (where `climb` is given).
        func round(_ track: inout Track, turn: Int, deep: Double, climb: Int?) {
            track.sail(at(4, 4), ticks: 1, leg: 2, end: (2, 1))
            track.sail(at(-3, deep), ticks: turn, leg: 2, stage: 1, end: (3, 0))
            guard let climb else { return }
            track.sail(at(-8, 4), ticks: climb - 1, leg: 3)
            track.sail(at(-8, -2), ticks: 1, leg: 3)
            track.sail(at(-8, -50), ticks: 500, leg: 3)
        }

        // (1) Clean. Below on her crossing tick, the 60 of the turn (2 s to the leg's end) and 59 of the climb: 120
        // ticks, 4 s, 6 m deep at the leg's end.
        var track = approach(4)
        round(&track, turn: 60, deep: 6, climb: 60)
        let clean = try score(track)
        let cleanBelow = try #require(clean.belowTheLine)
        #expect(clean.mark == .gate && clean.entryToEnd != nil && clean.overshootTicks == 0, "\(clean)")
        #expect(cleanBelow.seconds == 120 / rate && cleanBelow.seconds == 4 && cleanBelow.secondsOnLeg == 2, "\(cleanBelow)")
        #expect(abs(cleanBelow.deepest - 6) < 1e-9 && !cleanBelow.stillBelow, "\(cleanBelow)")

        // (2) Wide and deep after the same crossing: 150 ticks down to 20 m below, 210 back up. 1 + 150 + 209 ticks, 12 s.
        track = approach(4)
        round(&track, turn: 150, deep: 20, climb: 210)
        let wide = try #require(try score(track).belowTheLine)
        #expect(wide.seconds == 12 && wide.secondsOnLeg == 5 && abs(wide.deepest - 20) < 1e-9 && !wide.stillBelow, "\(wide)")

        // (3) An overshoot. Outside the left mark she goes under the line's level before the race has her across it:
        // 1 tick to 5 m below, 60 down to 8 m, 59 back up to 3 m, 1 to 2 m above; 90 ticks above the line back to the
        // gate, then (1)'s rounding. The clock runs from her first tick below: 120 + 91 + 120 ticks.
        track = approach(-10)
        let first = track.samples.count
        track.sail(at(-10, 5), ticks: 1, leg: 2)
        track.sail(at(-12, 8), ticks: 60, leg: 2)
        track.sail(at(-10, 3), ticks: 59, leg: 2)
        track.sail(at(-10, -2), ticks: 1, leg: 2)
        track.sail(at(4, -2), ticks: 90, leg: 2)
        round(&track, turn: 60, deep: 6, climb: 60)
        let overshot = try score(track)
        let circled = try #require(overshot.belowTheLine)
        #expect(overshot.overshootTicks == 120 && overshot.overshoots, "\(overshot)")
        #expect(circled.seconds == 331 / rate && circled.secondsOnLeg == 271 / rate, "\(circled)")
        #expect(abs(circled.deepest - 8) < 1e-9 && !circled.stillBelow, "\(circled)")
        #expect(track.samples[first].tick == first && circled.seconds > cleanBelow.seconds + 7)

        // (4) Still below when the exit's window closes. (1)'s crossing and turn, then 600 ticks on down to 30 m below:
        // the window is the 450 ticks after the leg's end, so 1 + 60 + 450 ticks and 6 + 24 x 450 / 600 = 24 m deep.
        track = approach(4)
        round(&track, turn: 60, deep: 6, climb: nil)
        track.sail(at(-3, 30), ticks: 600, leg: 3)
        let held = try #require(try score(track).belowTheLine)
        #expect(held.seconds == 511 / rate && held.secondsOnLeg == 2 && held.stillBelow, "\(held)")
        #expect(abs(held.deepest - 24) < 1e-9, "\(held)")
        // The same, the race over 100 ticks after the leg's end: what she was seen below, and still below.
        track.samples.removeLast(500)
        let cut = try #require(try score(track).belowTheLine)
        #expect(cut.seconds == 161 / rate && abs(cut.deepest - 10) < 1e-9 && cut.stillBelow, "\(cut)")

        // (5) The table. Club: two gate roundings, 4 s and 6 m, and 12 s and 20 m, still below; and a windward one.
        // National: one at the gate, 5 s and 7 m.
        func boat(_ tier: BotTier, _ roundings: [RoundingObservation]) -> BoatDiagnosis {
            var boat = BoatDiagnosis(tier: tier, start: StartObservation(startSeconds: 1), finish: FinishObservation(status: .finished))
            boat.roundings = roundings
            return boat
        }
        func gate(_ seconds: Double, _ deepest: Double, still: Bool = false) -> RoundingObservation {
            RoundingObservation(mark: .gate, approachExtra: 1, roundExtra: 2, exitExtra: 3, belowTheLine:
                RoundingObservation.BelowTheLine(seconds: seconds, deepest: deepest, stillBelow: still))
        }
        let upwind = RoundingObservation(mark: .windward, approachExtra: 5, roundExtra: 0, exitExtra: 0)
        let summary = DiagnoseSummary([RaceDiagnosis(cell: Self.cell(), boats: [boat(.club, [upwind, gate(4, 6), gate(12, 20, still: true)]),
                                                                                boat(.national, [gate(5, 7)])])], seats: [])
        func row(_ tier: String, _ mark: String) throws -> DiagnoseSummary.RoundingRow {
            try #require(summary.roundings.first { $0.tier == tier && $0.mark == mark })
        }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }
        let every = try row("all", "gate")
        #expect(every.roundings == 3 && near(every.belowLineSecondsMean, 7) && near(every.deepestMean, 11) && every.stillBelow == 1)
        #expect(near(every.belowLineSeconds?.median, 5) && near(every.belowLineSeconds?.p90, 12))
        #expect(near(every.deepest?.median, 7) && near(every.deepest?.p90, 20))
        #expect(near(every.extraMean, 6) && every.overshoots == 0 && every.entryToEndSeconds == nil, "the other columns as before")
        let club = try row("club", "gate")
        #expect(near(club.belowLineSecondsMean, 8) && near(club.belowLineSeconds?.median, 8) && near(club.belowLineSeconds?.p90, 12))
        #expect(near(club.deepestMean, 13) && near(club.deepest?.p90, 20) && club.stillBelow == 1)
        let national = try row("national", "gate")
        #expect(near(national.belowLineSecondsMean, 5) && near(national.deepestMean, 7) && national.stillBelow == 0)
        // The JSON: the keys on the gate rows that have a rounding, and on no other.
        let keys: Set = ["belowLineSecondsMean", "belowLineSeconds", "deepestMean", "deepest", "stillBelow"]
        for row in summary.roundings where row.mark != "gate" {
            #expect(row.belowLineSecondsMean == nil && row.belowLineSeconds == nil && row.deepestMean == nil && row.deepest == nil
                && row.stillBelow == nil, "\(row)")
        }
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        let rows = try #require(json["roundings"] as? [[String: Any]])
        #expect(rows.count == 12)
        for row in rows {
            #expect(Set(row.keys).intersection(keys) == (row["mark"] as? String == "gate" ? keys : []), "\(row)")
        }
        #expect(rows[3]["belowLineSecondsMean"] as? Double == 7 && rows[3]["stillBelow"] as? Int == 1)
        #expect((rows[3]["deepest"] as? [String: Double]) == ["median": 7, "p90": 20])
        // The text: five more columns, a dash off the gate.
        let lines = summary.lines
        let heading = try #require(lines.firstIndex { $0.hasPrefix("roundings by tier and mark: extra metres a rounding") })
        #expect(lines[heading].contains("below the line") && lines[heading].contains("no ideal path")
            && lines[heading].contains("blind to the approach"))
        func cells(_ line: String) -> [String] {
            line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        #expect(cells(lines[heading + 1]).suffix(5) == ["below the line s", "median / p90 s", "deepest m", "p90 m", "still below"])
        #expect(cells(lines[heading + 2]).suffix(5) == ["-", "-", "-", "-", "-"], "all marks")
        #expect(cells(lines[heading + 5]) == ["all", "gate", "3", "6.0", "6.0 / 6.0", "0.000", "0.000", "-", "0 (0.0%)", "-", "-", "-",
                                              "7.0", "5.0 / 12.0", "11.0", "20.0", "1 (33.3%)"])
        #expect(cells(lines[heading + 9]).suffix(5) == ["8.0", "8.0 / 12.0", "13.0", "20.0", "1 (50.0%)"], "club at the gate")
        #expect(cells(lines[heading + 13]).suffix(5) == ["5.0", "5.0 / 5.0", "7.0", "7.0", "0 (0.0%)"], "national at the gate")
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
                        "non-finishers by cause", "roundings by tier and mark"] {
            #expect(lines.contains { $0.hasPrefix(heading) }, "\(heading)")
        }
    }
    #endif
}
