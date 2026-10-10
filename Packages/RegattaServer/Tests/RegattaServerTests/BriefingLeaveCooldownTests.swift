import Foundation
import Persistence
import RaceHost
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// Waits (wall clock, at most `seconds`) until `condition` holds: for work a callback hands to a task.
func eventually(seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// The briefing leaves a host reported.
final class BriefingLeaves: Sendable {
    private let leaves = Mutex<[BriefingLeave]>([])
    func append(_ leave: BriefingLeave) { leaves.withLock { $0.append(leave) } }
    var all: [BriefingLeave] { leaves.withLock { $0 } }
}

extension RaceSims {
    /// #147: three briefing leaves in a rolling hour cost a 5-minute cooldown (owner Q1, Q2); a briefing leave is a human
    /// leaving between fleet lock and the gun, a drop counting only if she isn't back by the gun (owner Q6). Virtual clocks:
    /// the queue's (`VirtualClock`) and each race's (`ManualHostClock`).
    @Suite(.timeLimit(.minutes(2))) struct BriefingLeaveCooldownTests {
        static let time = Date(timeIntervalSince1970: 1_791_460_800)

        /// A queue whose races start on a lifecycle rig, never on the wall clock; humans first, then bots to 3 boats.
        struct QueueRig {
            let clock = VirtualClock()
            let rig = LifecycleRig()
            let store = InMemoryRestrictionStore()
            let matchmaker: QueueMatchmaker

            init() {
                var settings = QueueSettings()
                settings.startSequenceTicks = 90
                settings.botFloor = 3
                settings.catchFinishers = nil
                let clock = clock
                matchmaker = QueueMatchmaker(settings: settings, registry: RaceRegistry(),
                                             draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                             tokenKey: LifecycleRig.key, tokenLifetime: 600, random: SeededRandom(seed: 147), now: { clock.now },
                                             restrictions: store, launch: rig.lifecycle.launcher(clock: rig.clock))
            }

            /// Queues `players` and locks their fleet; returns its race.
            func lock(_ players: [AccountPlayer]) async throws -> RaceSession {
                let before = await rig.started.sessions.count
                for player in players { try await matchmaker.join(player) }
                clock.advance(60)
                await matchmaker.step()
                return try #require(await rig.started.sessions.dropFirst(before).first)
            }

            func leaves(_ id: String) async throws -> Int { try await store.briefingLeaves(of: id, since: .distantPast).count }
        }

        // MARK: Acceptance

        /// Acceptance: the third briefing leave within 60 minutes starts a 300 s cooldown, shown as a countdown and refused
        /// on join; it ends idle. The count starts again from zero (Q2).
        @Test func thirdLeaveInSixtyMinutesStartsA300SecondCooldown() async throws {
            let clock = VirtualClock(Self.time), store = InMemoryRestrictionStore()
            let tracker = BriefingLeaveTracker(store: store, now: { clock.now })
            #expect(await tracker.recordLeave("T:0", race: nil) == nil)
            clock.advance(20 * 60)
            #expect(await tracker.recordLeave("T:0", race: nil) == nil)
            clock.advance(20 * 60)
            let until = await tracker.recordLeave("T:0", race: nil)
            #expect(until == Self.time + 40 * 60 + 300)
            #expect(try await store.restrictions(of: "T:0").cooldownUntil == until)
            #expect(try await store.briefingLeaves(of: "T:0", since: .distantPast) == [])

            // The queue shows it as a countdown and refuses a join; it ends idle.
            let log = LaunchLog()
            let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                        draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                        tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, now: { clock.now }, restrictions: store,
                                        launch: { fleet, closed in try await log.record(fleet, closed) })
            var states = queue.stateUpdates(for: "T:0").makeAsyncIterator()
            #expect(await states.next() == .unavailable(.cooldown(secondsRemaining: 300)))
            await #expect(throws: QueueError.refused(.cooldown(secondsRemaining: 300))) {
                try await queue.join(QueueMatchmakerTests.player(0))
            }
            clock.advance(1)
            await queue.step()
            #expect(await states.next() == .unavailable(.cooldown(secondsRemaining: 299)))

            // Q2: a leave while cooling down lengthens nothing and isn't counted.
            #expect(await tracker.recordLeave("T:0", race: nil) == nil)
            #expect(try await store.restrictions(of: "T:0").cooldownUntil == until)
            #expect(try await store.briefingLeaves(of: "T:0", since: .distantPast) == [])

            clock.advance(299)
            await queue.step()
            #expect(await states.next() == .idle)
            try await queue.join(QueueMatchmakerTests.player(0))
            // The count started again: one more leave is the first of three.
            #expect(await tracker.recordLeave("T:0", race: nil) == nil)
        }

        /// Acceptance: backgrounding after lock (her race connection drops) counts, when she isn't back by the gun (owner
        /// Q6); a drop she comes back from before the gun doesn't. A seat never joined counts when the gun finds it empty.
        @Test func backgroundingAfterLockCountsAsALeave() async throws {
            let queue = QueueRig()
            let gone = QueueMatchmakerTests.player(0), back = QueueMatchmakerTests.player(1), never = QueueMatchmakerTests.player(2)
            let race = try await queue.lock([gone, back, never])
            #expect(await queue.matchmaker.state(of: gone.teamPlayerID) == .fleetLocked)
            let goneLink = KeptTransport(), backLink = KeptTransport()
            try await race.join(seat: 0, transport: goneLink)
            try await race.join(seat: 1, transport: backLink)
            await queue.rig.run(race, to: -60)
            // Both background the app: their race connections drop. One comes back before the gun.
            await race.leave(seat: 0, transport: goneLink)
            await race.leave(seat: 1, transport: backLink)
            await queue.rig.run(race, to: -30)
            try await race.join(seat: 1, transport: KeptTransport())
            #expect(try await queue.leaves(gone.teamPlayerID) == 0, "a drop counts only once the gun finds her gone")

            await queue.rig.run(race, to: 1)
            #expect(await eventually { (try? await queue.leaves(gone.teamPlayerID)) == 1 })
            #expect(await eventually { (try? await queue.leaves(never.teamPlayerID)) == 1 })
            #expect(try await queue.leaves(back.teamPlayerID) == 0)
            // Her seat is still hers after the gun (#66): she stays locked into it.
            #expect(await queue.matchmaker.state(of: gone.teamPlayerID) == .fleetLocked)
        }

        @Test func leavesOutsideSixtyMinutesDontAccumulate() async throws {
            let clock = VirtualClock(Self.time), store = InMemoryRestrictionStore()
            let tracker = BriefingLeaveTracker(store: store, now: { clock.now })
            for minutes in [0.0, 61, 61] {
                clock.advance(minutes * 60)
                #expect(await tracker.recordLeave("T:0", race: nil) == nil)
            }
            // 0, 61, 122 minutes: never three within an hour. Then 130 and 138: three since 122 - 60.
            #expect(try await store.briefingLeaves(of: "T:0", since: .distantPast).count == 1)
            clock.advance(8 * 60)
            #expect(await tracker.recordLeave("T:0", race: nil) == nil)
            clock.advance(8 * 60)
            #expect(await tracker.recordLeave("T:0", race: nil) == clock.now + 300)
        }

        /// Leaving the queue before lock is free (#16): any number of times.
        @Test func queueLeaveBeforeLockIsFree() async throws {
            let queue = QueueRig()
            let player = QueueMatchmakerTests.player(0)
            for _ in 0..<4 {
                try await queue.matchmaker.join(player)
                try await queue.matchmaker.leave(player.teamPlayerID)
                try await queue.matchmaker.join(player)
                await queue.matchmaker.dropped(player.teamPlayerID)
            }
            #expect(try await queue.leaves(player.teamPlayerID) == 0)
            #expect(await queue.matchmaker.state(of: player.teamPlayerID) == .idle)
        }

        /// After the gun nothing counts: a drop, or leaving for good.
        @Test func leaveAfterTheGunDoesNotCount() async throws {
            let reported = BriefingLeaves()
            let rig = LifecycleRig()
            let setup = try RaceSetup(raceSeed: RaceSeed(147), seats: [.human, .human, .bot], laps: 1, startSequenceTicks: 60)
            let race = rig.lifecycle.session(id: UUID(), setup: setup, windSeed: WindSeed(147), names: ["A", "B"], clock: rig.clock,
                                             onBriefingLeave: { reported.append($0) })
            let a = KeptTransport(), b = KeptTransport()
            try await race.join(seat: 0, transport: a)
            try await race.join(seat: 1, transport: b)
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1], to: 30, seq: &seq)
            await race.leave(seat: 0, transport: a)
            #expect(await race.quit(seat: 1))
            await rig.run(race, to: 90)
            #expect(reported.all.isEmpty)
        }

        // MARK: More

        /// Leaving for good before the gun (`RaceHost.leave`) counts at once, and frees her: she can queue again.
        @Test func leavingForGoodBeforeTheGunCountsAtOnceAndFreesHer() async throws {
            let queue = QueueRig()
            let player = QueueMatchmakerTests.player(0)
            let race = try await queue.lock([player])
            try await race.join(seat: 0, transport: KeptTransport())
            await queue.rig.run(race, to: -60)
            #expect(await race.quit(seat: 0))
            #expect(await eventually { (try? await queue.leaves(player.teamPlayerID)) == 1 })
            #expect(await eventually { await queue.matchmaker.state(of: player.teamPlayerID) == .idle })
            try await queue.matchmaker.join(player)
            // Nothing more at the gun for a seat she already left.
            await queue.rig.run(race, to: 1)
            try await Task.sleep(for: .milliseconds(50))
            #expect(try await queue.leaves(player.teamPlayerID) == 1)
        }

        /// Three races' briefings left in an hour: the third starts the cooldown, which the queue shows her.
        @Test func threeRacesLeftStartTheCooldownInTheQueue() async throws {
            let queue = QueueRig()
            let player = QueueMatchmakerTests.player(0)
            for _ in 0..<3 {
                let race = try await queue.lock([player])
                await queue.rig.run(race, to: -60)
                #expect(await race.quit(seat: 0))
                #expect(await eventually { await queue.matchmaker.state(of: player.teamPlayerID) != .fleetLocked })
            }
            #expect(await queue.matchmaker.state(of: player.teamPlayerID) == .unavailable(.cooldown(secondsRemaining: 300)))
        }

        /// A race cancelled before the gun reports nobody who hadn't left: a seat never joined isn't a leave then.
        @Test func aRaceCancelledBeforeTheGunCountsNobody() async throws {
            let reported = BriefingLeaves()
            let rig = LifecycleRig()
            let setup = try RaceSetup(raceSeed: RaceSeed(147), seats: [.human, .bot], laps: 1, startSequenceTicks: 60)
            let race = rig.lifecycle.session(id: UUID(), setup: setup, windSeed: WindSeed(147), names: ["A"], clock: rig.clock,
                                             onBriefingLeave: { reported.append($0) })
            await rig.run(race, to: -30)
            await race.host.cancel(.unspecified)
            await rig.run(race, to: 30)
            #expect(reported.all.isEmpty)
        }
    }
}
