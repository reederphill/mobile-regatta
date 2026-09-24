import RegattaClient
import Testing

/// The fault-injecting link: delay, jitter, loss, reorder and disconnect, all from its seed.
@Suite struct FaultInjectingLinkTests {
    /// Sends `count` one-byte frames on the uplink, one a millisecond, and returns (sent index,
    /// arrival time) for each arrival, running the clock to `until`.
    static func trace(_ link: FaultInjectingLink, count: Int = 2000, until: UInt64 = 5_000_000) -> [(index: Int, at: UInt64)] {
        let clock = link.clock
        let start = clock.now
        var arrivals: [(Int, UInt64)] = []
        var sent = 0
        while clock.now - start < until {
            if sent < count {
                link.client.send([UInt8(truncatingIfNeeded: sent), UInt8(truncatingIfNeeded: sent >> 8)])
                sent += 1
            }
            clock.advance(by: 1000)
            for frame in link.server.receive() { arrivals.append((Int(frame[0]) | Int(frame[1]) << 8, clock.now)) }
        }
        return arrivals
    }

    @Test func theSameSeedGivesTheSameFaults() {
        let faults = LinkFaults(delay: 30_000, jitter: 20_000, loss: 0.1, reorder: 0.05, reorderDelay: 50_000)
        let a = Self.trace(FaultInjectingLink(clock: VirtualClock(), uplink: faults, seed: 1))
        let b = Self.trace(FaultInjectingLink(clock: VirtualClock(), uplink: faults, seed: 1))
        let c = Self.trace(FaultInjectingLink(clock: VirtualClock(), uplink: faults, seed: 2))
        #expect(a.map(\.index) == b.map(\.index) && a.map(\.at) == b.map(\.at))
        #expect(a.map(\.index) != c.map(\.index))
    }

    @Test func delayAndJitterStayInTheirBounds() {
        let link = FaultInjectingLink(clock: VirtualClock(), uplink: LinkFaults(delay: 30_000, jitter: 20_000), seed: 3)
        let arrivals = Self.trace(link)
        #expect(arrivals.count == 2000)
        // Sent at index ms after the start, seen at the first whole millisecond at or after arrival.
        let delays = arrivals.map { Int($0.at) - $0.index * 1000 }
        #expect(delays.min()! >= 30_000 && delays.max()! <= 51_000)
        #expect(delays.max()! - delays.min()! > 15_000)
        // Jitter of more than the send spacing reorders frames.
        #expect(arrivals.map(\.index) != arrivals.map(\.index).sorted())
    }

    @Test func lossIsAboutItsRate() {
        let link = FaultInjectingLink(clock: VirtualClock(), uplink: LinkFaults(delay: 1000, loss: 0.02), seed: 4)
        let arrivals = Self.trace(link, count: 5000, until: 6_000_000)
        let lost = 5000 - arrivals.count
        #expect(lost == link.uplinkCounts.lost)
        #expect((60...140).contains(lost))
    }

    @Test func reorderHoldsFramesBackAndInOrderPreservesOrder() {
        let reordering = FaultInjectingLink(clock: VirtualClock(), uplink: LinkFaults(delay: 1000, reorder: 0.1, reorderDelay: 20_000), seed: 5)
        let a = Self.trace(reordering).map(\.index)
        #expect(a != a.sorted() && a.count == 2000)
        let tcp = FaultInjectingLink(clock: VirtualClock(), uplink: LinkFaults(delay: 1000, jitter: 30_000, reorder: 0.1,
                                                                               reorderDelay: 20_000, inOrder: true), seed: 5)
        let b = Self.trace(tcp).map(\.index)
        #expect(b == Array(0..<2000))
    }

    @Test func aDisconnectLosesWhatIsInFlightAndOldEndsStayClosed() {
        let clock = VirtualClock()
        let link = FaultInjectingLink(clock: clock, uplink: LinkFaults(delay: 10_000), seed: 6)
        let oldClient = link.client!
        oldClient.send([1])
        link.disconnect()
        #expect(!oldClient.isConnected)
        oldClient.send([2])
        clock.advance(by: 20_000)
        #expect(link.server.receive().isEmpty)
        link.reconnect()
        #expect(!oldClient.isConnected && link.client.isConnected)
        oldClient.send([3])
        link.client.send([4])
        clock.advance(by: 20_000)
        #expect(link.server.receive() == [[4]])
    }
}
