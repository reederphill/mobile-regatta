import Foundation
import Persistence
import RaceHost
import Ratings
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// #159: seat liveries on the server: stored per player, owned by acquisition and completed races, locked from fleet
/// lock to the close, raced as a free starter when not owned, equal sail numbers resolved in the briefing, and earned
/// unlocks told to analytics.
@Suite(.timeLimit(.minutes(1))) struct SeatLiveryTests {
    static let catalogue = OnlineBriefing.catalogue!
    static let ann = AccountPlayer(teamPlayerID: "T:ann", gamePlayerID: "G:ann", alias: "ann")

    static func livery(_ design: String, _ colours: [String], number: Int = 7) -> Livery {
        Livery(design: DesignID(design), colours: colours.map(SwatchID.init), sailNumber: number)
    }

    /// A design with three slots, filled from the palette.
    static func three(_ design: String, number: Int = 7) -> Livery { livery(design, ["charcoal", "sky-blue", "off-white"], number: number) }

    static func liveries(races: Int = 0, locked: Bool = false) -> (StoredLiveries, InMemoryRatingBook) {
        let book = InMemoryRatingBook()
        book.setStats(completedRaces: races, wins: 0, for: ann.teamPlayerID)
        return (StoredLiveries(store: InMemoryLiveryStore(), ratings: book, isLocked: { _ in locked }), book)
    }

    /// The stored livery is the player's, wherever she reads it from (a new connection, another device); until she
    /// stores one she wears her starter, the same each time.
    @Test func aStoredLiveryFollowsThePlayer() async throws {
        let (liveries, _) = Self.liveries()
        let starter = try await liveries.livery(of: Self.ann)
        #expect(try await liveries.livery(of: Self.ann) == starter)
        #expect(await liveries.raceLivery(of: Self.ann) == nil, "the briefing gives her starter itself")
        let mine = Self.three("skiff-stripe", number: 42)
        #expect(try await liveries.save(mine, for: Self.ann) == mine)
        let elsewhere = AccountPlayer(teamPlayerID: "T:ann", gamePlayerID: "G:ann", alias: "ann on her iPad")
        #expect(try await liveries.livery(of: elsewhere) == mine)
        #expect(await liveries.raceLivery(of: elsewhere) == mine)
        #expect(try await liveries.livery(of: AccountPlayer(teamPlayerID: "T:bob", gamePlayerID: "G:bob", alias: "bob")) != mine)
    }

    /// Free designs are everyone's; an earned design is hers from its threshold of completed races; paid designs are
    /// nobody's before purchases are verified (#399).
    @Test(arguments: [(9, "skiff-earned-10", false), (10, "skiff-earned-10", true), (49, "skiff-earned-50", false), (50, "skiff-earned-50", true),
                      (0, "skiff-sheer", true), (500, "skiff-pinstripe", false)])
    func ownershipDecidesWhatCanBeStored(races: Int, design: String, owned: Bool) async throws {
        let (liveries, _) = Self.liveries(races: races)
        let livery = Self.three(design)
        if owned {
            #expect(try await liveries.save(livery, for: Self.ann) == livery)
        } else {
            await #expect(throws: ProfileError.invalidLivery(.notOwned)) { try await liveries.save(livery, for: Self.ann) }
            #expect(try await liveries.livery(of: Self.ann) != livery)
        }
    }

    /// From fleet lock to the close nothing is stored, valid or not; resending the livery she has is answered as stored.
    @Test func lockedFromFleetLockToTheClose() async throws {
        let locked = Mutex(false)
        let liveries = StoredLiveries(store: InMemoryLiveryStore(), ratings: InMemoryRatingBook(), isLocked: { _ in locked.withLock { $0 } })
        let mine = Self.three("skiff-stripe")
        _ = try await liveries.save(mine, for: Self.ann)
        locked.withLock { $0 = true }
        await #expect(throws: ProfileError.liveryLocked) { try await liveries.save(Self.three("skiff-sheer"), for: Self.ann) }
        #expect(try await liveries.livery(of: Self.ann) == mine)
        #expect(try await liveries.save(mine, for: Self.ann) == mine)
    }

    /// A fleet that locks while her write is in flight has read the old livery: the write is undone and refused.
    @Test func aWriteRacingTheLockIsUndone() async throws {
        let checks = Mutex(0)
        // Unlocked at the check before the write, locked by the one after it.
        let liveries = StoredLiveries(store: InMemoryLiveryStore(), ratings: InMemoryRatingBook(),
                                      isLocked: { _ in checks.withLock { $0 += 1; return $0 > 1 } })
        let starter = try await liveries.livery(of: Self.ann)
        await #expect(throws: ProfileError.liveryLocked) { try await liveries.save(Self.three("skiff-stripe"), for: Self.ann) }
        #expect(try await liveries.livery(of: Self.ann) == starter, "nothing stored: she wears her starter")
        #expect(await liveries.raceLivery(of: Self.ann) == nil)
    }

    /// Her stored livery races when her completed races can't be read: it was hers when she stored it.
    @Test func anUnreadableCountRacesTheStoredDesign() async throws {
        let store = InMemoryLiveryStore()
        _ = try await store.save(Self.three("skiff-earned-10"), for: Self.ann.teamPlayerID, at: Date())
        let liveries = StoredLiveries(store: store, ratings: UnreadableRatings())
        #expect(await liveries.raceLivery(of: Self.ann) == Self.three("skiff-earned-10"))
    }

    /// The queue holds her livery from her fleet's lock until its race closes.
    @Test func theQueueHoldsTheLiveryFromLockToClose() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 159),
                                    now: { clock.now }, launch: { fleet, closed in try await log.record(fleet, closed) })
        for index in 0..<2 { try await queue.join(QueueMatchmakerTests.player(index)) }
        #expect(await !queue.holdsLivery("T:0"), "queued, not locked")
        clock.advance(60)
        await queue.step()
        #expect(await queue.holdsLivery("T:0"))
        #expect(await queue.holdsLivery("T:1"))
        let race = try #require(await log.fleets.first?.raceID)
        // Giving her seat up frees hers alone.
        await queue.releaseSeat(race, seat: 1)
        #expect(await !queue.holdsLivery("T:1"))
        #expect(await queue.holdsLivery("T:0"))
        await queue.raceClosed(race)
        #expect(await !queue.holdsLivery("T:0"))
    }

    /// A stored design she doesn't own (or the catalogue no longer has) races as the same colours on a free starter of
    /// the class: the first with the same slots, else the first free one. Never an earned or paid design.
    @Test func anUnownedDesignRacesAsTheSameColoursOnAFreeStarter() throws {
        let earned = Self.three("skiff-earned-50", number: 42)
        let raced = StoredLiveries.raceable(earned, catalogue: Self.catalogue, boatClass: "skiff") { $0.acquisition.isFree }
        #expect(raced == Self.three("skiff-stripe", number: 42))
        // Owned, it is raced as stored.
        #expect(StoredLiveries.raceable(earned, catalogue: Self.catalogue, boatClass: "skiff") { _ in true } == earned)
        // Two slots: the two-slot free design.
        let paid = Self.livery("skiff-band", ["charcoal", "off-white"], number: 3)
        #expect(StoredLiveries.raceable(paid, catalogue: Self.catalogue, boatClass: "skiff") { $0.acquisition.isFree }
            == Self.livery("skiff-plain", ["charcoal", "off-white"], number: 3))
        // A design the catalogue doesn't have: the first free design, each slot filled from the palette.
        let gone = Self.livery("skiff-retired", ["charcoal", "off-white"], number: 3)
        let fallback = StoredLiveries.raceable(gone, catalogue: Self.catalogue, boatClass: "skiff") { _ in true }
        #expect(fallback.design == DesignID("skiff-plain") && fallback.sailNumber == 3)
        #expect((try? Self.catalogue.validate(fallback, boatClass: "skiff")) != nil)
    }

    /// The briefing reads her raceable livery at fleet lock.
    @Test func theBriefingRacesAnUnownedDesignAsAStarter() async throws {
        let (liveries, book) = Self.liveries(races: 50)
        try await #require(liveries.save(Self.three("skiff-earned-50"), for: Self.ann) == Self.three("skiff-earned-50"))
        #expect(await liveries.raceLivery(of: Self.ann) == Self.three("skiff-earned-50"))
        // Her account was reset (say): the earned design is no longer hers to race.
        book.setStats(completedRaces: 0, wins: 0, for: Self.ann.teamPlayerID)
        #expect(await liveries.raceLivery(of: Self.ann) == Self.three("skiff-stripe"))
    }

    /// Acceptance (#159): two equal sail numbers in a fleet are resolved deterministically: the player who joined
    /// later shows the next free number for that race, the same in every briefing and every time.
    @Test func twoEqualSailNumbersAreResolvedDeterministically() async throws {
        func fleetNumbers() async throws -> [[Int]] {
            let clock = VirtualClock(), log = LaunchLog()
            let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                        draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                        tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 159),
                                        now: { clock.now }, liveries: { _ in Self.three("skiff-stripe", number: 42) },
                                        launch: { fleet, closed in try await log.record(fleet, closed) })
            for index in 0..<2 { try await queue.join(QueueMatchmakerTests.player(index)) }
            clock.advance(60)
            await queue.step()
            var numbers: [[Int]] = []
            for index in 0..<2 { numbers.append(try #require(try await queue.handOff(for: "T:\(index)").briefing).fleet.map(\.livery.sailNumber)) }
            return numbers
        }
        let first = try await fleetNumbers()
        #expect(first[0] == first[1], "every briefing shows the same numbers")
        #expect(first[0][0] == 42 && first[0][1] == 43, "the later joiner shows the next free number")
        #expect(Set(first[0]).count == first[0].count)
        #expect(try await fleetNumbers() == first)
    }

    /// The lobby chip shows the stored livery's deck and sail.
    @Test func theLobbyChipIsTheStoredLiverys() async throws {
        let (liveries, _) = Self.liveries()
        _ = try await liveries.save(Self.three("skiff-stripe"), for: Self.ann)
        #expect(await liveries.chip(of: Self.ann) == LiveryChip(deck: SwatchID("charcoal"), sail: SwatchID("off-white")))
    }

    /// The bundled catalogue's skiff designs are earned at 10, 50 and 200 completed races.
    @Test func earnedDesignsFollowTheCatalogue() {
        let earned = EarnedDesigns(catalogue: Self.catalogue, boatClass: "skiff")
        #expect(earned.milestones.map(\.completedRaces) == [10, 50, 200])
        #expect(earned.progress(completedRaces: 0) == EarnedProgress(earned: [], next: earned.milestones[0]))
        #expect(earned.progress(completedRaces: 50) == EarnedProgress(earned: [DesignID("skiff-earned-10"), DesignID("skiff-earned-50")],
                                                                      next: earned.milestones[2]))
        #expect(earned.progress(completedRaces: 999).next == nil)
        #expect(earned.unlocked(at: 10) == [DesignID("skiff-earned-10")] && earned.unlocked(at: 11).isEmpty)
    }
}

