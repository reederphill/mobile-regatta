import Crypto
import Foundation
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// A clock that moves only when told.
final class VirtualClock: Sendable {
    private let time: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_460_800)) { time = Mutex(start) }

    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

/// The races a matchmaker launched, without sailing them.
actor LaunchLog {
    private(set) var fleets: [LockedFleet] = []
    private var closers: [UUID: @Sendable () -> Void] = [:]
    var failNext = false

    func record(_ fleet: LockedFleet, _ closed: @escaping @Sendable () -> Void) throws {
        if failNext {
            failNext = false
            throw RaceRegistry.StartError.full
        }
        fleets.append(fleet)
        closers[fleet.raceID] = closed
    }

    func close(_ id: UUID) { closers.removeValue(forKey: id)?() }
    func failing() { failNext = true }
}

/// #146: the matchmaker on a virtual clock. Time moves only by `clock.advance` and `step()`; nothing sails.
@Suite(.timeLimit(.minutes(1))) struct QueueMatchmakerTests {
    static let key = SymmetricKey(size: .bits256)

    static func make(_ clock: VirtualClock, _ log: LaunchLog, settings: QueueSettings = QueueSettings(), poolSize: Int = 8,
                     pairings: [OnlinePairing] = OnlinePairing.bundled(), seed: UInt64 = 1,
                     bands: RatingBands? = nil) -> QueueMatchmaker {
        QueueMatchmaker(settings: settings, registry: RaceRegistry(), draw: RaceDraw(pairings: pairings, seeds: FixtureWindSeedPools(poolSize: poolSize)),
                        tokenKey: key, tokenLifetime: 600, random: SeededRandom(seed: seed), now: { clock.now },
                        bands: bands ?? { [$0] }, launch: { fleet, closed in try await log.record(fleet, closed) })
    }

    static func player(_ index: Int) -> AccountPlayer {
        AccountPlayer(teamPlayerID: "T:\(index)", gamePlayerID: "G:\(index)", alias: "P\(index)")
    }

    // MARK: Acceptance

    /// Acceptance: the 16th human locks the fleet at once, with no bots.
    @Test func theSixteenthHumanLocksImmediately() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        for index in 0..<15 {
            try await queue.join(Self.player(index))
            clock.advance(1)
        }
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
        #expect(await queue.queuedCount == 15)
        try await queue.join(Self.player(15))
        #expect(await queue.fleetsLocked == 1)
        #expect(await queue.queuedCount == 0)
        let fleet = try #require(await log.fleets.first)
        #expect(fleet.humans.map(\.teamPlayerID) == (0..<16).map { "T:\($0)" })
        #expect(fleet.setup.seats == Array(repeating: .human, count: 16))
        // Every human holds a token for their own seat in that race.
        for index in 0..<16 {
            #expect(await queue.state(of: "T:\(index)") == .fleetLocked)
            let handOff = try await queue.handOff(for: "T:\(index)")
            let token = try RaceToken.verify(handOff.token.bytes, key: Self.key, now: Int64(clock.now.timeIntervalSince1970))
            #expect(token.raceID == fleet.raceID)
            #expect(token.seat == index)
            #expect(handOff.raceID.rawValue == fleet.raceID.uuidString.lowercased())
        }
    }

    /// Acceptance: a lone player locks at 60 s, with 9 bots.
    @Test func aLonePlayerLocksAtSixtySecondsWithNineBots() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        try await queue.join(Self.player(0))
        #expect(await queue.state(of: "T:0") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 60)))
        clock.advance(59)
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
        #expect(await queue.state(of: "T:0") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 1)))
        clock.advance(1)
        await queue.step()
        #expect(await queue.fleetsLocked == 1)
        let fleet = try #require(await log.fleets.first)
        #expect(fleet.setup.seats.count == 10)
        #expect(fleet.setup.seats.filter { $0 == .human }.count == 1)
        #expect(fleet.setup.seats.filter { $0 == .bot }.count == 9)
        #expect(fleet.setup.seats.first == .human)
        #expect(await queue.state(of: "T:0") == .fleetLocked)
    }

    /// Acceptance: one filling race at a time. While the first fleet has fewer than 16 humans no second one opens:
    /// every joiner is in the one fleet, counting down from the oldest's join. The 17th starts the next fleet.
    @Test func aSecondRaceIsntOpenedWhileTheFirstHasFewerThanSixteen() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        for index in 0..<15 {
            try await queue.join(Self.player(index))
            clock.advance(2)
            await queue.step()
        }
        #expect(await queue.fleetsLocked == 0)
        #expect(await log.fleets.isEmpty)
        // All 15 see the same fleet: 15 queued, 30 s to the oldest's lock.
        for index in 0..<15 {
            #expect(await queue.state(of: "T:\(index)") == .queued(QueuedStatus(queuedPlayers: 15, secondsToLock: 30)))
        }
        try await queue.join(Self.player(15))
        try await queue.join(Self.player(16))
        #expect(await log.fleets.count == 1)
        #expect(await log.fleets.first?.humans.count == 16)
        #expect(await queue.state(of: "T:16") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 60)))
    }

    // MARK: Joining and leaving

    @Test func leavingIsFreeAndADroppedConnectionLeaves() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        await #expect(throws: QueueError.notQueued) { try await queue.leave("T:0") }
        try await queue.join(Self.player(0))
        await #expect(throws: QueueError.alreadyQueued) { try await queue.join(Self.player(0)) }
        try await queue.leave("T:0")
        #expect(await queue.state(of: "T:0") == .idle)
        try await queue.join(Self.player(0))
        await queue.dropped("T:0")
        #expect(await queue.queuedCount == 0)
        clock.advance(120)
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
    }

    /// After lock the queue is done with the player until the race closes; then she may queue again.
    @Test func aLockedPlayerIsFreeAgainWhenHerRaceCloses() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        try await queue.join(Self.player(0))
        clock.advance(60)
        await queue.step()
        await #expect(throws: QueueError.alreadyQueued) { try await queue.join(Self.player(0)) }
        await #expect(throws: QueueError.notQueued) { try await queue.leave("T:0") }
        await queue.dropped("T:0")
        #expect(await queue.state(of: "T:0") == .fleetLocked)
        let fleet = try #require(await log.fleets.first)
        await queue.raceClosed(fleet.raceID)
        #expect(await queue.state(of: "T:0") == .idle)
        await #expect(throws: RaceSessionError.noRace) { try await queue.handOff(for: "T:0") }
        try await queue.join(Self.player(0))
    }

    @Test func aRaceThatCantStartPutsItsFleetBackAtTheHead() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        try await queue.join(Self.player(0))
        clock.advance(30)
        try await queue.join(Self.player(1))
        clock.advance(30)
        await log.failing()
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
        #expect(await queue.queuedCount == 2)
        #expect(await queue.state(of: "T:1") == .queued(QueuedStatus(queuedPlayers: 2, secondsToLock: 0)))
        await queue.step()
        #expect(await log.fleets.first?.humans.map(\.teamPlayerID) == ["T:0", "T:1"])
    }

    // MARK: Pushes

    /// The countdown is pushed each step and the queued count on each change, coalesced to the latest.
    @Test func theCountdownAndQueuedCountArePushed() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        var states = queue.stateUpdates(for: "T:0").makeAsyncIterator()
        #expect(await states.next() == .idle)
        try await queue.join(Self.player(0))
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 60)))
        clock.advance(1)
        await queue.step()
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 59)))
        try await queue.join(Self.player(1))
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 2, secondsToLock: 59)))
        clock.advance(59)
        await queue.step()
        #expect(await states.next() == .fleetLocked)
    }

    @Test func aDevCooldownCountsDownToIdleAndASuspensionRefuses() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        await queue.arrangeCooldown("T:0", seconds: 3)
        #expect(await queue.state(of: "T:0") == .unavailable(.cooldown(secondsRemaining: 3)))
        await #expect(throws: QueueError.refused(.cooldown(secondsRemaining: 3))) { try await queue.join(Self.player(0)) }
        clock.advance(1.5)
        await queue.step()
        #expect(await queue.state(of: "T:0") == .unavailable(.cooldown(secondsRemaining: 2)))
        clock.advance(1.5)
        await queue.step()
        #expect(await queue.state(of: "T:0") == .idle)
        try await queue.join(Self.player(0))

        await queue.arrangeSuspension("T:1", until: nil)
        await #expect(throws: QueueError.refused(.suspended(until: nil))) { try await queue.join(Self.player(1)) }
        let until = Int64(clock.now.timeIntervalSince1970) + 10
        await queue.arrangeSuspension("T:2", until: until)
        #expect(await queue.state(of: "T:2") == .unavailable(.suspended(until: until)))
        clock.advance(10)
        #expect(await queue.state(of: "T:2") == .idle)
    }

    // MARK: The gun

    /// The gun's system line for the lobby (#17, #36), at the end of the start sequence: venue name, boats, humans.
    @Test func theGunGoesToTheLobbyAtTheEndOfTheStartSequence() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        var lines = queue.gunLines().makeAsyncIterator()
        try await queue.join(Self.player(0))
        try await queue.join(Self.player(1))
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)
        let startSeconds = Double(RaceSetup.defaultStartSequenceTicks) / Double(Race.tickRate)
        clock.advance(startSeconds - 1)
        await queue.step()
        clock.advance(1)
        await queue.step()
        await queue.stop()
        #expect(await lines.next() == .gun(venue: fleet.drawn.pairing.venue.content.displayName, boats: 10, humans: 2))
        #expect(await lines.next() == nil)
    }

    // MARK: The draw

    @Test func onlinePairingsAreTheBundledVenuesButTheDevVenue() {
        let pairings = OnlinePairing.bundled()
        #expect(!pairings.isEmpty)
        #expect(!pairings.contains { $0.venue.id == OnlinePairing.devVenueID })
        for pairing in pairings {
            #expect(pairing.venue.content.pairing(for: DataFileKey(id: pairing.conditions.id, version: pairing.conditions.version)) != nil)
        }
    }

    /// G1: each draw retires its seed; a pairing whose buffer is empty is passed over for another; with every buffer
    /// empty there is no race (and the fleet waits).
    @Test func aDrawnSeedIsRetiredAndAnEmptyBufferDrawsAnotherPairing() async throws {
        let pairings = Array(OnlinePairing.bundled().prefix(2))
        #expect(pairings.count == 2)
        var draw = RaceDraw(pairings: pairings, seeds: FixtureWindSeedPools(poolSize: 1))
        var random = SeededRandom(seed: 7)
        let drawn = (0..<3).map { _ in draw.draw(using: &random) }
        let first = try #require(drawn[0]), second = try #require(drawn[1])
        #expect(first.pairing.name != second.pairing.name)
        #expect(drawn[2] == nil)

        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log, poolSize: 0)
        try await queue.join(Self.player(0))
        clock.advance(60)
        await queue.step()
        #expect(await queue.fleetsLocked == 0)
        #expect(await queue.queuedCount == 1)
    }

    /// The tide state is the one the sim draws from the race seed, so it lies within the venue's range; and the draw
    /// replays from its seed.
    @Test func theDrawIsReproducibleAndItsTideIsTheRaceSeeds() throws {
        func draws(_ seed: UInt64) -> [DrawnRace] {
            var draw = RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 64))
            var random = SeededRandom(seed: seed)
            return (0..<12).compactMap { _ in draw.draw(using: &random) }
        }
        let one = draws(3), two = draws(3)
        #expect(one.count == 12)
        #expect(one.map(\.raceSeed) == two.map(\.raceSeed))
        #expect(one.map(\.windSeed) == two.map(\.windSeed))
        #expect(one.map(\.pairing.name) == two.map(\.pairing.name))
        for drawn in one {
            let tide = CurrentField.tideStateAtGun(for: drawn.pairing.venue.content, raceSeed: drawn.raceSeed)
            #expect(drawn.poolKey.tideStateDegrees == tide.map { $0 * 180 / .pi })
            #expect((drawn.pairing.venue.content.current == nil) == (tide == nil))
        }
    }

    /// The race a fleet locks into is one the server can sail: a `RaceSession` builds from it.
    @Test func aLockedFleetsRaceBuilds() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log, seed: 11)
        try await queue.join(Self.player(0))
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)
        #expect(fleet.setup.venue == fleet.drawn.pairing.venue.ref)
        #expect(fleet.setup.conditions == fleet.drawn.pairing.conditions.ref)
        let session = RaceSession(id: fleet.raceID, setup: fleet.setup, windSeed: fleet.windSeed)
        #expect(session.humanSeats == [0])
    }

    /// Rating bands are a stub hook, asked only when more than `bandsAbove` are queued (#146 Q3).
    @Test func ratingBandsAreAskedOnlyPastTheThreshold() {
        var settings = QueueSettings()
        settings.bandsAbove = 2
        settings.fleetCap = 4
        let asked = Mutex(0)
        let bands: ([QueueEntry]) -> [[QueueEntry]] = { entries in
            asked.withLock { $0 += 1 }
            return [Array(entries.reversed())]
        }
        var book = QueueBook()
        let start = Date(timeIntervalSince1970: 0)
        book.add(Self.player(0), at: start)
        book.add(Self.player(1), at: start)
        #expect(book.takeFleet(settings, bands: bands).map(\.player.teamPlayerID) == ["T:0", "T:1"])
        #expect(asked.withLock { $0 } == 0)
        for index in 0..<3 { book.add(Self.player(index), at: start) }
        #expect(book.takeFleet(settings, bands: bands).map(\.player.teamPlayerID) == ["T:2", "T:1", "T:0"])
        #expect(asked.withLock { $0 } == 1)
    }
}
