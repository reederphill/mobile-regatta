import Crypto
import Foundation
import RaceHost
import RegattaBots
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
    /// A launch the store or the registry refused for a reason of the fleet's own.
    struct Refused: Error {}

    private(set) var fleets: [LockedFleet] = []
    /// Every launch asked for, started or not.
    private(set) var attempts: [LockedFleet] = []
    private var closers: [UUID: @Sendable () -> Void] = [:]
    private var failure: (error: any Error, times: Int)?
    private var refusedPlayers: Set<String> = []

    func record(_ fleet: LockedFleet, _ closed: @escaping @Sendable () -> Void) throws {
        attempts.append(fleet)
        if let failure, failure.times > 0 {
            self.failure?.times -= 1
            throw failure.error
        }
        if fleet.humans.contains(where: { refusedPlayers.contains($0.teamPlayerID) }) { throw Refused() }
        fleets.append(fleet)
        closers[fleet.raceID] = closed
    }

    func close(_ id: UUID) { closers.removeValue(forKey: id)?() }
    /// The next `times` launches fail with `error` (by default as a full registry does).
    func failing(_ error: any Error = RaceRegistry.StartError.full, times: Int = 1) { failure = (error, times) }
    /// Every fleet with this player in it fails to launch, for good (a player the store refuses).
    func refusing(_ player: String) { refusedPlayers.insert(player) }
}

/// A wind seed source that counts what the draw takes.
struct CountingSeeds: WindSeedSource {
    final class Count: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    let taken = Count()
    var pools = FixtureWindSeedPools(poolSize: 8)

    mutating func take(for pairing: WindSeedPool.Pairing) -> WindSeed? {
        taken.add()
        return pools.take(for: pairing)
    }
}

