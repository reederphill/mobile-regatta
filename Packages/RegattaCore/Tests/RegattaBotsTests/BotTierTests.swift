import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #102: bot tiers are skill bands from the versioned bot-tier file, mapped to skill in RegattaBots (for practice
/// setup, #131), and a tier is only ever what its bots choose to send: never their boat.
@Suite struct BotTierTests {
    /// The bands tile the skills a tier sails at, in order; a tier maps a position in its band, and a bot's seed, to a
    /// skill inside it; the Mixed-fleet draw deals the tiers by the file's shares.
    @Test func botTierMapsToSkill() throws {
        let file = BotTierFile.bundled
        #expect(file.id == "bot-tiers" && file.version == BotTierFile.currentVersion)
        #expect(file.minPlaceGap == 1.0, "the placeholder place gap")
        let bands = BotTier.allCases.map(\.skillBand)
        #expect(BotTier.allCases == [.club, .regional, .national])
        for (lower, upper) in zip(bands, bands.dropFirst()) {
            #expect(lower.upperBound == upper.lowerBound, "bands meet: \(lower) then \(upper)")
        }
        #expect(bands.first!.lowerBound >= 0 && bands.last!.upperBound == 1)

        for tier in BotTier.allCases {
            #expect(tier.skill(at: 0) == tier.skillBand.lowerBound)
            #expect(tier.skill(at: 1) == tier.skillBand.upperBound)
            #expect(tier.skill(at: 0.5) == (tier.skillBand.lowerBound + tier.skillBand.upperBound) / 2)
            #expect(tier.skill(at: -1) == tier.skillBand.lowerBound && tier.skill(at: 2) == tier.skillBand.upperBound)
            for seat in 0..<16 {
                let raceSeed = RaceSeed(UInt64(seat) * 7 + 1)
                let seed = botSeed(raceSeed: raceSeed, seat: seat)
                let skill = tier.skill(seed: seed)
                #expect(tier.skillBand.contains(skill))
                #expect(skill == tier.skill(seed: seed), "a seed's skill never changes")
                #expect(BotDriver(seat: seat, raceSeed: raceSeed, tier: tier).style.skill == skill)
            }
        }
        // A tier's bots keep a spread of skills.
        let nationals = (0..<50).map { BotTier.national.skill(seed: botSeed(raceSeed: RaceSeed(9), seat: $0)) }
        #expect((nationals.max() ?? 0) - (nationals.min() ?? 0) > 0.1)

        // The Mixed-fleet draw: each tier near its share of 3000 bots, and the app's default bot is exactly that.
        let total = BotTier.allCases.reduce(0) { $0 + file[$1].mixShare }
        let drawn = (0..<3000).map { BotTier.mixedFleetDraw(seed: botSeed(raceSeed: RaceSeed(UInt64($0 / 10)), seat: $0 % 10)).tier }
        for tier in BotTier.allCases {
            let share = Double(drawn.filter { $0 == tier }.count) / Double(drawn.count)
            #expect(abs(share - file[tier].mixShare / total) < 0.03, "\(tier): \(share)")
        }
        // One draw of a bot's seed deals her tier and her skill in it, so a Mixed fleet's skills spread over every
        // band; the prototype's skill (0.35 + 0.65 × that draw) is exactly the Mixed fleet's with these placeholders.
        for seat in 0..<10 {
            let raceSeed = RaceSeed(4)
            let seed = botSeed(raceSeed: raceSeed, seat: seat)
            let drawn = BotTier.mixedFleetDraw(seed: seed)
            #expect(drawn.tier.skillBand.contains(drawn.skill))
            #expect(BotDriver(seat: seat, raceSeed: raceSeed).style.skill == drawn.skill)
            #expect(abs(drawn.skill - (0.35 + 0.65 * BotTier.skillDraw(seed: seed))) < 1e-12)
        }
    }

    /// #19: weaknesses, not a slower boat. Nothing a tier sets reaches the race: every tier's fleet sails the same
    /// setup and class, a style and its weaknesses hold no physics, and a tier's race replays from its input log with
    /// no brains to the same digest (ADR 0002).
    @Test func allTiersShareBoatPhysics() throws {
        let physicsWords = ["speed", "polar", "hull", "mass", "drag", "rudderRate", "turnRate", "sail", "class"]
        for type in [Mirror(reflecting: BotStyle(skill: 0.5, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)),
                     Mirror(reflecting: BotWeaknesses(skill: 0.5)), Mirror(reflecting: BotTierFile.bundled.club)] {
            for label in type.children.compactMap(\.label) {
                #expect(!physicsWords.contains { label.lowercased().contains($0.lowercased()) }, "per-seat physics: \(label)")
            }
        }
        var classes: [BoatClass] = []
        var setups: [RaceSetup] = []
        for tier in BotTier.allCases {
            let race = botRace(seats: Array(repeating: .bot, count: 6), prestartSeconds: 30, seed: 31)
            for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
            var controllers = SeatControllers(race.boats.indices.map {
                .bot(BotDriver(seat: $0, raceSeed: race.setup.raceSeed, tier: tier))
            })
            sail(race, &controllers, ticks: Race.tickRate * 90)
            classes.append(race.boatClass)
            setups.append(race.setup)
            let log = try #require(race.log)
            #expect(try Replayer.replay(log).digest() == race.digest(), "\(tier) replays with no brains")
        }
        #expect(Set(setups.map { "\($0)" }).count == 1, "every tier's fleet sails the same setup")
        #expect(classes.allSatisfy { $0 == classes[0] }, "and the same class")
    }

    /// #222, #263: a bot's roll tacks hit more often the more skilled she is: never below the skill floor, ~30 % at
    /// Club's centre, ~80 % at National's (placeholders). The rate only; #263 sends the roll.
    @Test func rollHitRateRisesWithSkill() {
        let skills = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }
        let rates = skills.map { BotWeaknesses(skill: $0).rollHitRate }
        for (a, b) in zip(rates, rates.dropFirst()) { #expect(b >= a) }
        #expect(zip(skills, rates).allSatisfy { $0 >= BotWeaknesses.rollSkillFloor || $1 == 0 }, "no rolls below the floor")
        func centre(_ tier: BotTier) -> Double { tier.skill(at: 0.5) }
        let club = BotWeaknesses(skill: centre(.club)).rollHitRate
        let regional = BotWeaknesses(skill: centre(.regional)).rollHitRate
        let national = BotWeaknesses(skill: centre(.national)).rollHitRate
        #expect(abs(club - 0.3) < 0.05 && abs(national - 0.8) < 0.05, "club \(club), national \(national)")
        #expect(club < regional && regional < national)
        #expect(rates.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
