import Foundation
import Testing
@testable import RegattaCore

/// Online rules authority (#96, ADR 0005): a prediction judges nothing and takes the server's word, its events
/// (`Race.apply(authoritative:)`) and its umpire's relations (`Race.setUmpireRelations`).
@Suite struct OnlineRulesAuthorityTests {
    /// A prediction of `authoritative`: the same setup and files, given every key the authoritative race will use.
    static func prediction(of authoritative: Race, through finalTick: Int, windSeed: WindSeed) throws -> Race {
        var generator = try WindKeyGenerator(windSeed: windSeed, setup: authoritative.windSetup,
                                             windows: authoritative.wind.windows)
        let keys = generator.keys(through: authoritative.wind.windows.window(containing: finalTick) + 2)
        return try Race(setup: authoritative.setup, files: RaceFiles(resolving: authoritative.setup),
                        mode: .prediction(revealedWindKeys: keys))
    }

    /// Sails `log` (as `Replayer` does) in an authoritative race and a prediction of it side by side, to
    /// `finalTick`. After each tick `each` sees both races and the tick's events of each; with `applying`, the
    /// prediction applies the authoritative race's events first, as a client applies the server's.
    @discardableResult
    static func sail(_ log: RaceLog, to finalTick: Int? = nil, applying: Bool,
                     each: (Race, Race, [RaceEvent], [RaceEvent]) -> Void = { _, _, _, _ in }) throws -> (Race, Race) {
        let setup = log.header.setup
        let authoritative = try Race(setup: setup, files: RaceFiles(resolving: setup),
                                     mode: .authoritative(windSeed: log.header.windSeed))
        let end = finalTick ?? log.finalTick
        let prediction = try prediction(of: authoritative, through: end, windSeed: log.header.windSeed)
        var nextInput = 0
        while authoritative.tick < end {
            let next = authoritative.tick + 1
            while nextInput < log.inputs.count, log.inputs[nextInput].tick <= next {
                let record = log.inputs[nextInput]
                for race in [authoritative, prediction] {
                    switch record.kind {
                    case .held(let input): race.apply(input, seat: record.seat, atTick: next)
                    case .tap(let tap): race.tap(tap, seat: record.seat, atTick: next)
                    }
                }
                nextInput += 1
            }
            authoritative.step()
            try prediction.tryStep()
            let calls = authoritative.drainEvents()
            let predicted = prediction.drainEvents()
            if applying { for event in calls { prediction.apply(authoritative: event) } }
            each(authoritative, prediction, calls, predicted)
        }
        return (authoritative, prediction)
    }

    /// The golden 16-seat log: four humans and twelve scripted boats, with contacts, calls and mark touches.
    static func log() throws -> RaceLog { try ScriptedLog.fixture() }

    /// Acceptance (#96): a prediction sailing a log that contains fouls emits no rule event, owes no turn
    /// and disqualifies nobody, while the authoritative race calls them.
    @Test func predictionOverALogWithFoulsEmitsNoRuleEvents() throws {
        var calls = 0, ruleEventsPredicted = 0, turnsPredicted = 0, dsqPredicted = 0
        try Self.sail(Self.log(), applying: false) { _, prediction, authoritative, predicted in
            calls += authoritative.filter { if case .ruleCall = $0.kind { true } else { false } }.count
            ruleEventsPredicted += predicted.filter(\.kind.isRuleEvent).count
            turnsPredicted += prediction.boats.map(\.penaltyTurnsOwed).reduce(0, +)
            dsqPredicted += prediction.boats.filter { $0.status == .dsq }.count
        }
        #expect(calls > 0, "the log has fouls")
        #expect(ruleEventsPredicted == 0)
        #expect(turnsPredicted == 0)
        #expect(dsqPredicted == 0)
    }

