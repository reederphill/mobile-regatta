import Foundation
import Persistence
@testable import RegattaServerKit
import RegattaServices
import Testing

/// #147: the queue refuses a suspended player (with the end time, none for a permanent ban), a failed attestation, and a
/// cooldown (counting down to idle), read from the restriction store; in that order after the gate's refusals (Q4).
@Suite(.timeLimit(.minutes(1))) struct QueueRefusalTests {
    struct Rig {
        let clock = VirtualClock()
        let store = InMemoryRestrictionStore()
        let log = LaunchLog()
        let queue: QueueMatchmaker

        init() {
            let clock = clock, log = log
            queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, now: { clock.now }, restrictions: store,
                                    launch: { fleet, closed in try await log.record(fleet, closed) })
        }

        var unix: Int64 { Int64(clock.now.timeIntervalSince1970) }
    }

    static let player = QueueMatchmakerTests.player(0)

    @Test func suspendedPlayerIsRefusedWithTheEndTime() async throws {
        let rig = Rig()
        let until = rig.clock.now + 3600
        try await rig.store.setSuspension("T:0", StoredSuspension(until: until))
        let refusal = QueueRefusal.suspended(until: rig.unix + 3600)
        var states = rig.queue.stateUpdates(for: "T:0").makeAsyncIterator()
        #expect(await states.next() == .unavailable(refusal))
        await #expect(throws: QueueError.refused(refusal)) { try await rig.queue.join(Self.player) }
        // It ends on its own.
        rig.clock.advance(3600)
        await rig.queue.step()
        #expect(await states.next() == .idle)
        try await rig.queue.join(Self.player)
    }

    @Test func permanentSuspensionHasNoEnd() async throws {
        let rig = Rig()
        try await rig.store.setSuspension("T:0", .permanent)
        await #expect(throws: QueueError.refused(.suspended(until: nil))) { try await rig.queue.join(Self.player) }
        rig.clock.advance(365 * 86_400)
        await #expect(throws: QueueError.refused(.suspended(until: nil))) { try await rig.queue.join(Self.player) }
    }

    @Test func attestationFlagRefusesJoin() async throws {
        let rig = Rig()
        try await rig.store.setAttestationFailed("T:0", true)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await rig.queue.join(Self.player) }
        #expect(await rig.queue.state(of: "T:0") == .unavailable(.attestationFailed))
        try await rig.store.setAttestationFailed("T:0", false)
        try await rig.queue.join(Self.player)
    }

    @Test func cooldownCountsDownAndEndsIdle() async throws {
        let rig = Rig()
        try await rig.store.setCooldown("T:0", until: rig.clock.now + 3)
        var states = rig.queue.stateUpdates(for: "T:0").makeAsyncIterator()
        for seconds in [3, 2, 1] {
            #expect(await states.next() == .unavailable(.cooldown(secondsRemaining: seconds)))
            rig.clock.advance(1)
            await rig.queue.step()
        }
        #expect(await states.next() == .idle)
    }

    /// Q4: suspended, then attestation failed, then the cooldown. The gate's refusals (not signed in, multiplayer
    /// restricted, terms) come before all three, at the endpoint (`ServiceEndpoint.gate`, #145).
    @Test func refusalOrder() async throws {
        let rig = Rig()
        try await rig.store.setCooldown("T:0", until: rig.clock.now + 60)
        try await rig.store.setAttestationFailed("T:0", true)
        try await rig.store.setSuspension("T:0", .permanent)
        await #expect(throws: QueueError.refused(.suspended(until: nil))) { try await rig.queue.join(Self.player) }
        try await rig.store.setSuspension("T:0", nil)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await rig.queue.join(Self.player) }
        try await rig.store.setAttestationFailed("T:0", false)
        await #expect(throws: QueueError.refused(.cooldown(secondsRemaining: 60))) { try await rig.queue.join(Self.player) }
    }

    /// A suspension or flag set while she is queued takes her out of the queue, and she is shown why.
    @Test func aSuspensionWhileQueuedRemovesHer() async throws {
        let rig = Rig()
        try await rig.queue.join(Self.player)
        try await rig.queue.join(QueueMatchmakerTests.player(1))
        var states = rig.queue.stateUpdates(for: "T:0").makeAsyncIterator()
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 2, secondsToLock: 60)))
        try await rig.store.setSuspension("T:0", .permanent)
        await rig.queue.step()
        #expect(await states.next() == .unavailable(.suspended(until: nil)))
        #expect(await rig.queue.queuedCount == 1)
        // A writer that says so (#153, #158) takes effect at once.
        try await rig.store.setAttestationFailed("T:1", true)
        await rig.queue.restrictionsChanged("T:1")
        #expect(await rig.queue.queuedCount == 0)
    }

    // MARK: The restrictions cache (#469)

    /// #469: a stream re-reads her restrictions when it opens: a suspension written since her last read, which nobody
    /// told the queue of, shows in its first state.
    @Test func watchingReadsHerRestrictionsAfresh() async throws {
        let rig = Rig()
        try await rig.queue.join(Self.player)
        try await rig.store.setSuspension("T:0", .permanent)
        var states = rig.queue.stateUpdates(for: "T:0").makeAsyncIterator()
        #expect(await states.next() == .unavailable(.suspended(until: nil)))
    }

    /// #469: the queue keeps a player's restrictions only while she is queued, locked or watching.
    @Test func restrictionsAreKeptOnlyForPlayersQueuedLockedOrWatching() async throws {
        let rig = Rig()
        // Refused, asked about, changed: with nobody watching, nothing is kept.
        try await rig.store.setAttestationFailed("T:9", true)
        await #expect(throws: QueueError.refused(.attestationFailed)) { try await rig.queue.join(QueueMatchmakerTests.player(9)) }
        #expect(await rig.queue.state(of: "T:9") == .unavailable(.attestationFailed))
        await rig.queue.restrictionsChanged("T:9")
        #expect(await rig.queue.cachedRestrictions == 0)
        // Queued: kept. Left: gone.
        try await rig.queue.join(Self.player)
        #expect(await rig.queue.cachedRestrictions == 1)
        try await rig.queue.leave("T:0")
        #expect(await rig.queue.cachedRestrictions == 0)
        // Watching: kept, through a join and a leave, until her stream ends.
        do {
            let stream = rig.queue.stateUpdates(for: "T:0")
            var states = stream.makeAsyncIterator()
            #expect(await states.next() == .idle)
            try await rig.queue.join(Self.player)
            try await rig.queue.leave("T:0")
            #expect(await rig.queue.cachedRestrictions == 1)
            withExtendedLifetime(stream) {}
        }
        #expect(!rig.queue.watchers.isWatched("T:0"))
        #expect(await eventually { await rig.queue.cachedRestrictions == 0 })
        // Locked: kept until her race closes.
        try await rig.queue.join(Self.player)
        rig.clock.advance(60)
        await rig.queue.step()
        #expect(await rig.queue.state(of: "T:0") == .fleetLocked)
        #expect(await rig.queue.cachedRestrictions == 1)
        await rig.log.close(try #require(await rig.log.fleets.first).raceID)
        #expect(await eventually { await rig.queue.cachedRestrictions == 0 })
    }

    /// #469: a stream dropped as soon as it is opened leaves no watcher (its removal can't come before its
    /// registration) and nothing cached.
    @Test func aStreamDroppedAtOnceLeavesNoWatcher() async throws {
        let rig = Rig()
        for _ in 0..<200 { _ = rig.queue.stateUpdates(for: "T:0") }
        #expect(!rig.queue.watchers.isWatched("T:0"))
        await rig.queue.step()
        #expect(await eventually { await rig.queue.cachedRestrictions == 0 })
        #expect(rig.queue.watchers.keys.isEmpty)
    }
}