/// #146: the matchmaker on a virtual clock. Time moves only by `clock.advance` and `step()`; nothing sails.
@Suite(.timeLimit(.minutes(1))) struct QueueMatchmakerTests {
    static let key = SymmetricKey(size: .bits256)

    static func make(_ clock: VirtualClock, _ log: LaunchLog, settings: QueueSettings = QueueSettings(), poolSize: Int = 8,
                     pairings: [OnlinePairing] = OnlinePairing.bundled(), seed: UInt64 = 1,
                     bands: RatingBands? = nil, registry: RaceRegistry = RaceRegistry(),
                     seeds: (any WindSeedSource)? = nil) -> QueueMatchmaker {
        QueueMatchmaker(settings: settings, registry: registry,
                        draw: RaceDraw(pairings: pairings, seeds: seeds ?? FixtureWindSeedPools(poolSize: poolSize)),
                        tokenKey: key, tokenLifetime: 600, random: SeededRandom(seed: seed), now: { clock.now },
                        bands: bands ?? { [$0] }, launch: { fleet, closed in try await log.record(fleet, closed) })
    }

    static func player(_ index: Int) -> AccountPlayer {
        AccountPlayer(teamPlayerID: "T:\(index)", gamePlayerID: "G:\(index)", alias: "P\(index)")
    }

    // MARK: Acceptance

    /// Acceptance (#149): three humans queue, and the race that starts has ten boats: seven bots under sailing names,
    /// in free starter liveries, sailing at the fleet's level.
    @Test func threeHumansQueueAFleetOfTenWithNamedBotsAndStarterLiveries() async throws {
        let clock = VirtualClock(), registry = RaceRegistry()
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: registry,
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: Self.key, tokenLifetime: 600, random: SeededRandom(seed: 149), now: { clock.now })
        for index in 0..<3 { try await queue.join(Self.player(index)) }
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await queue.lastFleet)
        let setup = fleet.setup
        #expect(setup.seats == Array(repeating: .human, count: 3) + Array(repeating: .bot, count: 7))
        #expect(fleet.ratings == [1500, 1500, 1500] && fleet.fill.medianRating == 1500)

        // The race the registry is running: its roster and its bots.
        let session = try #require(await registry.session(fleet.raceID))
        let roster = await session.host.rosterEntries
        #expect(roster.map(\.isBot) == [false, false, false] + Array(repeating: true, count: 7))
        #expect(roster.prefix(3).map(\.name) == ["P0", "P1", "P2"])
        #expect(Array(roster.dropFirst(3).map(\.name)) == FleetRoster(setup: setup).entries.dropFirst(3).compactMap(\.sailingName))
        #expect(Set(roster.map(\.name)).count == 10)
        let bots = await session.host.botSeats
        #expect(bots.map(\.seat) == Array(3..<10) && bots.allSatisfy { $0.source == .fill })
        for bot in bots {
            #expect((1350...1650).contains(bot.plan.rating))
            #expect(bot.plan.skill == BotRatingMap.bundled.skill(rating: bot.plan.rating))
            guard case .bot(let driver) = await session.host.controller(seat: bot.seat) else {
                Issue.record("seat \(bot.seat) isn't a fleet bot")
                continue
            }
            #expect(driver.style.skill == bot.plan.skill && driver.handling == bot.plan.handling)
        }
        for seat in 0..<3 { #expect(await session.host.controller(seat: seat).isHuman) }

        // Each wears the free starter livery her seat's seed draws.
        let catalogue = try #require(OnlineBriefing.catalogue)
        let briefing = try #require(try await queue.handOff(for: "T:0").briefing)
        #expect(briefing.fleet.map(\.name) == roster.map(\.name) && briefing.fleet.map(\.isBot) == roster.map(\.isBot))
        for seat in 3..<10 {
            let drawn = try #require(BotDressing(setup: setup).livery(seat: seat, catalogue: catalogue))
            #expect(briefing.fleet[seat].livery.design == drawn.design && briefing.fleet[seat].livery.colours == drawn.colours)
            #expect(catalogue.designs(for: setup.boatClass.id).first { $0.id == drawn.design }?.acquisition.isFree == true)
        }
        await session.host.cancel(.unspecified)
        await queue.stop()
    }

    /// #149: the bots are rated at the median of the humans' ratings, give or take 150, and sail at the skill the map
    /// gives that rating; a rating that can't be read counts as 1500. Asking for ratings draws nothing of the queue's
    /// random numbers: the same seed locks the same race.
    @Test func botSkillsFollowTheFleetsMedianRating() async throws {
        func lock(_ ratings: RatingSource?) async throws -> LockedFleet {
            let clock = VirtualClock(), log = LaunchLog()
            let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                        draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                        tokenKey: Self.key, tokenLifetime: 600, random: SeededRandom(seed: 149), now: { clock.now },
                                        ratings: ratings, launch: { fleet, closed in try await log.record(fleet, closed) })
            for index in 0..<3 { try await queue.join(Self.player(index)) }
            clock.advance(60)
            await queue.step()
            return try #require(await log.fleets.first)
        }
        struct NoRating: Error {}
        let plain = try await lock(nil)
        let strong = try await lock { player in
            switch player.teamPlayerID {
            case "T:0": 2050
            case "T:1": 1900
            default: throw NoRating()
            }
        }
        let weak = try await lock { _ in 1100 }
        // The same draw whatever the ratings.
        #expect(strong.raceID == plain.raceID && strong.setup == plain.setup && strong.windSeed == plain.windSeed)
        #expect(weak.raceID == plain.raceID && weak.setup == plain.setup)

        #expect(plain.ratings == [1500, 1500, 1500] && plain.fill.medianRating == 1500)
        #expect(strong.ratings == [2050, 1900, 1500] && strong.fill.medianRating == 1900)
        #expect(weak.ratings == [1100, 1100, 1100] && weak.fill.medianRating == 1100)
        let seed = plain.setup.raceSeed, map = BotRatingMap.bundled
        for seat in 3..<10 {
            let low = weak.fill.plan(seat: seat, raceSeed: seed), mid = plain.fill.plan(seat: seat, raceSeed: seed)
            let high = strong.fill.plan(seat: seat, raceSeed: seed)
            #expect((1750...2050).contains(high.rating) && (950...1250).contains(low.rating))
            // One seat's offset is the same in every fleet: only the median moves her.
            #expect(high.rating - 1900 == mid.rating - 1500 && mid.rating - 1500 == low.rating - 1100)
            #expect(high.skill == map.skill(rating: high.rating) && low.skill == map.skill(rating: low.rating))
            #expect(low.skill < mid.skill && mid.skill < high.skill)
        }
        // The briefing shows each human the rating the median came from.
        #expect(OnlineBriefing.payloads(strong, stored: [], settings: QueueSettings())[0].fleet.prefix(3).map(\.rating) == [2050, 1900, 1500])
    }

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
        // The registry's last place went to another race between the check and the start, eight times over.
        await log.failing(times: 8)
        for attempt in 1...8 {
            await queue.step()
            #expect(await log.attempts.count == attempt)
            #expect(await queue.fleetsLocked == 0)
            #expect(await queue.queuedCount == 2)
            #expect(await queue.state(of: "T:1") == .queued(QueuedStatus(queuedPlayers: 2, secondsToLock: 0)))
            // Not again at once (#469), and never counted against the fleet: the same short wait each time.
            await queue.step()
            #expect(await log.attempts.count == attempt)
            clock.advance(2)
        }
        await queue.step()
        #expect(await queue.fleetsDropped == 0)
        #expect(await log.fleets.first?.humans.map(\.teamPlayerID) == ["T:0", "T:1"])
    }

    // MARK: Launch failures (#469)

    /// #469: a race that can't start is tried again after 2 s, then 4 s, then 8 s, never every second; each try draws
    /// its own race. A launch that works ends the run of failures.
    @Test func aFailedLaunchBacksOffBeforeItsNextTry() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = Self.make(clock, log)
        try await queue.join(Self.player(0))
        await log.failing(LaunchLog.Refused(), times: 3)
        clock.advance(60)
        await queue.step()
        #expect(await log.attempts.count == 1)
        #expect(await queue.state(of: "T:0") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 0)))
        // A step a second: the tries come 2, 6 and 14 s after the first.
        var tries: [Int] = []
        for _ in 1...14 {
            clock.advance(1)
            await queue.step()
            tries.append(await log.attempts.count)
        }
        #expect(tries == [1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4])
        #expect(Set(await log.attempts.map(\.raceID)).count == 4)
        #expect(await queue.fleetsLocked == 1)
        #expect(await queue.fleetsDropped == 0)
        #expect(await queue.state(of: "T:0") == .fleetLocked)

        // The next fleet's first failure waits 2 s again, not 16.
        try await queue.join(Self.player(1))
        await log.failing(LaunchLog.Refused(), times: 1)
        clock.advance(60)
        await queue.step()
        clock.advance(1)
        await queue.step()
        #expect(await log.attempts.count == 5)
        clock.advance(1)
        await queue.step()
        #expect(await log.attempts.count == 6)
        #expect(await queue.fleetsLocked == 2)
    }

    /// #469: a fleet whose race can never start (the store refuses one of its players) is dropped after five tries, and
    /// the players queued behind it lock on their own time: the head of the queue isn't pinned for ever.
    @Test func afterFiveFailedLaunchesTheFleetAtTheHeadIsDroppedAndTheQueueMovesOn() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        var settings = QueueSettings()
        settings.fleetCap = 2
        let queue = Self.make(clock, log, settings: settings)
        await log.refusing("T:0")
        var states = queue.stateUpdates(for: "T:1").makeAsyncIterator()
        #expect(await states.next() == .idle)
        try await queue.join(Self.player(0))
        // The second human fills the fleet: it locks at once, and its race can't start.
        try await queue.join(Self.player(1))
        #expect(await log.attempts.count == 1)
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 2, secondsToLock: 0)))
        clock.advance(1)
        try await queue.join(Self.player(2))
        // Tries 2…5 come 2, 6, 14 and 30 s after the first; the fifth failure drops the fleet.
        var tries: [Int] = []
        for _ in 2...30 {
            clock.advance(1)
            await queue.step()
            tries.append(await log.attempts.count)
        }
        #expect(tries.last == 5)
        #expect(tries.filter { $0 == 2 }.count == 4 && tries.filter { $0 == 3 }.count == 8 && tries.filter { $0 == 4 }.count == 16)
        #expect(await log.attempts.allSatisfy { $0.humans.map(\.teamPlayerID) == ["T:0", "T:1"] })
        #expect(await queue.fleetsDropped == 1)
        #expect(await queue.fleetsLocked == 0)
        // The dropped players are idle and free to join again; the player behind them is still queued, on her own clock.
        #expect(await states.next() == .idle)
        #expect(await queue.state(of: "T:0") == .idle)
        #expect(await queue.queuedCount == 1)
        #expect(await queue.state(of: "T:2") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 31)))
        clock.advance(31)
        await queue.step()
        #expect(await log.attempts.count == 6)
        #expect(await log.fleets.map { $0.humans.map(\.teamPlayerID) } == [["T:2"]])
        #expect(await queue.state(of: "T:2") == .fleetLocked)
        try await queue.join(Self.player(1))
    }

    /// #469: a full server draws nothing: no launch, no race id, no wind seed, however long it stays full; the fleet
    /// waits at the head, is never dropped, and may leave.
    @Test func aFullServerDrawsNothingAndDropsNobody() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let seeds = CountingSeeds()
        let queue = Self.make(clock, log, registry: RaceRegistry(maxRaces: 0), seeds: seeds)
        try await queue.join(Self.player(0))
        for _ in 0..<180 {
            clock.advance(1)
            await queue.step()
        }
        #expect(await log.attempts.isEmpty)
        #expect(seeds.taken.value == 0)
        #expect(await queue.fleetsDropped == 0)
        #expect(await queue.state(of: "T:0") == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 0)))
        try await queue.leave("T:0")
        // With room the same draw is taken.
        let roomy = Self.make(clock, log, seeds: seeds)
        try await roomy.join(Self.player(0))
        clock.advance(60)
        await roomy.step()
        #expect(await log.attempts.count == 1)
        #expect(seeds.taken.value == 1)
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
        var lines = await queue.gunLines().makeAsyncIterator()
        try await queue.join(Self.player(0))
        try await queue.join(Self.player(1))
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)
        // The briefing, then the sequence (#147, G2).
        let startSeconds = Double(fleet.setup.startSequenceTicks) / Double(Race.tickRate)
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