    /// A prediction judges no OCS either (#96): a boat over the line at the gun is OCS in the authoritative race,
    /// and in the prediction only once the server's `ocsNotice` comes. Starting stays the prediction's own.
    @Test func aPredictionJudgesNoOCS() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(96), seats: [.human, .human], startSequenceTicks: 60)
        let authoritative = Race(setup: setup, windSeed: WindSeed(96))
        let prediction = try Self.prediction(of: authoritative, through: 120, windSeed: WindSeed(96))
        while authoritative.tick < -10 {
            authoritative.step()
            try prediction.tryStep()
        }
        var snapshot = authoritative.exportSnapshot()
        snapshot.seats[0].boat.position = authoritative.course.startLine.centre + authoritative.course.upwind * 30
        try authoritative.importSnapshot(snapshot)
        try prediction.importSnapshot(snapshot)
        // The import keeps only the snapshot's keys: reveal the rest again.
        var generator = try WindKeyGenerator(windSeed: WindSeed(96), setup: authoritative.windSetup,
                                             windows: authoritative.wind.windows)
        for key in generator.keys(through: 40) where key.window >= snapshot.windKeys.endWindow {
            prediction.addRevealedWindKey(key)
        }
        var calls: [RaceEvent] = [], predicted: [RaceEvent] = []
        while authoritative.tick < 1 {
            authoritative.step()
            try prediction.tryStep()
            calls += authoritative.drainEvents()
            predicted += prediction.drainEvents()
        }
        #expect(calls.map(\.kind).contains(.ocsNotice(recipient: 0)))
        #expect(authoritative.boats[0].status == .ocs)
        #expect(!predicted.map(\.kind).contains(.ocsNotice(recipient: 0)))
        #expect(prediction.boats[0].status == .prestart)
        for event in calls { prediction.apply(authoritative: event) }
        #expect(prediction.boats[0].status == .ocs)
        #expect(prediction.boats[1].status == authoritative.boats[1].status)
    }

    /// The penalty state of each seat that differs between `authoritative` and `prediction`, as text: turns owed,
    /// the current turn's clock, the queue, the status and ghosting, and the turn's progress (a served turn's
    /// overshoot carries into the next in both).
    static func penaltyMismatches(_ authoritative: Race, _ prediction: Race) -> [String] {
        zip(authoritative.boats, prediction.boats).enumerated().compactMap { seat, pair in
            let (a, p) = pair
            guard a.penaltyTurnsOwed != p.penaltyTurnsOwed || a.penaltyClockTick != p.penaltyClockTick
                || a.queuedPenaltyCallTicks != p.queuedPenaltyCallTicks || a.status != p.status
                || abs(a.penaltyProgress - p.penaltyProgress) > 1e-9
                || authoritative.isGhost(seat: seat) != prediction.isGhost(seat: seat) else { return nil }
            return "tick \(authoritative.tick) seat \(seat): owed \(a.penaltyTurnsOwed)/\(p.penaltyTurnsOwed) "
                + "clock \(String(describing: a.penaltyClockTick))/\(String(describing: p.penaltyClockTick)) "
                + "status \(a.status)/\(p.status) progress \(a.penaltyProgress)/\(p.penaltyProgress)"
        }
    }

    /// Acceptance (#96): applying the authoritative event stream to a prediction yields the authoritative race's
    /// penalty state at every tick (`penaltyMismatches`), over the golden log's calls and mark touches, and over a
    /// port-starboard collision whose boats then turn: turns owed, started, served, given up or missed (DSQ).
    @Test func applyingTheAuthoritativeEventsYieldsTheAuthoritativePenaltyState() throws {
        var mismatches: [String] = []
        var owedTicks = 0
        try Self.sail(Self.log(), applying: true) { authoritative, prediction, _, _ in
            owedTicks += authoritative.boats.filter { $0.penaltyTurnsOwed > 0 }.count
            mismatches += Self.penaltyMismatches(authoritative, prediction)
        }
        #expect(owedTicks > 0, "the log owes turns")
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(3))")

        // Port meets starboard bow to bow below the line (`RaceAssemblyTests.predictionModeNeverEmitsRuleEvents`),
        // then both turn hard one way: the offender serves her turn; later the other way, giving a turn up.
        for rudder: Int8 in [127, -127] {
            let setup = try RaceAssemblyTests.setup(seats: [.human, .human])
            let authoritative = Race(setup: setup, windSeed: RaceAssemblyTests.windSeed)
            let prediction = try Self.prediction(of: authoritative, through: 1200, windSeed: RaceAssemblyTests.windSeed)
            var snapshot = authoritative.exportSnapshot()
            let centre = authoritative.course.startLine.centre - authoritative.course.upwind * 60
            let wind = authoritative.windSetup.meanDirection
            snapshot.seats[0].boat.position = centre
            snapshot.seats[0].boat.heading = wind + deg2rad(50)
            snapshot.seats[0].boat.boomSide = .leeward(ofRelativeWind: -deg2rad(50))
            snapshot.seats[1].boat.position = centre + Vec2.heading(wind + deg2rad(50)) * 3
            snapshot.seats[1].boat.heading = wind - deg2rad(50)
            snapshot.seats[1].boat.boomSide = .leeward(ofRelativeWind: deg2rad(50))
            try authoritative.importSnapshot(snapshot)
            try prediction.importSnapshot(snapshot)
            // The import keeps only the snapshot's keys: reveal the rest again.
            var generator = try WindKeyGenerator(windSeed: RaceAssemblyTests.windSeed, setup: authoritative.windSetup,
                                                 windows: authoritative.wind.windows)
            for key in generator.keys(through: 40) where key.window >= snapshot.windKeys.endWindow {
                prediction.addRevealedWindKey(key)
            }
            var calls: [RaceEvent] = []
            for step in 0..<900 {
                let input: BoatInput? = switch step {
                case 20: BoatInput(rudder: rudder)
                case 200: BoatInput(rudder: -rudder)
                case 230: BoatInput(rudder: rudder)
                default: nil
                }
                if let input {
                    for race in [authoritative, prediction] {
                        for seat in 0..<2 { race.apply(input, seat: seat, atTick: race.tick + 1) }
                    }
                }
                authoritative.step()
                try prediction.tryStep()
                let events = authoritative.drainEvents()
                _ = prediction.drainEvents()
                for event in events { prediction.apply(authoritative: event) }
                calls += events
                mismatches += Self.penaltyMismatches(authoritative, prediction)
            }
            #expect(calls.contains { if case .ruleCall = $0.kind { true } else { false } })
            #expect(calls.contains { if case .penaltyServed = $0.kind { true } else { false } }
                    || calls.contains { if case .disqualified = $0.kind { true } else { false } })
            #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(3))")
        }
    }

    /// Acceptance (#96): the split leaves the authoritative race alone. Sailed beside a prediction that takes its
    /// events, its digest is the replay's, which the golden table pins on the replay platform (`GoldenTests`).
    @Test func authoritativeReplayDigestIsUnchangedByTheSplit() throws {
        let log = try Self.log()
        let (authoritative, _) = try Self.sail(log, applying: true)
        #expect(authoritative.digest() == (try GoldenTests.goldenDigest()))
        if isReplayPlatform, let row = try GoldenTests.goldenTable()[simulationVersion] {
            #expect(row == hex64(authoritative.digest()))
        }
    }

    /// A prediction never serves a penalty turn itself: its progress runs on past a full turn (the arc,
    /// `OwedPenalty.progress`, waits just short of one) until the server's `penaltyServed` comes, which carries the
    /// turning past the full turn into the next owed turn as the server did, however late it comes.
    @Test func aPredictionNeverServesAPenaltyTurnItself() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(96), seats: [.human, .bot], startSequenceTicks: 60)
        let authoritative = Race(setup: setup, windSeed: WindSeed(96))
        let prediction = try Self.prediction(of: authoritative, through: 900, windSeed: WindSeed(96))
        for race in [authoritative, prediction] {
            race.penalize(0)
            race.penalize(0)
            race.apply(BoatInput(rudder: Int8(127)), seat: 0, atTick: race.tick + 1)
        }
        // Each served turn reaches the prediction 6 ticks late, as over the network.
        var inFlight: [RaceEvent] = []
        var served = 0, heldAtFullTurn = 0
        for _ in 0..<800 {
            authoritative.step()
            try prediction.tryStep()
            let events = authoritative.drainEvents().filter { $0.kind == .penaltyServed(seat: 0) }
            served += events.count
            inFlight += events
            #expect(!prediction.drainEvents().contains { $0.kind == .penaltyServed(seat: 0) })
            if let owed = prediction.owedPenalty(ofSeat: 0) {
                #expect(owed.progress <= Race.heldPenaltyProgress)
                if abs(prediction.boats[0].penaltyProgress) >= 2 * .pi { heldAtFullTurn += 1 }
            }
            for event in inFlight where event.tick + 6 == prediction.tick {
                prediction.apply(authoritative: event)
                #expect(abs(prediction.boats[0].penaltyProgress - authoritative.boats[0].penaltyProgress) < 1e-9)
            }
            inFlight.removeAll { $0.tick + 6 <= prediction.tick }
        }
        #expect(served == 2)
        #expect(heldAtFullTurn > 0, "the arc waited for the server's word")
        #expect(prediction.boats[0].penaltyTurnsOwed == 0 && prediction.boats[0].penaltyClockTick == nil)
        #expect(prediction.boats[0].penaltyProgress == 0)
    }

    /// A prediction's right-of-way relations and rule 17 restrictions are the server umpire's, never its own
    /// world's: none until they come, then exactly them for the seat they are for (#96, ADR 0005).
    @Test func aPredictionsRelationsAreTheServerUmpiresOnly() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(96), seats: [.human, .bot, .bot], startSequenceTicks: 60)
        let authoritative = Race(setup: setup, windSeed: WindSeed(96))
        let prediction = try Self.prediction(of: authoritative, through: 60, windSeed: WindSeed(96))
        #expect(prediction.keepClearRelations(of: 0) == [nil, nil, nil])
        let relations = Race.UmpireRelations(seat: 0, keepClear: [nil, RightOfWay(keepClear: 0, rule: .portStarboard), nil],
                                             restrictedBy: [2])
        prediction.setUmpireRelations(relations)
        #expect(prediction.keepClearRelations(of: 0) == relations.keepClear)
        #expect(prediction.properCourseRestrictions(of: 0) == [2])
        #expect(prediction.keepClearRelations(of: 1) == [nil, nil, nil])
        #expect(prediction.properCourseRestrictions(of: 1).isEmpty)
        prediction.setUmpireRelations(nil)
        #expect(prediction.keepClearRelations(of: 0) == [nil, nil, nil])
    }
}
