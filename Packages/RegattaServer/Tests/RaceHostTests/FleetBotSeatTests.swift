import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol
import Testing

/// #149: an online race's bot seats on the host. Fill bots sail at the fleet's level from the start; a seat its
/// player gives up before the gun (`tick < 0`) goes to a bot of that level for good, where the boat is, under a
/// sailing name; a seat that merely dropped stays its player's. The gun is at tick 0.
struct FleetBotSeatTests {
    static let fleet = FleetFill(medianRating: 1500)

    private func held(_ rudder: Int8) -> Message { .inputHeld(BoatInput(rudder: rudder)) }

    private func rosterChanges(_ transport: RecordingTransport) -> [RosterChange] {
        transport.frames.compactMap { if case .rosterChange(let change) = $0.message { change } else { nil } }
    }

    private func raceStarts(_ transport: RecordingTransport) -> [RaceStart] {
        transport.frames.compactMap { if case .raceStart(let start) = $0.message { start } else { nil } }
    }

    private func driver(_ controller: SeatController) -> BotDriver? {
        if case .bot(let driver) = controller { driver } else { nil }
    }

    @Test func fillBotsSailAtTheFleetDrawFromTheirFirstDecision() async throws {
        let rig = try await Rig(humans: 1, seats: 6, fleet: Self.fleet)
        let seed = rig.setup.raceSeed
        // Each bot seat is the fleet's bot for it: her rating within 150 of the median, her skill the map's.
        for seat in 1..<6 {
            let plan = Self.fleet.plan(seat: seat, raceSeed: seed)
            let bot = try #require(driver(await rig.host.controller(seat: seat)))
            #expect(bot.style.skill == plan.skill && bot.handling == plan.handling && bot.decisions == 0)
            #expect((1350...1650).contains(plan.rating))
        }
        #expect(await rig.host.botSeats == (1..<6).map { BotSeat(seat: $0, source: .fill, plan: Self.fleet.plan(seat: $0, raceSeed: seed)) })
        #expect(await rig.host.rosterEntries.map(\.isBot) == [false, true, true, true, true, true])
        #expect(raceStarts(rig.seat0).first?.roster.map(\.isBot) == [false, true, true, true, true, true])

        // The host's race is the race those drivers sail on their own: the same inputs, tick for tick, from each
        // one's first decision (within three ticks of the start).
        let reference = Race(setup: rig.setup, windSeed: rig.windSeed)
        var controllers = SeatControllers(rig.setup.seats.indices.map { seat in
            rig.setup.seats[seat] == .bot ? .bot(Self.fleet.driver(seat: seat, raceSeed: seed)) : .human
        })
        let first = reference.tick
        while reference.tick < first + 3 {
            controllers.drive(reference)
            reference.step()
        }
        await rig.run(to: first + 3)
        for seat in 1..<6 { #expect(driver(await rig.host.controller(seat: seat))?.decisions == 1) }
        while reference.tick < 90 {
            controllers.drive(reference)
            reference.step()
        }
        await rig.run(to: 90)
        let log = await rig.host.log
        #expect(log.inputs == reference.log?.inputs)
        #expect(log.inputs.contains { $0.seat != 0 })
        #expect(try Replayer.digest(of: log) == reference.digest())

        // Without a fleet the host keeps the Mixed-fleet draw and records no bots.
        let mixed = try await Rig(humans: 1, seats: 6)
        let drawn = try #require(driver(await mixed.host.controller(seat: 1)))
        #expect(drawn.style.skill == BotTier.mixedFleetDraw(seed: botSeed(raceSeed: seed, seat: 1)).skill)
        #expect(await mixed.host.botSeats.isEmpty)
    }

    @Test func leavingBeforeTheGunTakesTheSeatAtTheBoatsPositionWithinThreeTicks() async throws {
        let rig = try await Rig(humans: 2, seats: 6, fleet: Self.fleet)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        await rig.run(to: -210)
        await rig.send(held(40), seq: 1, stamp: -205, from: 1)
        await rig.run(to: -200)
        let names = await rig.host.rosterEntries.map(\.name)
        let before = await rig.host.boat(seat: 1)
        #expect(await rig.host.leave(seat: 1))

        // Where the boat is, at once, and for good.
        let after = await rig.host.boat(seat: 1)
        #expect(after.position == before.position && after.heading == before.heading && after.speed == before.speed)
        #expect(seat1.isClosed)
        #expect(await rig.host.hasLeft(seat: 1))
        #expect(await !rig.host.attach(seat: 1, transport: RecordingTransport()))
        #expect(rig.briefingLeaves == [BriefingLeave(seat: 1, kind: .left)])
        #expect(rig.leftAfterGun.isEmpty)

        // A bot of the fleet's level, not a cautious one: she races to win.
        let plan = Self.fleet.plan(seat: 1, raceSeed: rig.setup.raceSeed)
        let bot = try #require(driver(await rig.host.controller(seat: 1)))
        #expect(bot.style.skill == plan.skill && bot.handling == plan.handling && !bot.isCautious)
        #expect(await rig.host.botSeats.first { $0.seat == 1 } == BotSeat(seat: 1, source: .takeover, plan: plan, takenTick: -200))
        #expect(await rig.host.botSeats.filter { $0.source == .fill }.map(\.seat) == [2, 3, 4, 5])

        // Labelled a bot from then on, under a sailing name no other boat has; nobody else's entry moves.
        let roster = await rig.host.rosterEntries
        #expect(roster[1].isBot && FleetRoster.sailingNames.contains(roster[1].name) && roster[1].colorIndex == 1)
        #expect(Set(roster.map(\.name)).count == 6)
        for seat in [0, 2, 3, 4, 5] { #expect(roster[seat].name == names[seat]) }
        #expect(!roster[0].isBot)
        // The others are told once, on the reliable stream; the setup's seats never change.
        #expect(rosterChanges(rig.seat0) == [RosterChange(seat: 1, entry: roster[1])])
        #expect(rosterChanges(seat1).isEmpty)
        #expect(await rig.host.log.header.setup.seats == rig.setup.seats)
        #expect(await rig.host.log.seatEvents.filter { $0.seat == 1 } == [
            SeatEvent(tick: -300, seat: 1, kind: .joined(.human)),
            SeatEvent(tick: -200, seat: 1, kind: .leftBeforeGun),
            SeatEvent(tick: -200, seat: 1, kind: .botTookOver(.fleet)),
        ])

        // Her helm is released at the next tick, and the bot's first decision comes within three.
        await rig.run(to: -197)
        #expect(try #require(driver(await rig.host.controller(seat: 1))).decisions == 1)
        let inputs = await rig.host.log.inputs.filter { $0.seat == 1 }
        #expect(inputs.contains { record in
            if case .held(let input) = record.kind { record.tick == -199 && input == .neutral } else { false }
        })
        #expect((await rig.host.boat(seat: 1).position - before.position).length < 2)

        // One who joins now, or asks for a resync, sees the roster as it is.
        let late = RecordingTransport()
        await rig.host.disconnect(seat: 0)
        #expect(await rig.host.attach(seat: 0, transport: late))
        #expect(raceStarts(late).first?.roster == roster)
        #expect(rosterChanges(late) == [RosterChange(seat: 1, entry: roster[1])])

        // A second leave, and one from a bot seat, do nothing.
        #expect(await !rig.host.leave(seat: 1))
        #expect(await !rig.host.leave(seat: 3))
        #expect(await rig.host.rosterEntries == roster)

        // The log replays, brains unseen, to the host's race.
        await rig.run(to: 60)
        let outcome = await rig.host.close()
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)
    }

    @Test func aLeaveAtTickZeroIsAfterTheGun() async throws {
        // One tick before the gun is still before it.
        let early = try await Rig(humans: 2, seats: 4, fleet: Self.fleet)
        await early.run(to: -1)
        #expect(await early.host.leave(seat: 0))
        #expect(await early.host.rosterEntries[0].isBot)
        #expect(early.briefingLeaves == [BriefingLeave(seat: 0, kind: .left)] && early.leftAfterGun.isEmpty)
        #expect(await early.host.botSeats.contains { $0.seat == 0 && $0.source == .takeover && $0.takenTick == -1 })

        // At the gun's tick it is after it: the dropped-boat path for good, no bot seat, no new name.
        let rig = try await Rig(humans: 2, seats: 4, fleet: Self.fleet)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        await rig.run(to: 0)
        let roster = await rig.host.rosterEntries
        #expect(await rig.host.leave(seat: 0))
        #expect(rig.leftAfterGun == [0])
        #expect(rig.briefingLeaves.isEmpty)
        #expect(await rig.host.rosterEntries == roster)
        #expect(rosterChanges(seat1).isEmpty)
        #expect(await rig.host.botSeats.map(\.source) == [.fill, .fill])
        #expect(await rig.host.log.seatEvents.contains(SeatEvent(tick: 0, seat: 0, kind: .left)))
        #expect(await !rig.host.log.seatEvents.contains { $0.kind == .leftBeforeGun })
        #expect(await rig.host.controller(seat: 0).isHuman)
        await rig.run(to: 15)
        if case .dropped = await rig.host.controller(seat: 0) {} else { Issue.record("seat 0 is \(await rig.host.controller(seat: 0))") }
        #expect(await rig.host.hasLeft(seat: 0))
        #expect(await !rig.host.attach(seat: 0, transport: RecordingTransport()))
        #expect(await rig.host.rosterEntries == roster)
    }

    @Test func aDropBackBeforeTheGunHandsBackAndCountsNothing() async throws {
        let rig = try await Rig(humans: 2, seats: 4, fleet: Self.fleet)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        let roster = await rig.host.rosterEntries
        await rig.run(to: -285)
        await rig.send(held(30), seq: 1, stamp: -280)
        await rig.run(to: -260)
        await rig.host.disconnect(seat: 0)
        // The hold (0.5 s), then the stub that covers a dropped boat: her seat, not a bot's.
        await rig.run(to: -200)
        if case .dropped = await rig.host.controller(seat: 0) {} else { Issue.record("seat 0 is \(await rig.host.controller(seat: 0))") }
        #expect(await rig.host.rosterEntries == roster)
        #expect(await rig.host.botSeats.map(\.source) == [.fill, .fill])
        #expect(await !rig.host.hasLeft(seat: 0))

        // Back before the gun, same seat: the boat is hers again.
        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 0, transport: back))
        #expect(await rig.host.controller(seat: 0).isHuman)
        #expect(await rig.host.log.seatEvents.last == SeatEvent(tick: -200, seat: 0, kind: .rejoined))
        #expect(raceStarts(back).first?.roster == roster)
        await rig.host.receive(try Frame(seq: 1, tick: -199, message: held(10)).encoded(), from: 0)
        await rig.run(to: 5)
        // Nothing counted, nobody relabelled, nobody told anything.
        #expect(rig.briefingLeaves.isEmpty && rig.leftAfterGun.isEmpty)
        #expect(await rig.host.rosterEntries == roster)
        #expect(rosterChanges(seat1).isEmpty && rosterChanges(back).isEmpty)
        #expect(await rig.host.botSeats.map(\.source) == [.fill, .fill])
    }

    @Test func aDropStillGoneAtTheGunCountsOnceAndStaysTheirSeat() async throws {
        let rig = try await Rig(humans: 2, seats: 4, fleet: Self.fleet)
        let seat1 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        let roster = await rig.host.rosterEntries
        await rig.run(to: -260)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: -1)
        #expect(rig.briefingLeaves.isEmpty)
        await rig.run(to: 60)
        #expect(rig.briefingLeaves == [BriefingLeave(seat: 0, kind: .absentAtGun)])
        #expect(rig.leftAfterGun.isEmpty)
        // Her seat still: covered, never a bot seat, no new name.
        if case .dropped = await rig.host.controller(seat: 0) {} else { Issue.record("seat 0 is \(await rig.host.controller(seat: 0))") }
        #expect(await rig.host.rosterEntries == roster)
        #expect(rosterChanges(seat1).isEmpty)
        #expect(await rig.host.botSeats.map(\.source) == [.fill, .fill])
        #expect(await !rig.host.hasLeft(seat: 0))
        // And she can take the boat back after the gun (#148).
        #expect(await rig.host.attach(seat: 0, transport: RecordingTransport()))
        #expect(await rig.host.controller(seat: 0).isHuman)
        await rig.run(to: 90)
        #expect(rig.briefingLeaves.count == 1)
    }

    @Test func takeoverAllGoneBeforeTheGunStillCloses() async throws {
        var options = RaceHostOptions()
        options.allGone.endsRace = true
        options.allGone.graceTicks = 30
        let rig = try await Rig(humans: 2, seats: 5, options: options, fleet: Self.fleet)
        #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
        await rig.run(to: -250)
        #expect(await rig.host.leave(seat: 1))
        await rig.run(to: -240)
        #expect(await rig.host.leave(seat: 0))
        let roster = await rig.host.rosterEntries
        #expect(roster.allSatisfy(\.isBot) && Set(roster.map(\.name)).count == 5)
        // Both takeover bots sail through the grace.
        await rig.run(to: -211)
        #expect(await !rig.host.isEnded)
        for seat in 0..<2 { #expect((driver(await rig.host.controller(seat: seat))?.decisions ?? 0) > 5) }
        await rig.run(to: -200)
        // The all-gone close, as before (G3): results, the leavers out in leave order, and the bots still recorded.
        #expect(rig.allGones == [AllGone(tick: -210, leaveOrder: [1, 0], isMassDrop: false)])
        let outcome = try #require(await rig.host.outcome)
        #expect(outcome.results != nil)
        #expect(await rig.host.cancelled == nil)
        #expect(await rig.host.botSeats.map(\.source) == [.takeover, .takeover, .fill, .fill, .fill])
        #expect(await rig.host.botSeats.prefix(2).map(\.takenTick) == [-240, -250])
        #expect(await rig.host.rosterEntries == roster)
        #expect(rig.briefingLeaves == [BriefingLeave(seat: 1, kind: .left), BriefingLeave(seat: 0, kind: .left)])
        #expect(try Replayer.digest(of: outcome.log) == outcome.digest)

        // A leave once the race has ended does nothing.
        #expect(await !rig.host.leave(seat: 0))
    }
}
