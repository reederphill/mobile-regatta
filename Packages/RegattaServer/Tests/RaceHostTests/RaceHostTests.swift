import Foundation
import RaceHost
import RegattaCore
import RegattaProtocol
import Testing

/// The host on a virtual clock (#65): scheduler, input buffer, caps, snapshots and events.
struct RaceHostTests {
    private func held(_ rudder: Int8) -> Message { .inputHeld(BoatInput(rudder: rudder)) }

    private func heldRecords(_ log: RaceLog, seat: Int = 0) -> [(tick: Int, rudder: Int8)] {
        log.inputs.compactMap { record in
            guard record.seat == seat, case .held(let input) = record.kind else { return nil }
            return (record.tick, input.rudder)
        }
    }

    // MARK: Scheduler

    @Test func advanceSimulatesEveryTickDueAndNoMore() async throws {
        let rig = try await Rig()
        let start = await rig.host.tick
        rig.clock.set(await rig.host.time(ofTick: start + 10) - 1)
        await rig.host.advance()
        #expect(await rig.host.tick == start + 9)
        rig.clock.advance(by: 1)
        await rig.host.advance()
        #expect(await rig.host.tick == start + 10)
        #expect(rig.behindAlerts.isEmpty)
    }

    @Test func behindMoreThanOneSecondAlertsAndCatchesUpInOneCall() async throws {
        let rig = try await Rig()
        let start = await rig.host.tick
        rig.clock.advance(by: 1_000_000) // exactly 30 ticks: not more than 1 s behind
        await rig.host.advance()
        #expect(rig.behindAlerts.isEmpty)
        #expect(await rig.host.tick == start + 30)

        rig.clock.advance(by: 2_000_000)
        await rig.host.advance()
        #expect(rig.behindAlerts == [60])
        #expect(await rig.host.tick == start + 90)
    }

    // MARK: Input buffer (#18, ADR 0005)

    @Test func lateInputLandsNextTickAndIsLoggedThere() async throws {
        let rig = try await Rig()
        await rig.run(to: -200)
        // Stamped for a tick already simulated: applies at the next one.
        await rig.send(held(50), seq: 1, stamp: -200)
        // On time: applies at its stamp.
        await rig.send(held(70), seq: 2, stamp: -195)
        await rig.run(to: -190)

        let records = heldRecords(await rig.host.log)
        #expect(records.map(\.tick) == [-199, -195])
        #expect(records.map(\.rudder) == [50, 70])
        #expect(await rig.host.stats(seat: 0).applied == 2)
    }

    @Test func inputThirtyOneTicksAheadIsRejectedAndThirtyIsNot() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let next = await rig.host.tick + 1
        await rig.send(held(31), seq: 1, stamp: next + 31)
        await rig.send(held(30), seq: 2, stamp: next + 30)
        await rig.run(to: next + 40)

