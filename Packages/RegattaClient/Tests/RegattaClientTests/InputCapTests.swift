import RegattaClient
import RegattaCore
import RegattaProtocol
import Testing

/// The input caps (#26): the client never sends more than 60 held-input messages or 5 taps in any
/// second, however hard the player works the helm.
@Suite struct InputCapTests {
    /// A noisy scripted steerer: a new rudder every frame from a seeded stream, at 120 frames a second,
    /// and a tap on 40 % of frames. The sends are counted over every sliding one-second window, as the
    /// client sent them and as the host received them.
    @Test(arguments: [8_334, 16_667] as [UInt64])
    func aNoisySteererNeverExceedsTheCaps(frameEvery: UInt64) throws {
        let faults = LinkFaults(delay: 60_000, jitter: 80_000)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: 26)
        var noise = SplitMix64(seed: 26, stream: 0x6E6F_6973_65)
        var taps = 0
        harness.run(for: 30_000_000, frameEvery: frameEvery) { h, now in
            h.client.setHeld(BoatInput(rudder: Int8(truncatingIfNeeded: Int(noise.int(in: -127...127)))))
            if noise.unit() < 0.4 {
                h.client.tap(noise.bool() ? .tackGybe : .protest(target: 1 + Int(noise.int(in: 0...6))), now: now)
                taps += 1
            }
        }
        let held = harness.maxSends(of: [.inputHeld])
        let tapped = harness.maxSends(of: [.inputTap])
        let heldArrived = harness.maxArrivals(taps: false)
        let tapsArrived = harness.maxArrivals(taps: true)
        let stats = harness.client.stats
        print("CAPS frame=\(frameEvery)µs: max held/s sent \(held) arrived \(heldArrived); max taps/s sent \(tapped) arrived "
              + "\(tapsArrived); tapped \(taps), sent \(stats.tapsSent), refused \(stats.tapsRefused); held sent \(stats.heldSent)")
        #expect(held <= 60 && heldArrived <= 60)
        #expect(tapped <= 5 && tapsArrived <= 5)
        // It still sends as much as it may: a held input every tick and taps up to the cap.
        #expect(held >= 25)
        #expect(tapped >= 4)
        #expect(stats.tapsRefused > 0)
    }

    /// The limiter itself, at the cap exactly: 60 held messages go in a second, the 61st waits, and a
    /// change that waited goes out with its latest value once there is room.
    @Test func heldChangesWaitForRoomAndAreNeverLost() {
        var limits = InputLimits()
        limits.guardBand = 0
        var stamper = InputStamper(limits: limits)
        var sent: [(time: UInt64, input: BoatInput)] = []
        // A change every 5 ms, each stamped for a new tick, for 2 s.
        for i in 0..<400 {
            let now = UInt64(i) * 5_000
            stamper.setHeld(BoatInput(rudder: Int8(i % 100)))
            for out in stamper.outgoing(now: now, tick: i) {
                if case .held(let input) = out.kind { sent.append((now, input)) }
            }
        }
        var most = 0, first = 0
        for last in sent.indices {
            while sent[last].time - sent[first].time >= 1_000_000 { first += 1 }
            most = max(most, last - first + 1)
        }
        #expect(most == 60)
        #expect(sent.count == 120)
        // At 2 s, room again: the latest value goes.
        let later = stamper.outgoing(now: 2_000_000, tick: 400)
        #expect(later.map(\.kind) == [.held(BoatInput(rudder: Int8(399 % 100)))])
    }

    /// Heartbeats: a steady helm still sends its held input every 200 ms, and only then.
    @Test func aSteadyHelmSendsAHeartbeat() {
        var stamper = InputStamper()
        var times: [UInt64] = []
        for i in 0..<300 {
            let now = UInt64(i) * 10_000
            if !stamper.outgoing(now: now, tick: i).isEmpty { times.append(now) }
        }
        #expect(times == stride(from: 0, to: 3_000_000, by: 200_000).map { UInt64($0) })
    }
}
