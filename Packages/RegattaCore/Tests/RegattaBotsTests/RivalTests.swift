import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #235: practice rivals. Their skill comes from the player's recent practice results (`Rivals.skill`), their seats
/// from the race seed (`Rivals.seats`); online setups never have any.
@Suite struct RivalTests {
    static func finishes(_ places: [Int], fleetSize: Int = 10, tier: BotTier? = nil) -> [PracticeFinish] {
        places.map { PracticeFinish(place: $0, fleetSize: fleetSize, tier: tier) }
    }

    /// Better recent places give a rival at least as much skill; only the newest `window` counted finishes count;
    /// the skill stays inside the coming race's tier band (or the Mixed union); no counted finish, no rival.
    @Test func rivalSkillTracksRecentResults() throws {
        // Empty history, or only small fleets or impossible places: no rivals (the first race, a fresh install).
        #expect(Rivals.skill(history: [], tier: nil) == nil)
        #expect(Rivals.skill(history: Self.finishes([1, 2, 1], fleetSize: 3), tier: nil) == nil)
        #expect(Rivals.skill(history: Self.finishes([0, 11]), tier: nil) == nil)

        let tiers: [BotTier?] = [nil] + BotTier.allCases.map { $0 }
        for tier in tiers {
            // Monotonic: the same history with the newest place better never lowers the skill.
            var previous = -Double.infinity
            for place in (1...10).reversed() {
                let skill = try #require(Rivals.skill(history: Self.finishes([5, 6, place]), tier: tier))
                #expect(skill >= previous)
                previous = skill
            }
            // A steadily better player gets a steadily better rival.
            var last = -Double.infinity
            for place in (1...10).reversed() {
                let skill = try #require(Rivals.skill(history: Self.finishes(Array(repeating: place, count: 5)),
                                                      tier: tier))
                #expect(skill >= last)
                last = skill
            }
        }

        // Winning a Mixed race every time is the top of the Mixed band; last every time its bottom.
        let mixed = BotTier.mixedBand
        #expect(Rivals.skill(history: Self.finishes([1, 1, 1]), tier: nil) == mixed.upperBound)
        #expect(Rivals.skill(history: Self.finishes([10, 10]), tier: nil) == mixed.lowerBound)

        // Only the newest `window` counted finishes count: old wins don't lift a run of last places.
        let old = Self.finishes(Array(repeating: 1, count: 5))
        let recent = Self.finishes(Array(repeating: 10, count: Rivals.window))
        #expect(Rivals.skill(history: old + recent, tier: nil) == Rivals.skill(history: recent, tier: nil))
        // A small fleet among them doesn't count, and doesn't push a counted finish out of the window.
        let withSmall = Self.finishes([1]) + Self.finishes([1], fleetSize: 3) + Self.finishes([10, 10, 10, 10])
        #expect(Rivals.skill(history: withSmall, tier: nil)
                == Rivals.skill(history: Self.finishes([1, 10, 10, 10, 10]), tier: nil))

        // Clamped to the coming race's tier: a Mixed-fleet winner's rival in a Club race stays a Club bot, a
        // last-placer's rival in a National race a National bot.
        for tier in BotTier.allCases {
            let band = tier.skillBand
            #expect(Rivals.skill(history: Self.finishes([1, 1, 1]), tier: tier).map(band.contains) == true)
            #expect(Rivals.skill(history: Self.finishes([10, 10, 10]), tier: tier).map(band.contains) == true)
        }
        #expect(Rivals.skill(history: Self.finishes([1, 1]), tier: .club) == BotTier.club.skillBand.upperBound)
        #expect(Rivals.skill(history: Self.finishes([10, 10]), tier: .national)
                == BotTier.national.skillBand.lowerBound)
        // A finish counts through its own race's band: midfield in a National race is worth more than in a Club one.
        let national = try #require(Rivals.skill(history: Self.finishes([5], tier: .national), tier: nil))
        let club = try #require(Rivals.skill(history: Self.finishes([5], tier: .club), tier: nil))
        #expect(national > club)

        // The history keeps the newest `kept`.
        var history: [PracticeFinish] = []
        for place in 1...(Rivals.kept + 3) {
            history = Rivals.recording(PracticeFinish(place: place, fleetSize: 20, tier: nil), in: history)
        }
        #expect(history.count == Rivals.kept)
        #expect(history.last?.place == Rivals.kept + 3)
    }

    /// Online-shaped setups (every server and online path builds its roster and controllers from the setup alone):
    /// no rival, and every bot at her ordinary Mixed-fleet draw.
    @Test func noRivalsInOnlineSetup() throws {
        for seed in [1, 7, 42, 1_000_003] as [UInt64] {
            for humans in [1, 2, 4, 8] {
                let seats = Array(repeating: SeatKind.human, count: humans)
                    + Array(repeating: SeatKind.bot, count: 10 - humans)
                let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: seats)
                let roster = FleetRoster(setup: setup)
                #expect(roster.rivals.isEmpty)
                #expect(roster.entries.allSatisfy { !$0.isRival })
                let controllers = SeatControllers(setup: setup)
                for seat in setup.seats.indices where setup.seats[seat] == .bot {
                    #expect(controllers[seat].driver?.style == BotDriver(seat: seat, raceSeed: setup.raceSeed).style)
                }
            }
        }
    }

    /// Rival seats are bot seats, the same for the same race seed, two from five bot seats and one below.
    @Test func rivalSeatsAreBotSeatsStablePerSeed() throws {
        for seed in 1...50 as ClosedRange<UInt64> {
            let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: [.human] + Array(repeating: .bot, count: 9))
            let rivals = Rivals.seats(setup: setup)
            #expect(rivals.count == 2)
            #expect(rivals.allSatisfy { setup.seats[$0] == .bot })
            #expect(Rivals.seats(setup: setup) == rivals)
            let roster = FleetRoster(setup: setup, rivals: rivals)
            #expect(roster.rivals == rivals)
            #expect(roster.entries.allSatisfy { !$0.isRival || $0.isBot })
            // Picking rivals moves no name.
            #expect(roster.entries.map(\.sailingName) == FleetRoster(setup: setup).entries.map(\.sailingName))
        }
        for botCount in 1...4 {
            let setup = try RaceSetup(raceSeed: RaceSeed(9), seats: [.human] + Array(repeating: .bot, count: botCount))
            #expect(Rivals.seats(setup: setup).count == 1)
        }
        #expect(Rivals.seats(raceSeed: RaceSeed(9), botSeats: []).isEmpty)
        // Different seeds pick different rivals somewhere.
        let picks = Set((1...20 as ClosedRange<UInt64>).map {
            Rivals.seats(raceSeed: RaceSeed($0), botSeats: Array(1..<10))
        })
        #expect(picks.count > 1)
    }
}
