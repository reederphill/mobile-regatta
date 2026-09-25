import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol
import Testing

/// The host's seat flow on a virtual clock (#66): the input hold and the dropped boat, rejoins, leaving
/// before and after the gun, and the all-gone trigger (G3). The gun is at tick 0.
struct SeatLifecycleTests {
    private func held(_ rudder: Int8) -> Message { .inputHeld(BoatInput(rudder: rudder)) }

    private func heldInputs(_ log: RaceLog, seat: Int = 0) -> [(tick: Int, input: BoatInput)] {
        log.inputs.compactMap { record in
            guard record.seat == seat, case .held(let input) = record.kind else { return nil }
            return (record.tick, input)
        }
    }

    private func isDropped(_ controller: SeatController) -> Bool {
        if case .dropped = controller { true } else { false }
    }

    private func isFleetBot(_ controller: SeatController) -> Bool {
        if case .bot = controller { true } else { false }
    }

    private func hasResync(_ transport: RecordingTransport) -> Bool {
        transport.frames.contains { if case .resync = $0.message { true } else { false } }
    }

    /// Checks the dropped-boat path for seat 0 with its hold starting at `hold`: nothing from the seat in
    /// between, a neutral held input at exactly `hold + 15`, and the dropped-boat bot from that tick on.
    private func expectDrop(_ rig: Rig, holdFrom hold: Int) async {
        let drop = hold + 15
        await rig.run(to: drop - 1)
        #expect(await rig.host.controller(seat: 0).isHuman)
        await rig.run(to: drop)
        #expect(isDropped(await rig.host.controller(seat: 0)))
        await rig.run(to: drop + 60)
        #expect(isDropped(await rig.host.controller(seat: 0)))

        let log = await rig.host.log
        let records = heldInputs(log)
        #expect(!records.contains { $0.tick > hold && $0.tick < drop })
        #expect(records.contains { $0.tick == drop && $0.input == .neutral })
        // After the neutral input the bot decides on its seat's usual phase, and sends for the next tick.
        let driver = BotDriver(seat: 0, raceSeed: rig.setup.raceSeed)
        #expect(records.filter { $0.tick > drop }.allSatisfy { driver.decides(atTick: $0.tick - 1) })
        #expect(log.seatEvents.filter { $0.tick == drop }.map(\.kind) == [.dropped, .botTookOver(.cautious)])
    }

    // MARK: Input hold and the dropped boat (#18)

