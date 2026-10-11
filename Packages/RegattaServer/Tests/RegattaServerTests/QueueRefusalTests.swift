import Foundation
import Persistence
@testable import RegattaServerKit
import RegattaServices
import Synchronization
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

    // MARK: Reading the store (#469)

    /// A restriction store that can fail or hang, and counts its reads.
    final class FaultyStore: RestrictionStore {
        struct Unreachable: Error {}
        /// `hangingOnceAfterReading`: the next read of one player's restrictions reads them, then hangs with what it
        /// read (a slow answer, stale by the time it arrives).
        enum Fault { case none, failing, hanging, hangingOnceAfterReading }

        let inner = InMemoryRestrictionStore()
        private let state = Mutex<(fault: Fault, single: Int, batch: Int, hung: [CheckedContinuation<Void, Never>])>((.none, 0, 0, []))

        var fault: Fault {
            get { state.withLock { $0.fault } }
            set { state.withLock { $0.fault = newValue } }
        }
        var reads: (single: Int, batch: Int) { state.withLock { ($0.single, $0.batch) } }

        /// Lets every hung read go, and reads answer again.
        func release() {
            let hung = state.withLock { state in
                defer { state.hung = [] }
                if state.fault == .hangingOnceAfterReading { state.fault = .none }
                return state.hung
            }
            for continuation in hung { continuation.resume() }
        }

        /// A hung read doesn't notice being cancelled, as a call stuck in a dead connection doesn't.
        private func read() async throws {
            switch fault {
            case .none: return
            case .failing: throw Unreachable()
            case .hanging, .hangingOnceAfterReading: await withCheckedContinuation { continuation in state.withLock { $0.hung.append(continuation) } }
            }
        }

        func restrictions(of playerID: String) async throws -> PlayerRestrictions {
            let stale = state.withLock { state -> Bool in
                state.single += 1
                return state.fault == .hangingOnceAfterReading
            }
            if stale {
                let restrictions = try await inner.restrictions(of: playerID)
                try await read()
                return restrictions
            }
            try await read()
            return try await inner.restrictions(of: playerID)
        }

        func restrictions(of playerIDs: [String]) async throws -> [String: PlayerRestrictions] {
            state.withLock { $0.batch += 1 }
            try await read()
            return try await inner.restrictions(of: playerIDs)
        }

        func briefingLeaves(of playerID: String, since: Date) async throws -> [Date] { try await inner.briefingLeaves(of: playerID, since: since) }
        func recordBriefingLeave(_ playerID: String, race: UUID?, at time: Date) async throws {
            try await inner.recordBriefingLeave(playerID, race: race, at: time)
        }
        func clearBriefingLeaves(of playerID: String) async throws { try await inner.clearBriefingLeaves(of: playerID) }
        func setCooldown(_ playerID: String, until: Date?) async throws { try await inner.setCooldown(playerID, until: until) }
        func setSuspension(_ playerID: String, _ suspension: StoredSuspension?) async throws { try await inner.setSuspension(playerID, suspension) }
        func setAttestationFailed(_ playerID: String, _ failed: Bool) async throws { try await inner.setAttestationFailed(playerID, failed) }
    }

    static func queue(_ store: FaultyStore, _ clock: VirtualClock, _ log: LaunchLog, readTimeout: Duration = .seconds(2)) -> QueueMatchmaker {
        var settings = QueueSettings()
        settings.restrictionReadTimeout = readTimeout
        return QueueMatchmaker(settings: settings, registry: RaceRegistry(),
                               draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                               tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, now: { clock.now }, restrictions: store,
                               launch: { fleet, closed in try await log.record(fleet, closed) })
    }

    /// #469, failing closed: a player whose restrictions can't be read isn't queued, suspended or not; the queue doesn't
    /// take the store's silence for a clean record. Once the store answers, the suspended player is refused by name and
    /// the other joins.
    @Test func aPlayerWhoseRestrictionsCantBeReadIsNotQueued() async throws {
        let store = FaultyStore(), clock = VirtualClock()
        let queue = Self.queue(store, clock, LaunchLog())
        try await store.inner.setSuspension("T:0", .permanent)
        store.fault = .failing
        await #expect(throws: RestrictionsUnreadable.self) { try await queue.join(Self.player) }
        await #expect(throws: RestrictionsUnreadable.self) { try await queue.join(QueueMatchmakerTests.player(1)) }
        #expect(await queue.queuedCount == 0)
        clock.advance(60)
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
        store.fault = .none
        await #expect(throws: QueueError.refused(.suspended(until: nil))) { try await queue.join(Self.player) }
        try await queue.join(QueueMatchmakerTests.player(1))
        #expect(await queue.queuedCount == 1)
    }

    /// #469: a good read earlier doesn't let her in when the read at her join fails (she may have been suspended since).
    @Test func aJoinNeedsAFreshReadEvenWithAnEarlierOne() async throws {
        let store = FaultyStore(), clock = VirtualClock()
        let queue = Self.queue(store, clock, LaunchLog())
        var states = queue.stateUpdates(for: "T:0").makeAsyncIterator()
        #expect(await states.next() == .idle)
        try await store.inner.setSuspension("T:0", .permanent)
        store.fault = .failing
        await #expect(throws: RestrictionsUnreadable.self) { try await queue.join(Self.player) }
        #expect(await queue.queuedCount == 0)
    }

    /// #469: a read that hangs is given up at `restrictionReadTimeout`: the join fails closed instead of waiting on it.
    @Test func aHungReadAtJoinFailsClosedAtTheTimeout() async throws {
        let store = FaultyStore(), clock = VirtualClock()
        let queue = Self.queue(store, clock, LaunchLog(), readTimeout: .milliseconds(50))
        store.fault = .hanging
        await #expect(throws: RestrictionsUnreadable.self) { try await queue.join(Self.player) }
        #expect(await queue.queuedCount == 0)
        store.release()
    }

    /// #469: each step reads the whole queue's restrictions in one store call, and a read that fails or hangs doesn't
    /// hold the lock back: the queued players keep what was read when they joined, and the fleet locks on time.
    @Test func aStepReadsTheQueueOnceAndAFailedOrHungReadDoesntHoldTheLock() async throws {
        let store = FaultyStore(), clock = VirtualClock(), log = LaunchLog()
        let queue = Self.queue(store, clock, log, readTimeout: .milliseconds(50))
        for index in 0..<5 { try await queue.join(QueueMatchmakerTests.player(index)) }
        let before = store.reads
        clock.advance(1)
        await queue.step()
        #expect(store.reads.batch == before.batch + 1)
        #expect(store.reads.single == before.single)

        // The store stops answering: nobody is dropped for it.
        store.fault = .failing
        clock.advance(1)
        await queue.step()
        #expect(await queue.queuedCount == 5)
        store.fault = .hanging
        clock.advance(58)
        await queue.step()
        #expect(await queue.fleetsLocked == 1)
        #expect(await log.fleets.first?.humans.count == 5)
        store.release()

        // Back again, a suspension written meanwhile takes its player out at the next step.
        store.fault = .none
        try await queue.join(QueueMatchmakerTests.player(7))
        try await store.inner.setSuspension("T:7", .permanent)
        clock.advance(1)
        await queue.step()
        #expect(await queue.queuedCount == 0)
    }

    /// #469: the deadline itself: the work's result inside the limit, `DeadlineExceeded` past it even when the work
    /// ignores its cancel.
    @Test func aDeadlineGivesUpOnWorkThatDoesntAnswer() async throws {
        #expect(try await withDeadline(.seconds(30)) { 7 } == 7)
        await #expect(throws: FaultyStore.Unreachable.self) { try await withDeadline(.seconds(30)) { throw FaultyStore.Unreachable() } }
        let store = FaultyStore()
        store.fault = .hanging
        await #expect(throws: DeadlineExceeded.self) {
            _ = try await withDeadline(.milliseconds(20)) { try await store.restrictions(of: "T:0") }
        }
        store.release()
    }
}
