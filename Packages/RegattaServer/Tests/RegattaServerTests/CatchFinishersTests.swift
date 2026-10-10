import Foundation
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// Running races whose expected closes a test sets, read on the queue's virtual clock. A race closes at its expected
/// close: from then it isn't running.
final class FakeRunningRaces: RunningRaces {
    private let closes = Mutex<[UUID: Date]>([:])
    let clock: VirtualClock

    init(_ clock: VirtualClock) { self.clock = clock }

    func set(_ race: UUID, closesAt close: Date?) { closes.withLock { $0[race] = close } }

    func runningRaces() async -> [RunningRace] {
        let now = clock.now
        return closes.withLock { $0 }.filter { $0.value > now }.map { RunningRace(id: $0.key, ticksToClose: max(0, Int(($0.value.timeIntervalSince(now) * Double(Race.tickRate)).rounded()))) }
    }
}

/// #147, G2: the queue holds its lock to catch a running race's finishers: lock = expected close + offset, while the oldest
/// queued player's wait stays within maxHold; else the 1-minute rule. Virtual clock; nothing sails.
@Suite(.timeLimit(.minutes(1))) struct CatchFinishersTests {
    static let t0 = Date(timeIntervalSince1970: 1_791_460_800)

    struct Rig {
        let clock = VirtualClock(CatchFinishersTests.t0)
        let log = LaunchLog()
        let races: FakeRunningRaces
        let queue: QueueMatchmaker

        init(_ catchFinishers: CatchFinishers? = CatchFinishers()) {
            races = FakeRunningRaces(clock)
            var settings = QueueSettings()
            settings.catchFinishers = catchFinishers
            let clock = clock, log = log
            queue = QueueMatchmaker(settings: settings, registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 147), now: { clock.now },
                                    runningRaces: races, launch: { fleet, closed in try await log.record(fleet, closed) })
        }

        /// Steps once a second from now until the fleet locks or `limit` seconds after t0; the lock's time.
        func stepUntilLocked(limit: TimeInterval = 600) async -> TimeInterval? {
            while clock.now.timeIntervalSince(CatchFinishersTests.t0) <= limit {
                await queue.step()
                if await queue.fleetsLocked > 0 { return clock.now.timeIntervalSince(CatchFinishersTests.t0) }
                clock.advance(1)
            }
            return nil
        }

        func secondsToLock(_ index: Int) async -> Int? {
            guard case .queued(let status) = await queue.state(of: "T:\(index)") else { return nil }
            return status.secondsToLock
        }
    }

    /// The race in every test closes 3 min after t0; the player joins at t0 + 60 s (so the 1-minute rule is t0 + 120 s, and
    /// maxHold 180 s caps a hold at t0 + 240 s).
    static func caught(_ catchFinishers: CatchFinishers) async throws -> (lock: TimeInterval?, shown: Int?, gun: TimeInterval?) {
        let rig = Rig(catchFinishers)
        rig.races.set(UUID(), closesAt: t0 + 180)
        rig.clock.advance(60)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        let shown = await rig.secondsToLock(0)
        let lock = await rig.stepUntilLocked()
        var lines = await rig.queue.gunLines().makeAsyncIterator()
        let gunTicks = try #require(await rig.log.fleets.first).setup.startSequenceTicks
        rig.clock.advance(Double(gunTicks) / Double(Race.tickRate))
        await rig.queue.step()
        await rig.queue.stop()
        let gun: TimeInterval? = await lines.next() == nil ? nil : rig.clock.now.timeIntervalSince(t0)
        return (lock, shown, gun)
    }

    // MARK: Acceptance

    /// Acceptance (G2 defaults): against a race closing in 3 min, the queue locks 15 s after its expected close and the queue
    /// bar counts down to that; the gun is 75 s later.
    @Test func locksFifteenSecondsAfterTheExpectedClose() async throws {
        let (lock, shown, gun) = try await Self.caught(CatchFinishers())
        #expect(lock == 195)
        #expect(shown == 135)
        #expect(gun == 270)
    }

    /// Acceptance: each setting's documented lock and gun times against a race closing in 3 min (join at +60 s).
    @Test func offsetAndMaxHoldAreTheConfiguredValues() async throws {
        // offset 0: the lock is at the close.
        var result = try await Self.caught(CatchFinishers(offset: 0, maxHold: 180))
        #expect(result.lock == 180 && result.shown == 120 && result.gun == 255)
        // offset +15 (G2).
        result = try await Self.caught(CatchFinishers(offset: 15, maxHold: 180))
        #expect(result.lock == 195 && result.shown == 135 && result.gun == 270)
        // offset +30.
        result = try await Self.caught(CatchFinishers(offset: 30, maxHold: 180))
        #expect(result.lock == 210 && result.shown == 150 && result.gun == 285)
        // maxHold 60: no hold fits within a minute of her join; the 1-minute rule.
        result = try await Self.caught(CatchFinishers(offset: 15, maxHold: 60))
        #expect(result.lock == 120 && result.shown == 60 && result.gun == 195)
        // maxHold 180 (G2): the hold fits (lock 195 <= 60 + 180).
        result = try await Self.caught(CatchFinishers(offset: 15, maxHold: 180))
        #expect(result.lock == 195)
        // Off: the 1-minute rule.
        let rig = Rig(nil)
        rig.races.set(UUID(), closesAt: Self.t0 + 180)
        rig.clock.advance(60)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        #expect(await rig.stepUntilLocked() == 120)
    }

    @Test func oldestWaitOverTheCapFallsBackToTheMinuteRule() async throws {
        let rig = Rig()
        // Joined at t0: a close at +170 locks at +185, past her 180 s cap.
        rig.races.set(UUID(), closesAt: Self.t0 + 170)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        #expect(await rig.secondsToLock(0) == 60)
        #expect(await rig.stepUntilLocked() == 60)
    }

    /// A close that slips after the hold began moves the lock, up to the cap: there it locks.
    @Test func slippingCloseLocksAtTheCap() async throws {
        let rig = Rig()
        let race = UUID()
        rig.races.set(race, closesAt: Self.t0 + 180)
        rig.clock.advance(60)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        #expect(await rig.secondsToLock(0) == 135)
        rig.clock.advance(40)
        await rig.queue.step()
        // The leader slows: the close slips 20 s, and the lock with it.
        rig.races.set(race, closesAt: Self.t0 + 200)
        await rig.queue.step()
        #expect(await rig.secondsToLock(0) == 115)
        // Then far past her cap (+240): the lock stays at the cap.
        rig.races.set(race, closesAt: Self.t0 + 400)
        await rig.queue.step()
        #expect(await rig.secondsToLock(0) == 140)
        #expect(await rig.stepUntilLocked() == 240)
    }

    /// A race that closes during the hold leaves the lock where it was last timed.
    @Test func aCaughtRaceThatClosesKeepsItsLockTime() async throws {
        let rig = Rig()
        let race = UUID()
        rig.races.set(race, closesAt: Self.t0 + 180)
        rig.clock.advance(60)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        rig.clock.advance(120)
        await rig.queue.step()
        rig.races.set(race, closesAt: nil)
        #expect(await rig.stepUntilLocked() == 195)
    }

    /// With several running, it catches the one closing first whose lock fits the cap (Q3).
    @Test func theEarliestCatchableCloseIsCaught() async throws {
        let rig = Rig()
        rig.races.set(UUID(), closesAt: Self.t0 + 40)
        rig.races.set(UUID(), closesAt: Self.t0 + 100)
        rig.races.set(UUID(), closesAt: Self.t0 + 150)
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        // +40 would lock before the minute rule anyway; +100 is the first that lengthens the wait (lock +115).
        #expect(await rig.secondsToLock(0) == 115)
        #expect(await rig.stepUntilLocked() == 115)
    }

    @Test func sixteenHumansLockAtOnce() async throws {
        let rig = Rig()
        rig.races.set(UUID(), closesAt: Self.t0 + 120)
        for index in 0..<15 { try await rig.queue.join(QueueMatchmakerTests.player(index)) }
        #expect(await rig.secondsToLock(0) == 135)
        #expect(await rig.queue.fleetsLocked == 0)
        try await rig.queue.join(QueueMatchmakerTests.player(15))
        #expect(await rig.queue.fleetsLocked == 1)
    }

    @Test func gunIsSeventyFiveSecondsAfterLock() async throws {
        let rig = Rig()
        var lines = await rig.queue.gunLines().makeAsyncIterator()
        try await rig.queue.join(QueueMatchmakerTests.player(0))
        #expect(await rig.stepUntilLocked() == 60)
        let fleet = try #require(await rig.log.fleets.first)
        #expect(fleet.setup.startSequenceTicks == 75 * Race.tickRate)
        rig.clock.advance(74)
        await rig.queue.step()
        rig.clock.advance(1)
        await rig.queue.step()
        await rig.queue.stop()
        #expect(await lines.next() != nil)
        #expect(await lines.next() == nil)
    }

    /// The server's config: G2's values, and the dev overrides.
    @Test func theServerConfigCarriesTheSetting() throws {
        #expect(try ServerConfig.load(from: ["ENV": "dev"]).queue.catchFinishers == CatchFinishers(offset: 15, maxHold: 180))
        #expect(try ServerConfig.load(from: ["ENV": "dev", "CATCH_FINISHERS_OFFSET_SECONDS": "30", "CATCH_FINISHERS_MAX_HOLD_SECONDS": "60"])
            .queue.catchFinishers == CatchFinishers(offset: 30, maxHold: 60))
        #expect(try ServerConfig.load(from: ["ENV": "dev", "CATCH_FINISHERS": "off"]).queue.catchFinishers == nil)
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: ["ENV": "dev", "CATCH_FINISHERS": "maybe"]) }
    }
}