extension RaceSims {
    /// #159: the earned counter over real closes: what counts is `earnedProgressResultCodes`; a cancelled race counts
    /// nothing; the close that reaches a threshold tells analytics, once.
    @Suite(.timeLimit(.minutes(2))) struct EarnedCounterTests {
        /// A rig whose closes report completions to `EarnedUnlocks` over an in-memory analytics store.
        static func rig(codes: Set<ResultCode>? = nil, cancel: Bool = false) -> (LifecycleRig, InMemoryAnalyticsStore, LateBound<EarnedUnlocks>) {
            var settings = LifecycleRig.quickGrace(cancel ? .cancel : .ret)
            settings.closeRetryDelay = .milliseconds(1)
            if let codes { settings.earnedProgressResultCodes = codes }
            let box = LateBound<EarnedUnlocks>()
            let rig = LifecycleRig(settings: settings, completed: { await box.value?.completed($0) })
            let store = InMemoryAnalyticsStore()
            box.set(EarnedUnlocks(ratings: rig.archive.ratings, earned: EarnedDesigns(catalogue: OnlineBriefing.catalogue, boatClass: "skiff"),
                                  analytics: AnalyticsIngest(store: store)))
            return (rig, store, box)
        }

        /// Two players at the gun who then leave: RET both (`.ret`), or the race cancelled (`.cancel`).
        static func sailAndLeave(_ rig: LifecycleRig) async throws -> RaceSession {
            let race = try await rig.race(["T:0", "T:1"])
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1], to: 30, seq: &seq)
            await race.leave(seat: 1, transport: transports[1])
            await rig.sail(race, [0], to: 120, seq: &seq)
            await race.leave(seat: 0, transport: transports[0])
            await rig.runUntilEnded(race, limit: 1_400)
            return race
        }

        /// Acceptance (#159): the counter, parametrised over `earnedProgressResultCodes` sets: a RET counts only where
        /// the set holds it (G6 ships without it). At 9 races before, the counted close is the 10th: one unlock event.
        @Test(arguments: [nil, [ResultCode.ret], [], [.ret, .finished, .byDistance, .dsq, .ocs]] as [Set<ResultCode>?])
        func completedRacesFollowTheResultCodes(codes: Set<ResultCode>?) async throws {
            let (rig, analytics, _) = Self.rig(codes: codes)
            for player in ["T:0", "T:1"] { rig.archive.ratings.setStats(completedRaces: 9, wins: 0, for: player) }
            let race = try await Self.sailAndLeave(rig)
            let results = try #require(await race.host.outcome?.results)
            #expect(results.row(of: 0)?.code == .ret && results.row(of: 1)?.code == .ret)
            await rig.end(race)
            let counts = (codes ?? RaceLifecycleSettings().earnedProgressResultCodes).contains(.ret)
            for player in ["T:0", "T:1"] {
                #expect(try await rig.archive.ratings.standing(of: player)?.completedRaces == (counts ? 10 : 9))
            }
            let unlocks = analytics.raw().filter { $0.name == "earned_unlock" }
            #expect(unlocks.map(\.playerID) == (counts ? ["T:0", "T:1"] : []))
            #expect(unlocks.allSatisfy { $0.properties == ["design": .string("skiff-earned-10"), "completed_races": .int(10)] && $0.installID == nil })
        }

        /// Acceptance (#159): the earned counter is unchanged by a cancelled race (#30), whatever the codes; nothing is
        /// unlocked.
        @Test(arguments: [nil, [ResultCode.ret]] as [Set<ResultCode>?])
        func aCancelledRaceLeavesTheCounter(codes: Set<ResultCode>?) async throws {
            let (rig, analytics, _) = Self.rig(codes: codes, cancel: true)
            for player in ["T:0", "T:1"] { rig.archive.ratings.setStats(completedRaces: 9, wins: 0, for: player) }
            let race = try await rig.race(["T:0", "T:1"])
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1], to: 30, seq: &seq)
            for seat in 0..<2 { await race.leave(seat: seat, transport: transports[seat]) }
            await rig.runUntilEnded(race, limit: 1_400)
            #expect(await race.host.cancelled != nil)
            await rig.end(race)
            for player in ["T:0", "T:1"] {
                #expect(try await rig.archive.ratings.standing(of: player)?.completedRaces == 9)
            }
            #expect(analytics.raw().isEmpty)
        }
    }
}

/// A rating book whose reads fail.
struct UnreadableRatings: RatingBook {
    struct Down: Error {}
    func ratings(of playerIDs: [String]) async throws -> [String: PlayerRating] { throw Down() }
    func standing(of playerID: String) async throws -> PlayerStanding? { throw Down() }
    func reset(_ playerID: String, reason: String, at time: Date, config: RatingConfig) async throws -> Bool { throw Down() }
    func mirrorPending(_ playerIDs: [String]?, maxFailures: Int, limit: Int) async throws -> [MirrorEntry] { throw Down() }
    func mirrored(_ playerID: String, rating: Int) async throws { throw Down() }
    func mirrorFailed(_ playerID: String) async throws { throw Down() }
}
