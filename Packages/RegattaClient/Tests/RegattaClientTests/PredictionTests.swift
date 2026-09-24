import RegattaClient
import RegattaCore
import RegattaProtocol
import Testing

/// Full-fleet prediction against the scripted host over a faulty link (#64, ADR 0005).
@Suite struct PredictionTests {
    /// A scripted helm: a new rudder every 0.75 s from a fixed sequence, and a tack or gybe every 12 s.
    static func helm(_ h: Harness, now: UInt64, start: UInt64) {
        let elapsed = now - start
        let rudders: [Int8] = [0, 60, -40, 0, 127, 0, -90, 20, 0, -127, 45, 0]
        h.client.setHeld(BoatInput(rudder: rudders[Int(elapsed / 750_000) % rudders.count]))
        let tackEvery: UInt64 = 12_000_000
        if elapsed % tackEvery < 16_667, elapsed >= tackEvery { h.client.tap(.tackGybe, now: now) }
    }

    struct Errors {
        var ownErrors: [Double] = []
        var predictedTicks: [Int] = []
    }

    /// Sails a scripted run, recording the client's own boat as drawn each frame, then compares it with
    /// where the server had her at the same tick.
    static func sail(_ harness: Harness, seconds: UInt64) -> Errors {
        let start = harness.clock.now
        var drawn: [(tick: Int, position: Vec2)] = []
        harness.run(for: seconds * 1_000_000) { h, now in
            helm(h, now: now, start: start)
            let race = h.client.predicted.race
            if h.client.clock.isSynchronised { drawn.append((race.tick, race.boats[h.client.seat].position)) }
        }
        var errors = Errors()
        for (tick, position) in drawn {
            guard let server = harness.host.ownPosition(atTick: tick) else { continue }
            errors.ownErrors.append((position - server).length)
            errors.predictedTicks.append(tick)
        }
        return errors
    }

    /// The acceptance run: 150 ms round trip (65 ms + 0…20 ms jitter each way), 2 % loss both ways, a
    /// scripted 60 s: 20 s of the start sequence, the gun, and 40 s of racing. The client's own boat as drawn stays within one boat length
    /// (`Boat.length`, 4.2 m, the hull the core sails today) of where the server had her at that tick.
    /// Five link seeds, so five different sets of frames are lost.
    @Test(arguments: [150, 151, 152, 153, 154] as [UInt64])
    func ownBoatStaysWithinABoatLengthAt150msAnd2PercentLoss(seed: UInt64) throws {
        let faults = LinkFaults(delay: 65_000, jitter: 20_000, loss: 0.02)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: seed)
        let errors = Self.sail(harness, seconds: 60)
        let sorted = errors.ownErrors.sorted()
        let worst = sorted.last ?? .infinity
        let p99 = sorted.isEmpty ? .infinity : sorted[sorted.count * 99 / 100]
        let mean = sorted.reduce(0, +) / Double(max(sorted.count, 1))
        let stats = harness.client.stats
        print("PREDICTION seed \(seed) own-boat error over 60 s at 150 ms RTT, 2% loss: worst \(worst) m, p99 \(p99) m, mean \(mean) m, "
              + "\(sorted.count) frames; lost up \(harness.link.uplinkCounts.lost) down \(harness.link.downlinkCounts.lost); "
              + "resync requests \(stats.resyncRequests), applied \(stats.resyncsApplied); lead \(harness.client.lead.lead); "
              + "snapshots \(harness.client.predicted.snapshotsImported), stale \(harness.client.predicted.staleSnapshots)")
        #expect(sorted.count > 3000)
        #expect(worst < Boat.length)
        // The run crossed the gun and sailed on.
        #expect(harness.host.race.tick > 1100)
        #expect(errors.predictedTicks.last! > 1100)
        #expect(harness.link.uplinkCounts.lost > 0 && harness.link.downlinkCounts.lost > 0)
    }

    /// Reordered frames: stale snapshots are skipped and the reliable stream puts events and keys back
    /// in order, so the prediction and the event state stay the server's.
    @Test func reorderedFramesAreHandled() throws {
        let faults = LinkFaults(delay: 50_000, jitter: 40_000, loss: 0.02, reorder: 0.1, reorderDelay: 120_000)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: 9)
        let errors = Self.sail(harness, seconds: 60)
        let worst = errors.ownErrors.max() ?? .infinity
        let predicted = harness.client.predicted
        let stats = harness.client.stats
        print("PREDICTION reorder 10%, loss 2%: worst \(worst) m; stale snapshots \(predicted.staleSnapshots); "
              + "resync requests \(stats.resyncRequests), applied \(stats.resyncsApplied)")
        #expect(predicted.staleSnapshots > 0)
        #expect(worst < Boat.length)
        // Quiet the link and let the last frames land: the event state is the server's.
        harness.link.uplink = .none
        harness.link.downlink = .none
        harness.run(for: 1_000_000)
        let server = EventState(world: harness.host.race.exportSnapshot(), nextEventSeq: predicted.events.nextEventSeq)
        #expect(predicted.events == server)
        #expect(harness.client.status == .predicting)
    }

    /// The whole fleet is predicted: every boat, not just the client's, as drawn, stays close to where
    /// the server had her at that tick. Other boats' inputs after the snapshot are unknown to the client,
    /// so they drift until the next one; bots on this host change their helm every tick.
    @Test func everyBoatIsPredicted() throws {
        let faults = LinkFaults(delay: 40_000, jitter: 10_000)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: 3)
        var drawn: [(tick: Int, positions: [Vec2])] = []
        harness.run(for: 40_000_000) { h, _ in
            let race = h.client.predicted.race
            if h.client.clock.isSynchronised { drawn.append((race.tick, race.boats.map(\.position))) }
        }
        var worst = 0.0, total = 0.0, count = 0
        for (tick, positions) in drawn {
            guard let server = harness.host.positions[tick] else { continue }
            for seat in positions.indices where seat != harness.client.seat {
                let error = (positions[seat] - server[seat]).length
                worst = max(worst, error)
                total += error
                count += 1
            }
        }
        print("PREDICTION other boats: worst \(worst) m, mean \(total / Double(max(count, 1))) m over \(count) samples")
        #expect(count > 10_000)
        #expect(worst < Boat.length)
    }
}
