import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol
import Testing

/// A covered boat (#150): a dropped player's boat, sailed by the cautious bot from the end of the input hold until she
/// is back or the race closes. Still her seat: her name, never a bot's glyph, only the disconnected mark on the roster.
/// The gun is at tick 0. Ticks are found by condition (the first tick the boat is racing, the first finish), never
/// picked by hand; the rig's seats send only what a test sends, so a seat that is attached and silent stays its
/// player's unless `firstInputHold` is set.
@Suite(.timeLimit(.minutes(3))) struct CoveredBoatTests {
    private func held(_ rudder: Int8) -> Message { .inputHeld(BoatInput(rudder: rudder)) }

    private func rosterChanges(_ transport: RecordingTransport) -> [RosterChange] {
        transport.frames.compactMap { if case .rosterChange(let change) = $0.message { change } else { nil } }
    }

    private func raceStarts(_ transport: RecordingTransport) -> [RaceStart] {
        transport.frames.compactMap { if case .raceStart(let start) = $0.message { start } else { nil } }
    }

    /// The cautious driver covering `seat`, if one is.
    private func cover(_ rig: Rig, _ seat: Int) async -> BotDriver? {
        guard case .dropped(let driver) = await rig.host.controller(seat: seat), driver.isCautious else { return nil }
        return driver
    }

    private func inputTicks(_ log: RaceLog, seat: Int, after tick: Int) -> [Int] {
        log.inputs.filter { $0.seat == seat && $0.tick > tick }.map(\.tick)
    }

    private func marked(_ entry: RosterEntry) -> RosterEntry {
        var entry = entry
        entry.isDisconnected = true
        return entry
    }

    /// Steps a tick at a time from the host's tick until `condition` holds, at most to `limit`: the first such tick.
    private func firstTick(_ rig: Rig, limit: Int, where condition: (RaceHost) async -> Bool) async -> Int? {
        var tick = await rig.host.tick
        while await !rig.host.isEnded {
            if await condition(rig.host) { return tick }
            guard tick < limit else { return nil }
            tick += 1
            await rig.run(to: tick)
        }
        return nil
    }

    /// Seat 1 attached, then gone from `tick`: her hold runs out 15 ticks later.
    private func drop(_ rig: Rig, seat: Int, at tick: Int) async -> RecordingTransport {
        let transport = RecordingTransport()
        #expect(await rig.host.attach(seat: seat, transport: transport))
        await rig.run(to: tick)
        await rig.host.disconnect(seat: seat)
        return transport
    }

    // MARK: The cover

    /// The ticket's acceptance: a drop at t = 120 s. The boat is racing then (the cautious bot started her: she was
    /// covered from before the gun, and her player came back for this), her last held input is at the first tick from
    /// 3600 on at which she races, the helm is released 15 ticks later, and from there the log holds the cautious bot's
    /// inputs for her seat: the first decision within three ticks, every one on her seat's phase.
    @Test func droppedAtTwoMinutesLogsCautiousInputsFromFifteenTicksOn() async throws {
        let rig = try await Rig(humans: 2, seats: 6, laps: 2)
        _ = await drop(rig, seat: 1, at: -290)
        await rig.run(to: 3600)
        let racing = try #require(await firstTick(rig, limit: 7200) { await $0.boat(seat: 1).status == .racing })
        #expect(await cover(rig, 1) != nil)
        #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
        let last = racing + 1
        await rig.send(held(40), seq: 1, stamp: last, from: 1)
        let drop = last + 15
        await rig.run(to: drop - 1)
        #expect(await rig.host.controller(seat: 1).isHuman)
        #expect(await !rig.host.rosterEntries[1].isDisconnected)
        await rig.run(to: drop)
        let covering = try #require(await cover(rig, 1))
        #expect(covering.decisions == 0)
        #expect(await rig.host.rosterEntries[1].isDisconnected)
        await rig.run(to: drop + 3)
        #expect(try #require(await cover(rig, 1)).decisions == 1, "her first decision comes within three ticks")
        await rig.run(to: drop + 600)

        let log = await rig.host.log
        let hers = log.inputs.filter { $0.seat == 1 }
        // Her own input, nothing through the hold, then the helm's release.
        #expect(hers.contains { record in
            if case .held(let input) = record.kind { record.tick == last && input == BoatInput(rudder: 40 as Int8) } else { false }
        })
        #expect(!hers.contains { $0.tick > last && $0.tick < drop })
        #expect(hers.contains { record in
            if case .held(let input) = record.kind { record.tick == drop && input == .neutral } else { false }
        })
        // From there the bot's: each sent on a decision tick of her seat's phase, for the next tick.
        let phase = BotDriver.cautious(seat: 1, raceSeed: rig.setup.raceSeed)
        let after = hers.filter { $0.tick > drop }
        #expect(!after.isEmpty, "the cautious bot sent nothing in 20 s")
        #expect(after.allSatisfy { phase.decides(atTick: $0.tick - 1) })
        #expect(log.seatEvents.filter { $0.seat == 1 && $0.tick >= racing }.map(\.kind) == [.rejoined, .dropped, .botTookOver(.cautious)])
        #expect(log.seatEvents.last == SeatEvent(tick: drop, seat: 1, kind: .botTookOver(.cautious)))
        // Not a bot seat, not in the fleet's bots.
        #expect(await rig.host.botSeats.isEmpty)
    }

    /// A drop doesn't dodge a penalty (owner 2026-10-11): the boat keeps the turns she owed and the turn she had begun,
    /// and the cautious bot serves it. The race is the first seed in which the player, sailing a straight helm, is called.
    @Test func aCoveredBoatKeepsHerOwedPenaltyAndTheSamePenaltyTurn() async throws {
        var found: (rig: Rig, seq: UInt32)?
        for seed in UInt64(1)...40 where found == nil {
            let rig = try await Rig(seats: 8, startSequenceTicks: 900, raceSeed: RaceSeed(seed))
            var seq: UInt32 = 0
            while await rig.host.tick < 1500, await !rig.host.isEnded {
                let boat = await rig.host.boat(seat: 0)
                if boat.penaltyTurnsOwed > 0, boat.status != .dsq {
                    found = (rig, seq)
                    break
                }
                seq += 1
                await rig.send(held(0), seq: seq, stamp: await rig.host.tick + 1)
                await rig.run(to: await rig.host.tick + 5)
            }
        }
        let (rig, start) = try #require(found, "no seed of 40 gave the player a penalty")
        var seq = start
        // She begins her turn, hard over, and is gone part of the way round.
        for _ in 0..<45 {
            let boat = await rig.host.boat(seat: 0)
            guard boat.penaltyTurnsOwed > 0, abs(boat.penaltyProgress) < 0.5 else { break }
            seq += 1
            await rig.send(held(100), seq: seq, stamp: await rig.host.tick + 1)
            await rig.run(to: await rig.host.tick + 1)
        }
        let last = await rig.host.tick
        let drop = last + 15
        await rig.run(to: drop - 1)
        let before = await rig.host.boat(seat: 0)
        try #require(before.penaltyTurnsOwed > 0 && before.status != .dsq, "the turn was over before the drop")
        await rig.run(to: drop)
        let taken = await rig.host.boat(seat: 0)
        #expect(await cover(rig, 0) != nil)
        // The takeover takes the boat as she is: the same turns owed, the same turn, on its own clock.
        #expect(taken.penaltyTurnsOwed == before.penaltyTurnsOwed)
        #expect(taken.penaltyClockTick == before.penaltyClockTick)
        #expect(abs(taken.penaltyProgress) >= abs(before.penaltyProgress) || taken.penaltyProgress == 0 && before.penaltyProgress == 0)

        // The bot serves it: every turn she owed, no disqualification for a turn nobody answered.
        let served = await firstTick(rig, limit: drop + 1800) { await $0.boat(seat: 0).penaltyTurnsOwed == 0 }
        let events = rig.seat0.events.filter { $0.tick >= drop }.map(\.kind)
        let owed = await rig.host.boat(seat: 0).penaltyTurnsOwed
        #expect(served != nil, "the covered boat still owes \(owed) turn(s) a minute on")
        #expect(await rig.host.boat(seat: 0).status != .dsq)
        #expect(events.contains(.penaltyServed(seat: 0)))
        #expect(!events.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } })
        // Nothing reset at the takeover itself.
        #expect(!rig.seat0.events.contains { $0.tick >= drop && $0.tick <= drop + 3 && $0.kind == .penaltyReset(seat: 0) })
    }

    /// Handback (CONTEXT): at the rejoin the boat is hers as she is. The host sends no input of its own, the bot sends
    /// no more, and nothing of the boat changes: her tack, her rudder, her penalty.
    @Test func rejoinHandsBackWithNoMoreBotInputsAndKeepsTackAndPenaltyProgress() async throws {
        let rig = try await Rig(humans: 2, seats: 6)
        _ = await drop(rig, seat: 1, at: 30)
        await rig.run(to: 345)
        #expect(await cover(rig, 1) != nil)
        let before = await rig.host.boat(seat: 1)
        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: back))
        let rejoin = await rig.host.tick
        let after = await rig.host.boat(seat: 1)
        #expect(await rig.host.controller(seat: 1).isHuman)
        #expect(after.position == before.position && after.heading == before.heading && after.speed == before.speed)
        #expect(after.tack == before.tack && after.rudder == before.rudder && after.status == before.status)
        #expect(after.penaltyTurnsOwed == before.penaltyTurnsOwed && after.penaltyProgress == before.penaltyProgress
                && after.penaltyClockTick == before.penaltyClockTick)
        #expect(await rig.host.log.seatEvents.last == SeatEvent(tick: rejoin, seat: 1, kind: .rejoined))

        // No input for her seat after the rejoin tick until she sends one: not the bot's, not a neutral of the host's.
        await rig.run(to: rejoin + 20)
        #expect(inputTicks(await rig.host.log, seat: 1, after: rejoin).isEmpty)
        #expect(!rig.seat0.events.contains { $0.tick >= rejoin && $0.kind == .penaltyReset(seat: 1) })
        await rig.send(held(-30), seq: 1, stamp: rejoin + 21, from: 1)
        await rig.run(to: rejoin + 30)
        #expect(inputTicks(await rig.host.log, seat: 1, after: rejoin) == [rejoin + 21])
        // Gone again: a fresh cautious driver, from her first decision.
        await rig.run(to: rejoin + 21 + 15)
        #expect(try #require(await cover(rig, 1)).decisions == 0)

        let outcome = await rig.host.close()
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)
    }

    /// A seat that never sends is covered a second after it attaches, and one nobody attaches to a second after the
    /// host starts; the boat is handed back the moment its player attaches, and covered again if she stays silent.
    @Test func aSilentSeatIsCoveredAfterOneSecondAndHandedBackWhenItAttaches() async throws {
        let rig = try await Rig(humans: 2, seats: 4, firstInputHold: true)
        await rig.run(to: -271)
        for seat in 0..<2 { #expect(await rig.host.controller(seat: seat).isHuman) }
        await rig.run(to: -270)
        for seat in 0..<2 { #expect(await cover(rig, seat) != nil) }
        #expect(await rig.host.rosterEntries.map(\.isDisconnected) == [true, true, false, false])
        await rig.run(to: -200)

        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        #expect(await rig.host.controller(seat: 1).isHuman)
        #expect(await rig.host.rosterEntries.map(\.isDisconnected) == [true, false, false, false])
        #expect(raceStarts(seat1).first?.roster.map(\.isDisconnected) == [true, false, false, false])
        await rig.run(to: -171)
        #expect(await rig.host.controller(seat: 1).isHuman)
        await rig.run(to: -170)
        #expect(try #require(await cover(rig, 1)).decisions == 0)
        #expect(await rig.host.rosterEntries.map(\.isDisconnected) == [true, true, false, false])
        #expect(await rig.host.log.seatEvents.filter { $0.seat == 1 }.map(\.kind)
                == [.dropped, .botTookOver(.cautious), .joined(.human), .dropped, .botTookOver(.cautious)])
    }

    /// A Leave after the gun: the boat is still on the water, so she is covered and marked as a dropped boat is, for
    /// good. (Her player is rated as retired if the boat hasn't finished at the close, #151.)
    @Test func leavingAfterTheGunIsCoveredAndMarked() async throws {
        let rig = try await Rig(humans: 2, seats: 4)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        let roster = await rig.host.rosterEntries
        await rig.run(to: 30)
        await rig.send(held(20), seq: 1, stamp: 31, from: 1)
        await rig.run(to: 33)
        #expect(await rig.host.leave(seat: 1))
        #expect(rig.leftAfterGun == [1])
        // The hold runs from the leave: 15 ticks.
        await rig.run(to: 47)
        #expect(await rig.host.rosterEntries == roster && rosterChanges(rig.seat0).isEmpty)
        await rig.run(to: 48)
        #expect(await cover(rig, 1) != nil)
        var expected = roster
        expected[1] = marked(roster[1])
        #expect(await rig.host.rosterEntries == expected)
        #expect(rosterChanges(rig.seat0) == [RosterChange(seat: 1, entry: expected[1])])
        #expect(await rig.host.botSeats.isEmpty && !expected[1].isBot)
        #expect(await !rig.host.attach(seat: 1, transport: RecordingTransport()))
        await rig.run(to: 400)
        #expect(await rig.host.rosterEntries == expected && rosterChanges(rig.seat0).count == 1)
        // A closed race has nobody disconnected.
        _ = await rig.host.close()
        #expect(await rig.host.rosterEntries == roster)
    }

    // MARK: The disconnected mark

    /// The mark rides a `RosterChange` to every attached seat at the drop tick (not at the socket's close: a gap
    /// shorter than the hold shows nothing) and is cleared the same way the moment she is back. Nothing else of her
    /// entry moves. Before the gun and racing alike.
    @Test(arguments: [-200, 90]) func theMarkRidesTheRosterChangeAtTheDropAndClearsAtTheRejoin(at tick: Int) async throws {
        let rig = try await Rig(humans: 3, seats: 5)
        let seat1 = RecordingTransport(), seat2 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        #expect(await rig.host.attach(seat: 2, transport: seat2))
        let roster = await rig.host.rosterEntries
        #expect(roster.allSatisfy { !$0.isDisconnected })

        // A blip: seat 2's socket closes and she is back inside the hold. Nobody hears of it.
        await rig.run(to: tick - 20)
        await rig.host.disconnect(seat: 2)
        await rig.run(to: tick - 10)
        let again = RecordingTransport()
        #expect(await rig.host.attach(seat: 2, transport: again))
        await rig.run(to: tick)
        #expect(rosterChanges(rig.seat0).isEmpty && rosterChanges(seat1).isEmpty && rosterChanges(again).isEmpty)

        // Seat 1's socket closes: nothing for 14 ticks, then the mark, stamped with the drop's tick.
        await rig.host.disconnect(seat: 1)
        await rig.run(to: tick + 14)
        #expect(rosterChanges(rig.seat0).isEmpty && rosterChanges(again).isEmpty)
        await rig.run(to: tick + 15)
        let gone = RosterChange(seat: 1, entry: marked(roster[1]))
        #expect(gone.entry.name == roster[1].name && !gone.entry.isBot && gone.entry.colorIndex == roster[1].colorIndex)
        for transport in [rig.seat0, again] {
            #expect(rosterChanges(transport) == [gone])
            #expect(transport.frames.first { $0.message == .rosterChange(gone) }?.tick == tick + 15)
        }
        #expect(await rig.host.log.seatEvents.last { $0.kind == .dropped } == SeatEvent(tick: tick + 15, seat: 1, kind: .dropped))
        #expect(await rig.host.log.header.setup.seats == rig.setup.seats)

        // Back: the mark is gone for everyone at once, and her `RaceStart` never had it.
        await rig.run(to: tick + 100)
        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: back))
        let returned = RosterChange(seat: 1, entry: roster[1])
        for transport in [rig.seat0, again] {
            #expect(rosterChanges(transport) == [gone, returned])
            #expect(transport.frames.last { $0.message == .rosterChange(returned) }?.tick == tick + 100)
        }
        #expect(raceStarts(back).first?.roster == roster)
        #expect(await rig.host.rosterEntries == roster)

        // A seat that stays attached and falls silent is marked for everyone, herself too; sending again clears it,
        // on her stream ahead of her resync.
        await rig.send(held(10), seq: 1, stamp: tick + 101, from: 2)
        await rig.run(to: tick + 116)
        let silent = RosterChange(seat: 2, entry: marked(roster[2]))
        #expect(rosterChanges(again) == [gone, returned, silent] && rosterChanges(rig.seat0).last == silent && rosterChanges(back).last == silent)
        await rig.run(to: tick + 150)
        await rig.send(held(10), seq: 2, stamp: tick + 151, from: 2)
        let awake = RosterChange(seat: 2, entry: roster[2])
        #expect(rosterChanges(rig.seat0).last == awake && rosterChanges(back).last == awake)
        let frames = again.frames
        let cleared = try #require(frames.firstIndex { $0.message == .rosterChange(awake) })
        let resync = try #require(frames.lastIndex { if case .resync = $0.message { true } else { false } })
        #expect(cleared < resync)
        #expect(await rig.host.rosterEntries == roster)
    }

    /// A seat that attaches late, and one that asks for a resync, get the marks as they stand: in the `RaceStart`'s
    /// seat table, and after a resync as each ever-marked seat's whole entry.
    @Test func aLateAttachAndAResyncCarryTheMark() async throws {
        let rig = try await Rig(humans: 3, seats: 5)
        _ = await drop(rig, seat: 1, at: 30)
        await rig.run(to: 60)
        let roster = await rig.host.rosterEntries
        #expect(roster.map(\.isDisconnected) == [false, true, false, false, false])

        // Seat 2 was never attached (the rig waits for ever for her): she attaches now.
        let late = RecordingTransport()
        #expect(await rig.host.attach(seat: 2, transport: late))
        #expect(raceStarts(late).first?.roster == roster)
        let bytes = try #require(late.sentBytes.first)
        guard case .raceStart(let decoded) = try Frame(decoding: bytes).message else {
            Issue.record("no RaceStart")
            return
        }
        #expect(decoded.roster[1].isDisconnected && !decoded.roster[1].isBot && decoded.setup.seats == rig.setup.seats)
        #expect(rosterChanges(late) == [RosterChange(seat: 1, entry: roster[1])], "again after her resync")

        // A resync restarts the reliable stream: the mark goes again.
        let before = rosterChanges(rig.seat0).count
        await rig.send(.requestResync, seq: 1, stamp: 61)
        #expect(rosterChanges(rig.seat0).dropFirst(before) == [RosterChange(seat: 1, entry: roster[1])])

        // And so does its clearing: a seat that missed it would show her gone for ever.
        await rig.run(to: 120)
        #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
        let count = rosterChanges(rig.seat0).count
        await rig.send(.requestResync, seq: 2, stamp: 121)
        var back = roster[1]
        back.isDisconnected = false
        #expect(rosterChanges(rig.seat0).dropFirst(count) == [RosterChange(seat: 1, entry: back)])
    }

    /// A seat given up before the gun is a fleet bot's for good (#149): a bot's entry, never the mark, even if the
    /// boat was covered when its player left.
    @Test func aPreGunLeaveStaysABotNotAMark() async throws {
        let fleet = FleetFill(medianRating: 1500)
        let rig = try await Rig(humans: 3, seats: 5, fleet: fleet)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        _ = await drop(rig, seat: 2, at: -280)
        await rig.run(to: -240)
        #expect(await rig.host.rosterEntries[2].isDisconnected)
        // Seat 1 leaves from her seat; seat 2's player, already covered, leaves too.
        #expect(await rig.host.leave(seat: 1))
        #expect(await rig.host.leave(seat: 2))
        let roster = await rig.host.rosterEntries
        for seat in [1, 2] {
            #expect(roster[seat].isBot && !roster[seat].isDisconnected)
            guard case .bot(let driver) = await rig.host.controller(seat: seat) else {
                Issue.record("seat \(seat) is \(await rig.host.controller(seat: seat))")
                continue
            }
            #expect(!driver.isCautious)
        }
        #expect(await rig.host.botSeats.filter { $0.source == .takeover }.map(\.seat) == [1, 2])
        await rig.run(to: 60)
        #expect(await rig.host.rosterEntries == roster)
        #expect(rosterChanges(rig.seat0).last == RosterChange(seat: 2, entry: roster[2]))
        #expect(rosterChanges(rig.seat0).filter { $0.entry.isDisconnected }.count == 1, "only seat 2's drop, before she left")
        // A late attach sees two bots and no mark.
        let late = RecordingTransport()
        await rig.host.disconnect(seat: 0)
        #expect(await rig.host.attach(seat: 0, transport: late))
        #expect(raceStarts(late).first?.roster == roster)
    }

    // MARK: Results

    /// The race whose covered boat (seat 1, covered from before the gun) finishes: the first seed of 20 in which she does.
    private func sailedHome() async throws -> (rig: Rig, outcome: RaceOutcome) {
        for seed in UInt64(1)...20 {
            let rig = try await Rig(humans: 2, seats: 5, raceSeed: RaceSeed(seed))
            _ = await drop(rig, seat: 1, at: -290)
            var tick = -290
            while await !rig.host.isEnded, tick < 18_000 {
                tick += 60
                await rig.run(to: tick)
            }
            guard let outcome = await rig.host.outcome, outcome.results?.row(of: 1)?.code == .finished else { continue }
            return (rig, outcome)
        }
        throw Unfinished()
    }

    private struct Unfinished: Error {}

    /// The bot's finish is in the results as any finish: `finished`, at her place, with her finish tick. (What it is
    /// worth to her player is the close's business, `CoveredFinish`.)
    @Test func coveredAndFinishedIsFinishedNotRET() async throws {
        let (rig, outcome) = try await sailedHome()
        let results = try #require(outcome.results)
        let row = try #require(results.row(of: 1))
        #expect(row.code == .finished && row.finishTick != nil)
        #expect(results.rows.filter { $0.code != .finished }.allSatisfy { $0.place > row.place })
        #expect(await cover(rig, 1) != nil, "covered to the close")
        // The seat events say she was gone when the boat crossed the line.
        let finish = try #require(row.finishTick)
        let gone = outcome.log.seatEvents.last { $0.seat == 1 && $0.kind == .dropped }
        #expect(try #require(gone).tick < finish)
        #expect(!outcome.log.seatEvents.contains { $0.seat == 1 && $0.kind == .rejoined })
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)
        #expect(try Replayer.replay(outcome.log).results == results)
    }

    /// Still gone at the close with the boat racing and not home: RET, behind every boat placed (the ticket's "gone at
    /// close -> RET"). The bot started her; her player came back, sailed on, and dropped at the first finish.
    @Test func coveredAndUnfinishedAtTheCloseIsRETBehindTheBoatsStillRacing() async throws {
        let rig = try await Rig(humans: 2, seats: 5)
        _ = await drop(rig, seat: 1, at: -290)
        let racing = try #require(await firstTick(rig, limit: 3600) { await $0.boat(seat: 1).status == .racing })
        await rig.run(to: racing + 30)
        #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
        let first = try #require(await firstTick(rig, limit: 18_000) { _ in rig.seat0.events.contains { if case .finished = $0.kind { true } else { false } } })
        try #require(await rig.host.boat(seat: 1).status == .racing)
        await rig.host.disconnect(seat: 1)
        var tick = first
        while await !rig.host.isEnded, tick < first + 9000 {
            tick += 30
            await rig.run(to: tick)
        }
        let outcome = try #require(await rig.host.outcome)
        let results = try #require(outcome.results)
        try #require(await rig.host.boat(seat: 1).status == .racing, "the covered boat got home")
        let row = try #require(results.row(of: 1))
        #expect(row.code == .ret && row.finishTick == nil)
        #expect(results.rows.filter { $0.code == .finished || $0.code == .byDistance }.allSatisfy { $0.place < row.place })
        #expect(results.rows.allSatisfy { $0.place <= row.place })
        #expect(await cover(rig, 1) != nil)
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)
    }

    /// The point the brief left open: a covered boat that never started. Her player is gone and the boat is neither
    /// finished nor disqualified, so she is RET, not OCS (`Race.score`: gone comes before never started).
    @Test func aCoveredBoatThatNeverStartedIsRET() async throws {
        var options = RaceHostOptions()
        options.allGone.endsRace = true
        options.allGone.graceTicks = 30
        let rig = try await Rig(humans: 2, seats: 5, startSequenceTicks: 900, options: options)
        // Seat 1 is covered from the start of the sequence; her player never comes. Seat 0's leaves well before the
        // gun's fleet has started... and the race ends for want of humans while the covered boat is still pre-start.
        _ = await drop(rig, seat: 1, at: -890)
        await rig.run(to: 10)
        try #require(await [.prestart, .ocs].contains(rig.host.boat(seat: 1).status), "the covered boat started inside a third of a second")
        #expect(await rig.host.leave(seat: 0))
        var tick = 10
        while await !rig.host.isEnded, tick < 300 {
            tick += 5
            await rig.run(to: tick)
        }
        let outcome = try #require(await rig.host.outcome)
        let results = try #require(outcome.results)
        try #require(await [.prestart, .ocs].contains(rig.host.boat(seat: 1).status))
        #expect(results.row(of: 1)?.code == .ret)
        #expect(results.row(of: 0)?.code == .ret)
        #expect(!results.rated, "nobody but seat 0 was at the gun")
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)
    }

    // MARK: Mass drop (G3)

    private func massDropRig() async throws -> (rig: Rig, dropped: Int) {
        var options = RaceHostOptions()
        options.allGone.endsRace = true
        let rig = try await Rig(humans: 3, seats: 6, options: options)
        let seat1 = RecordingTransport(), seat2 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        #expect(await rig.host.attach(seat: 2, transport: seat2))
        await rig.run(to: 60)
        for seat in 0..<3 { await rig.host.disconnect(seat: seat) }
        await rig.run(to: 75)
        for seat in 0..<3 { #expect(await cover(rig, seat) != nil) }
        return (rig, 75)
    }

    /// Every human dropped within 2 s: each boat is covered through the 30 s grace, then the race is cancelled, with
    /// no results (unchanged; the covers are what is new).
    @Test func massDropKeepsEveryBoatCoveredThroughTheGraceThenCancels() async throws {
        let (rig, dropped) = try await massDropRig()
        await rig.run(to: dropped + 899)
        #expect(await !rig.host.isEnded)
        for seat in 0..<3 {
            #expect(await cover(rig, seat) != nil)
            #expect(await rig.host.rosterEntries[seat].isDisconnected)
            #expect(!inputTicks(await rig.host.log, seat: seat, after: dropped).isEmpty, "seat \(seat)'s cover sent nothing in 30 s")
        }
        await rig.run(to: dropped + 900)
        #expect(await rig.host.cancelled == .unspecified)
        #expect(rig.allGones == [AllGone(tick: dropped + 900, leaveOrder: [0, 1, 2], isMassDrop: true)])
        #expect(await rig.host.close().results == nil)
    }

    /// One back inside the grace: the race goes on, her boat alone is handed back.
    @Test func oneBackInTheGraceKeepsTheRaceAndHandsBackOnlyHers() async throws {
        let (rig, dropped) = try await massDropRig()
        await rig.run(to: dropped + 300)
        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 2, transport: back))
        #expect(await rig.host.controller(seat: 2).isHuman)
        for seat in 0..<2 { #expect(await cover(rig, seat) != nil) }
        #expect(await rig.host.rosterEntries.map(\.isDisconnected) == [true, true, false, false, false, false])
        #expect(raceStarts(back).first?.roster.map(\.isDisconnected) == [true, true, false, false, false, false])
        await rig.run(to: dropped + 1500)
        #expect(await !rig.host.isEnded && rig.allGones.isEmpty)
        #expect(await rig.host.controller(seat: 2).isHuman)
        for seat in 0..<2 { #expect(await cover(rig, seat) != nil) }
    }
}