    @Test func silentSeatIsDroppedWithANeutralInputFifteenTicksAfterItsLastInput() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await expectDrop(rig, holdFrom: last)
        #expect(await rig.host.isAttached(seat: 0))
    }

    @Test func socketCloseStartsTheHoldRatherThanSkippingIt() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await rig.run(to: last + 5)
        await rig.host.disconnect(seat: 0)
        // The close came after the last input, so the hold runs from the close.
        await expectDrop(rig, holdFrom: last + 5)
        let kinds = await rig.host.log.seatEvents.map(\.kind)
        #expect(kinds == [.joined(.human), .disconnected, .dropped, .botTookOver(.cautious)])
    }

    @Test func repeatedCapViolationTakesTheDroppedBoatPath() async throws {
        var options = RaceHostOptions()
        options.caps.strikesToDisconnect = 1
        let rig = try await Rig(options: options)
        await rig.run(to: 30)
        let next = await rig.host.tick + 1
        for seq in 1...61 { await rig.send(held(Int8(seq)), seq: UInt32(seq), stamp: next) }
        #expect(await !rig.host.isAttached(seat: 0))
        // The applied inputs are stamped for the next tick, after the disconnect: the hold runs from them.
        await expectDrop(rig, holdFrom: next)
        let kinds = await rig.host.log.seatEvents.map(\.kind)
        #expect(kinds == [.joined(.human), .disconnected, .dropped, .botTookOver(.cautious)])
    }

    @Test func rejoinInsideTheHoldCancelsTheDrop() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: last + 10)
        #expect(await rig.host.attach(seat: 0, transport: RecordingTransport()))
        await rig.run(to: last + 60)
        #expect(await rig.host.controller(seat: 0).isHuman)
        let kinds = await rig.host.log.seatEvents.map(\.kind)
        #expect(kinds == [.joined(.human), .disconnected, .rejoined])
    }

    // MARK: Rejoin

    @Test func rejoinAfterTheGunTakesTheBoatBackWithAResync() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: last + 40)
        #expect(isDropped(await rig.host.controller(seat: 0)))

        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 0, transport: back))
        let rejoin = await rig.host.tick
        #expect(await rig.host.controller(seat: 0).isHuman)
        #expect(await rig.host.log.seatEvents.last == SeatEvent(tick: rejoin, seat: 0, kind: .rejoined))
        guard case .raceStart = back.frames.first?.message else {
            Issue.record("no RaceStart")
            return
        }
        #expect(hasResync(back))

        // From here only the player's inputs sail the boat.
        await rig.send(held(-50), seq: 1, stamp: rejoin + 1)
        await rig.run(to: rejoin + 12)
        let after = heldInputs(await rig.host.log).filter { $0.tick > rejoin }
        #expect(after.map(\.tick) == [rejoin + 1])
        #expect(after.map(\.input) == [BoatInput(rudder: -50 as Int8)])
        #expect(await rig.host.stats(seat: 0).applied == 1)
    }

    @Test func attachedSeatSendingAgainAfterItsDropTakesTheBoatBack() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await rig.run(to: last + 20)
        #expect(isDropped(await rig.host.controller(seat: 0)))
        #expect(!hasResync(rig.seat0))

        let now = await rig.host.tick
        await rig.send(held(-50), seq: 2, stamp: now + 1)
        #expect(await rig.host.controller(seat: 0).isHuman)
        #expect(await rig.host.log.seatEvents.last == SeatEvent(tick: now, seat: 0, kind: .rejoined))
        #expect(hasResync(rig.seat0))
    }

    // MARK: Leaving (#16, #35)

    @Test func leavingBeforeTheGunGivesTheSeatToAFleetBotWhereTheBoatIs() async throws {
        let rig = try await Rig()
        await rig.run(to: -200)
        let before = await rig.host.boat(seat: 0)
        #expect(await rig.host.leave(seat: 0))
        let after = await rig.host.boat(seat: 0)
        #expect(after.position == before.position)
        #expect(after.heading == before.heading)
        #expect(isFleetBot(await rig.host.controller(seat: 0)))
        #expect(rig.seat0.isClosed)
        #expect(await !rig.host.isAttached(seat: 0))
        #expect(await rig.host.log.seatEvents == [
            SeatEvent(tick: -300, seat: 0, kind: .joined(.human)),
            SeatEvent(tick: -200, seat: 0, kind: .leftBeforeGun),
            SeatEvent(tick: -200, seat: 0, kind: .botTookOver(.fleet)),
        ])

        // The bot sails on from there: no jump.
        await rig.run(to: -199)
        #expect((await rig.host.boat(seat: 0).position - before.position).length < 1)
        #expect(isFleetBot(await rig.host.controller(seat: 0)))
    }

    @Test func seatLeftBeforeTheGunCannotRejoin() async throws {
        let rig = try await Rig()
        await rig.run(to: -200)
        #expect(await rig.host.leave(seat: 0))
        let events = await rig.host.log.seatEvents
        await rig.run(to: -100)
        #expect(await !rig.host.attach(seat: 0, transport: RecordingTransport()))
        await rig.run(to: 30)
        #expect(await !rig.host.attach(seat: 0, transport: RecordingTransport()))
        #expect(await !rig.host.leave(seat: 0))
        #expect(await rig.host.log.seatEvents == events)
        #expect(isFleetBot(await rig.host.controller(seat: 0)))
    }

    @Test func seatDisconnectedBeforeTheGunWithoutLeavingMayRejoin() async throws {
        let rig = try await Rig()
        await rig.run(to: -200)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: -150)
        #expect(await rig.host.attach(seat: 0, transport: RecordingTransport()))
        #expect(await rig.host.controller(seat: 0).isHuman)
        #expect(await rig.host.log.seatEvents.last == SeatEvent(tick: -150, seat: 0, kind: .rejoined))
    }

    @Test func leavingAfterTheGunTakesTheDroppedBoatPathForGood() async throws {
        let rig = try await Rig()
        await rig.run(to: 30)
        let last = await rig.host.tick + 1
        await rig.send(held(60), seq: 1, stamp: last)
        await rig.run(to: last + 2)
        #expect(await rig.host.leave(seat: 0))
        #expect(rig.seat0.isClosed)
        await rig.run(to: last + 16)
        #expect(await rig.host.controller(seat: 0).isHuman)
        await rig.run(to: last + 17)
        #expect(isDropped(await rig.host.controller(seat: 0)))
        let log = await rig.host.log
        #expect(heldInputs(log).contains { $0.tick == last + 17 && $0.input == .neutral })
        #expect(log.seatEvents.map(\.kind) == [.joined(.human), .left, .botTookOver(.cautious)])
        #expect(await !rig.host.attach(seat: 0, transport: RecordingTransport()))
    }

    // MARK: All gone (G3)

    @Test func allGoneDefaultsAreG3s() {
        let options = RaceHostOptions()
        #expect(options.inputHoldTicks == 15)
        #expect(options.allGone.goneKinds == [.dropped, .left])
        #expect(options.allGone.graceTicks == 900)
        #expect(options.allGone.massDropWindowTicks == 60)
    }

    private func go(_ rig: Rig, seat: Int, _ way: GoneKind) async {
        switch way {
        case .dropped: await rig.host.disconnect(seat: seat)
        case .left: await rig.host.leave(seat: seat)
        }
    }

    /// Two humans go, seat 0 at tick 30 and seat 1 at 40, each way in turn. A disconnected seat is gone
    /// when its hold runs out 15 ticks later; a seat that leaves is gone at once.
    @Test(arguments: [[.dropped], [.left], [.dropped, .left]] as [Set<GoneKind>], [0, 90])
    func allGoneFiresAsConfigured(goneKinds: Set<GoneKind>, graceTicks: Int) async throws {
        let wayPairs: [[GoneKind]] = [[.dropped, .dropped], [.left, .left], [.dropped, .left], [.left, .dropped]]
        for ways in wayPairs {
            var options = RaceHostOptions()
            options.allGone.goneKinds = goneKinds
            options.allGone.graceTicks = graceTicks
            let rig = try await Rig(humans: 2, options: options)
            #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
            await rig.run(to: 30)
            await go(rig, seat: 0, ways[0])
            await rig.run(to: 40)
            await go(rig, seat: 1, ways[1])

            let goneAt = [ways[0] == .dropped ? 45 : 30, ways[1] == .dropped ? 55 : 40]
            let lastGone = max(goneAt[0], goneAt[1])
            if graceTicks > 0 {
                await rig.run(to: lastGone + graceTicks - 1)
                #expect(rig.allGones.isEmpty, "\(ways)")
            }
            await rig.run(to: lastGone + graceTicks + 30)
            if Set(ways).isSubset(of: goneKinds) {
                let order = goneAt[0] <= goneAt[1] ? [0, 1] : [1, 0]
                let expected = AllGone(tick: lastGone + graceTicks, leaveOrder: order,
                                       isMassDrop: ways == [.dropped, .dropped])
                #expect(rig.allGones == [expected], "\(ways)")
            } else {
                #expect(rig.allGones.isEmpty, "\(ways)")
            }
        }
    }

    @Test func rejoinDuringTheGraceCancelsTheTrigger() async throws {
        var options = RaceHostOptions()
        options.allGone.graceTicks = 90
        let rig = try await Rig(humans: 2, options: options)
        #expect(await rig.host.attach(seat: 1, transport: RecordingTransport()))
        await rig.run(to: 30)
        await rig.host.disconnect(seat: 1) // dropped at 45
        await rig.run(to: 40)
        await rig.host.disconnect(seat: 0) // dropped at 55: all gone, the grace runs to 145
        await rig.run(to: 100)
        #expect(await rig.host.attach(seat: 0, transport: RecordingTransport()))
        await rig.run(to: 200)
        #expect(rig.allGones.isEmpty)

        // Gone again, long after seat 1: not a mass drop, and seat 1 went first.
        await rig.host.disconnect(seat: 0) // dropped at 215
        await rig.run(to: 400)
        #expect(rig.allGones == [AllGone(tick: 305, leaveOrder: [1, 0], isMassDrop: false)])
    }
}
