import RegattaClient
import RegattaCore
import RegattaProtocol
import Testing

/// The adaptive lead (#64 acceptance): it converges within 2 s to the one-way latency plus the jitter,
/// and never exceeds 30 ticks.
///
/// Lead is ticks ahead of the estimated server tick (`LeadController`). The link's one-way delay is a
/// fixed `delay` plus a uniform 0…`jitter` per frame, both ways, so "latency + jitter" is
/// `(delay + jitter) / tick`, and the lead's target adds the one tick an input needs to land before its
/// tick is simulated (`LeadController`): `(delay + jitter) / tick + 1`.
@Suite struct LeadTests {
    struct Trace {
        var times: [UInt64] = []
        var leads: [Double] = []
        /// Estimated minus true server tick.
        var clockErrors: [Double] = []
    }

    static func sail(delay: UInt64, jitter: UInt64, seconds: UInt64, seed: UInt64 = 7) throws -> (Harness, Trace) {
        let faults = LinkFaults(delay: delay, jitter: jitter)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: seed)
        var trace = Trace()
        let start = harness.clock.now
        harness.run(for: seconds * 1_000_000) { h, now in
            // A helm that moves every half second, so held inputs flow as well as heartbeats.
            let step = Int((now - start) / 500_000)
            h.client.setHeld(BoatInput(rudder: Int8(truncatingIfNeeded: (step % 5 - 2) * 20)))
            guard let estimate = h.client.clock.serverTick(at: now) else { return }
            trace.times.append(now - start)
            trace.leads.append(h.client.lead.lead)
            trace.clockErrors.append(estimate - h.host.serverTick(at: now))
        }
        return (harness, trace)
    }

    /// The time after which the lead stays within `tolerance` of `target` to the end of the run.
    static func convergence(_ trace: Trace, target: Double, tolerance: Double) -> UInt64? {
        guard let last = trace.leads.indices.last(where: { abs(trace.leads[$0] - target) > tolerance }) else {
            return trace.times.first
        }
        return last + 1 < trace.times.count ? trace.times[last + 1] : nil
    }

    @Test(arguments: [(75_000, 30_000), (40_000, 10_000), (200_000, 60_000), (120_000, 100_000)] as [(UInt64, UInt64)])
    func leadConvergesWithinTwoSecondsToLatencyPlusJitter(delay: UInt64, jitter: UInt64) throws {
        let (harness, trace) = try Self.sail(delay: delay, jitter: jitter, seconds: 20)
        let target = Double(delay + jitter) / ClockSync.tickMicros + 1
        let converged = try #require(Self.convergence(trace, target: target, tolerance: 1))
        let afterTwo = trace.times.indices.filter { trace.times[$0] >= 2_000_000 }
        let worstClock = afterTwo.map { abs(trace.clockErrors[$0]) }.max() ?? 0
        let late = harness.host.arrivals.filter { $0.time >= harness.clock.now - 18_000_000 && $0.margin < 0 }.count
        let arrivals = harness.host.arrivals.filter { $0.time >= harness.clock.now - 18_000_000 }.count
        let maxLead = trace.leads.max() ?? 0
        print("LEAD delay=\(delay / 1000)ms jitter=\(jitter / 1000)ms target=\(target) converged=\(Double(converged) / 1e6)s "
              + "final=\(trace.leads.last ?? 0) max=\(maxLead) worstClockError=\(worstClock) late=\(late)/\(arrivals) "
              + "resyncRequests=\(harness.client.stats.resyncRequests) refused=\(harness.client.stats.snapshotsRefused)")
        #expect(converged <= 2_000_000)
        #expect(maxLead <= LeadController.maxLead)
        #expect(worstClock <= 0.75)
        // Once converged, inputs arrive in time.
        #expect(Double(late) <= 0.01 * Double(arrivals))
        #expect(harness.host.rejected == 0)
    }

    /// Past a second of latency the lead stops at 30 ticks: the server would reject inputs further ahead.
    @Test(arguments: [1_200_000, 3_000_000] as [UInt64])
    func leadNeverExceedsThirtyTicks(delay: UInt64) throws {
        let (harness, trace) = try Self.sail(delay: delay, jitter: 50_000, seconds: 20)
        let maxLead = trace.leads.max() ?? 0
        print("LEAD delay=\(delay / 1000)ms capped: max=\(maxLead) final=\(trace.leads.last ?? 0) rejected=\(harness.host.rejected)")
        #expect(maxLead <= LeadController.maxLead)
        #expect(trace.leads.last == LeadController.maxLead)
        let margins = harness.host.arrivals.map(\.margin)
        #expect(margins.allSatisfy { $0 <= 30 })
        #expect(harness.host.rejected == 0)
    }
}

/// The lead controller on its own: the target, the server's late feedback, and the cap.
@Suite struct LeadControllerTests {
    static let tick = ClockSync.tickMicros

    @Test func aSteadyUplinkGivesItsDelayPlusOneTick() {
        var lead = LeadController()
        lead.update(uplinkDelays: Array(repeating: 5 * Self.tick, count: 10), now: 0)
        #expect(abs(lead.lead - 6) < 1e-9)
    }

    /// A late input raises the lead by the ticks it was late, once per holdoff; with no more late inputs
    /// for 2 s the raise decays at half a tick a second.
    @Test func lateFeedbackRaisesTheLeadThenDecays() {
        var lead = LeadController()
        let delays = Array(repeating: 5 * Self.tick, count: 10)
        lead.update(uplinkDelays: delays, now: 0)
        lead.feedback(margin: -3, now: 10_000)
        lead.feedback(margin: -2, now: 100_000) // in flight with the old lead: ignored
        lead.update(uplinkDelays: delays, now: 100_000)
        #expect(abs(lead.lead - 9) < 1e-9)
        #expect(lead.lateInputs == 2)
        lead.feedback(margin: 4, now: 200_000) // early: nothing to do
        var now: UInt64 = 100_000
        while now < 2_010_000 {
            now += 10_000
            lead.update(uplinkDelays: delays, now: now)
        }
        #expect(abs(lead.lead - 9) < 1e-9) // still within 2 s of the last late input
        while now < 4_010_000 {
            now += 10_000
            lead.update(uplinkDelays: delays, now: now)
        }
        #expect(abs(lead.lead - 8) < 0.05)
        while now < 12_000_000 {
            now += 10_000
            lead.update(uplinkDelays: delays, now: now)
        }
        #expect(abs(lead.lead - 6) < 1e-9)
    }

    /// The lead falls at most 8 ticks a second when the link gets faster, and never passes 30 ticks.
    @Test func itFallsGentlyAndNeverPassesTheCap() {
        var lead = LeadController()
        lead.update(uplinkDelays: [60 * Self.tick], now: 0)
        #expect(lead.lead == 30)
        lead.feedback(margin: -100, now: 0)
        lead.update(uplinkDelays: [60 * Self.tick], now: 10_000)
        #expect(lead.lead == 30 && lead.feedback == lead.maxFeedback)
        lead.update(uplinkDelays: [2 * Self.tick], now: 510_000)
        #expect(abs(lead.lead - 26) < 1e-9)
    }
}