        let stats = await rig.host.stats(seat: 0)
        #expect(stats.rejectedAhead == 1)
        #expect(stats.applied == 1)
        let records = heldRecords(await rig.host.log)
        #expect(records.map(\.tick) == [next + 30])
        #expect(records.map(\.rudder) == [30])
    }

    @Test func outOfRangeInputsAreRejected() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let next = await rig.host.tick + 1
        await rig.send(.inputTap(.protest(target: 0)), seq: 1, stamp: next)  // itself
        await rig.send(.inputTap(.protest(target: 40)), seq: 2, stamp: next) // no such seat
        #expect(await rig.host.stats(seat: 0).rejectedRange == 2)
    }

    @Test func olderHeldInputThanOneAppliedIsDropped() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let next = await rig.host.tick + 1
        await rig.send(held(20), seq: 5, stamp: next)
        await rig.send(held(10), seq: 4, stamp: next + 1)
        await rig.run(to: next + 5)
        #expect(await rig.host.stats(seat: 0).stale == 1)
        #expect(heldRecords(await rig.host.log).map(\.rudder) == [20])
    }

    // MARK: Caps (#26)

    @Test func sixtyFirstHeldMessageInASecondIsDropped() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let next = await rig.host.tick + 1
        for seq in 1...60 { await rig.send(held(Int8(seq)), seq: UInt32(seq), stamp: next) }
        // The 61st, within the same second, stamped where nothing else would hide it.
        await rig.send(held(-99), seq: 61, stamp: next + 5)
        await rig.run(to: next + 10)

        var stats = await rig.host.stats(seat: 0)
        #expect(stats.applied == 60)
        #expect(stats.heldDropped == 1)
        #expect(!heldRecords(await rig.host.log).contains { $0.rudder == -99 })

        // A second after the first 60 the window has room again.
        rig.clock.set(await rig.host.time(ofTick: next + 31) + 1_000_000)
        await rig.send(held(-99), seq: 62, stamp: await rig.host.tick + 1)
        stats = await rig.host.stats(seat: 0)
        #expect(stats.applied == 61)
        #expect(stats.heldDropped == 1)
        #expect(await rig.host.isAttached(seat: 0))
    }

    @Test func sixthTapInASecondIsDropped() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let next = await rig.host.tick + 1
        for seq in 1...6 { await rig.send(.inputTap(.tackGybe), seq: UInt32(seq), stamp: next) }
        await rig.run(to: next + 2)

        let stats = await rig.host.stats(seat: 0)
        #expect(stats.applied == 5)
        #expect(stats.tapsDropped == 1)
        let taps = await rig.host.log.inputs.filter { $0.seat == 0 && $0.kind == .tap(.tackGybe) }
        #expect(taps.count == 5)
        #expect(taps.allSatisfy { $0.tick == next })
    }

    @Test func repeatedCapViolationDisconnects() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        var seq: UInt32 = 0
        for round in 1...3 {
            let next = await rig.host.tick + 1
            for _ in 1...61 {
                seq += 1
                await rig.send(held(Int8(seq % 100)), seq: seq, stamp: next)
            }
            #expect(await rig.host.isAttached(seat: 0) == (round < 3))
            rig.clock.advance(by: 1_100_000)
        }
        #expect(rig.seat0.isClosed)
        #expect(await rig.host.stats(seat: 0).heldDropped == 3)
        #expect(await rig.host.log.seatEvents.contains { $0.seat == 0 && $0.kind == .disconnected })
        // A disconnected seat's frames go nowhere.
        await rig.send(held(1), seq: seq + 1, stamp: await rig.host.tick + 1)
        #expect(await rig.host.stats(seat: 0).applied == 180)
    }

    // MARK: Snapshots and events

    @Test func snapshotsGoEveryThirdTickByDefault() async throws {
        let rig = try await Rig()
        await rig.run(to: -291)
        #expect(rig.seat0.snapshotTicks == [-297, -294, -291])
    }

    @Test func snapshotIntervalIsConfigurable() async throws {
        var options = RaceHostOptions()
        options.snapshotEvery = 5
        let rig = try await Rig(options: options)
        await rig.run(to: -285)
        #expect(rig.seat0.snapshotTicks == [-295, -290, -285])
    }

    @Test func snapshotAcksTheLatestAppliedInput() async throws {
        let rig = try await Rig()
        await rig.run(to: -297)
        await rig.send(held(40), seq: 7, stamp: -296)
        await rig.run(to: -294)
        let snapshot = rig.seat0.frames.last { if case .snapshot = $0.message { true } else { false } }
        guard case .snapshot(let last) = snapshot?.message else { Issue.record("no snapshot"); return }
        #expect(last.ack == InputAck(seq: 7, appliedTick: -296, margin: 0))
    }

    @Test func syntheticTargetedEventReachesOnlyItsRecipientSeat() async throws {
        let rig = try await Rig(humans: 3)
        let seat1 = RecordingTransport()
        let seat2 = RecordingTransport()
        #expect(await rig.host.attach(seat: 1, transport: seat1))
        #expect(await rig.host.attach(seat: 2, transport: seat2))
        await rig.run(to: -250)

        // The recall notice goes to the boat that is over only (#9).
        await rig.host.sendEvent(.ocs(seat: 2), to: .seats([2]))
        #expect(seat2.events.map(\.kind) == [.ocs(seat: 2)])
        #expect(seat1.events.isEmpty)
        #expect(rig.seat0.events.isEmpty)

        // A broadcast reaches everyone.
        await rig.host.sendEvent(.gun, to: .everyone)
        for transport in [rig.seat0, seat1, seat2] { #expect(transport.events.last?.kind == .gun) }
        // Each seat's reliable stream is numbered on its own, from 1.
        #expect(seat2.frames.filter { $0.raceEvent != nil }.map(\.seq) == [1, 2])
        #expect(seat1.frames.filter { $0.raceEvent != nil }.map(\.seq) == [1])
    }

    @Test func attachSendsRaceStartAndRefusesBotSeats() async throws {
        let rig = try await Rig()
        guard case .raceStart(let start) = rig.seat0.frames.first?.message else {
            Issue.record("no RaceStart")
            return
        }
        #expect(start.yourSeat == 0)
        #expect(start.setup == rig.setup)
        #expect(await !rig.host.attach(seat: 1, transport: RecordingTransport()))
        #expect(await rig.host.log.seatEvents == [SeatEvent(tick: -300, seat: 0, kind: .joined(.human))])
    }

    @Test func windKeyRevealHookSendsKeysOnTheReliableStream() async throws {
        let clock = VirtualClock()
        let setup = try RaceSetup(raceSeed: RaceSeed(65), seats: [.human, .bot], laps: 1, startSequenceTicks: 300)
        // The hook's keys go out as they are: #95 decides which and when.
        let key = WindKey(window: 3, shift: WindKnot(value: 0.1, slope: 0), strength: WindKnot(value: 1, slope: 0),
                          wobble: WindWobble(hump: 0, wiggle: 0), puffSeed: 7)
        let host = RaceHost(setup: setup, windSeed: WindSeed(0x65), clock: clock,
                            windKeyReveal: { tick in tick == -290 ? [key] : [] })
        let transport = RecordingTransport()
        await host.attach(seat: 0, transport: transport)
        clock.set(await host.time(ofTick: -280))
        await host.advance()
        #expect(await host.revealedWindKeys == [key])
        let keyFrames = transport.frames.filter { if case .windKey = $0.message { true } else { false } }
        #expect(keyFrames.map(\.tick) == [-290])
        #expect(keyFrames.map(\.message) == [.windKey(key)])
    }

    // MARK: Close and replay (#59, ADR 0002)

    @Test func closeSendsRaceClosedAndStopsTheRace() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        let outcome = await rig.host.close()
        #expect(outcome.log.finalTick == -250)
        #expect(outcome.standings.sorted() == [0, 1, 2, 3])
        #expect(rig.seat0.frames.last?.message == .raceClosed(RaceClosed(results: .none)))
        await rig.run(to: -200)
        #expect(await rig.host.tick == -250)
        #expect(await rig.host.close() == outcome)
    }

    @Test func producedRaceLogReplaysInANewProcessToTheResultDigest() async throws {
        let rig = try await Rig(startSequenceTicks: 150)
        await rig.run(to: -120)
        await rig.send(held(60), seq: 1, stamp: -120) // late: applies at -119
        await rig.send(.inputTap(.tackGybe), seq: 2, stamp: -100)
        await rig.run(to: -60)
        await rig.send(held(-40), seq: 3, stamp: -55)
        await rig.send(.inputTap(.protest(target: 2)), seq: 4, stamp: -50)
        await rig.run(to: 20)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: 450)
        let outcome = await rig.host.close()

        // Bots sail through the input API, so their inputs are in the log beside the player's.
        let log = outcome.log
        #expect(Set(log.inputs.map(\.seat)) == [0, 1, 2, 3])
        #expect(log.inputs.contains(InputRecord(tick: -119, seat: 0, kind: .held(BoatInput(rudder: 60 as Int8)))))
        #expect(log.seatEvents.map(\.kind) == [.joined(.human), .disconnected])
        #expect(try Replayer.digest(of: log) == outcome.digest)

        #if os(macOS) || os(Linux)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("racehost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("race-log.json")
        try log.jsonData().write(to: file)

        let executable = try #require(replayExecutable(), "regatta-replay not found next to the test bundle")
        let process = Process()
        process.executableURL = executable
        process.arguments = [file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(printed.trimmingCharacters(in: .whitespacesAndNewlines) == hex64(outcome.digest))
        #endif
    }
}

#if os(macOS) || os(Linux)
private final class BundleMarker {}

/// SwiftPM builds `regatta-replay` into the same products directory as the test bundle.
private func replayExecutable() -> URL? {
    var directories: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        directories.append(bundle.bundleURL.deletingLastPathComponent())
    }
    let marker = Bundle(for: BundleMarker.self).bundleURL
    directories.append(marker.pathExtension == "xctest" ? marker.deletingLastPathComponent() : marker)
    directories.append(Bundle.main.bundleURL)
    directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    return directories.lazy
        .map { $0.appendingPathComponent("regatta-replay") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
#endif
