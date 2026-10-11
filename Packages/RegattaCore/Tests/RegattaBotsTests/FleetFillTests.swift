import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #149: an online fleet's bots. Their rating is the fleet's median, give or take 150, their skill the versioned
/// map's for it, their name and livery their seat's seed's.
@Suite struct FleetFillTests {
    static let seeds: ClosedRange<UInt64> = 1...200

    static func setup(seed: UInt64, humans: Int = 3, boats: Int = 10) throws -> RaceSetup {
        try RaceSetup(raceSeed: RaceSeed(seed), seats: (0..<boats).map { $0 < humans ? .human : .bot }, laps: 1)
    }

    @Test func bundledRatingMapLoads() throws {
        let map = try BotRatingMap.load(version: BotRatingMap.currentVersion)
        #expect(map == BotRatingMap.bundled)
        #expect(map.id == "bot-ratings" && map.version == 1 && map.isValid)
        // The owner's placeholder (#149): a new player's rating is the top of Club.
        #expect(abs(map.skill(rating: 1500) - 0.55) < 1e-12)
        #expect(throws: (any Error).self) { try BotRatingMap.load(version: 99) }
    }

    @Test func aCorruptRatingMapIsRefused() throws {
        func file(_ points: String, id: String = "bot-ratings", version: Int = 1) -> Data {
            Data(#"{"id":"\#(id)","version":\#(version),"points":[\#(points)]}"#.utf8)
        }
        let good = #"{"rating":1000,"skill":0.4},{"rating":2000,"skill":0.9}"#
        #expect(try BotRatingMap.decode(file(good), version: 1).points.count == 2)
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(good, id: "bot-tiers"), version: 1) }
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(good, version: 2), version: 1) }
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(#"{"rating":1000,"skill":0.4}"#), version: 1) }
        // Ratings must rise, skills must not fall, and a skill is 0…1.
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(#"{"rating":2000,"skill":0.4},{"rating":1000,"skill":0.9}"#), version: 1) }
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(#"{"rating":1000,"skill":0.9},{"rating":2000,"skill":0.4}"#), version: 1) }
        #expect(throws: (any Error).self) { try BotRatingMap.decode(file(#"{"rating":1000,"skill":0.4},{"rating":2000,"skill":1.2}"#), version: 1) }
        #expect(throws: (any Error).self) { try BotRatingMap.decode(Data("not json".utf8), version: 1) }
    }

    @Test func ratingMapIsMonotonicAndClamped() {
        let map = BotRatingMap.bundled
        let range = BotRatingMap.skillRange
        #expect(range == BotTier.club.skillBand.lowerBound...1)
        var last = -Double.infinity
        for rating in stride(from: -500, through: 4000, by: 7) {
            let skill = map.skill(rating: rating)
            #expect(range.contains(skill), "rating \(rating) sails at \(skill)")
            #expect(skill >= last, "skill falls at rating \(rating)")
            last = skill
        }
        // The points themselves, and flat outside them.
        for point in map.points { #expect(abs(map.skill(rating: point.rating) - point.skill) < 1e-12) }
        #expect(map.skill(rating: 0) == map.skill(rating: map.points[0].rating))
        #expect(map.skill(rating: 9999) == 1)
        // Half way between two points is half way between their skills.
        #expect(abs(map.skill(rating: 1250) - 0.45) < 1e-12)
        // A map whose points reach outside the bots' range is still kept inside it.
        let wide = BotRatingMap(version: 1, points: [.init(rating: 0, skill: 0), .init(rating: 100, skill: 1)])
        #expect(wide.skill(rating: 0) == range.lowerBound && wide.skill(rating: 100) == 1)
    }

    @Test func fillOffsetIsWithin150AndIsPerSeatDeterministic() {
        var offsets: Set<Int> = []
        for seed in Self.seeds {
            for seat in 0..<16 {
                let bot = botSeed(raceSeed: RaceSeed(seed), seat: seat)
                let offset = FleetFill.ratingOffset(seed: bot)
                #expect((-150...150).contains(offset))
                #expect(FleetFill.ratingOffset(seed: bot) == offset)
                offsets.insert(offset)
                for median in [1000, 1500, 2100] {
                    let fill = FleetFill(medianRating: median)
                    let plan = fill.plan(seat: seat, raceSeed: RaceSeed(seed))
                    #expect(plan.rating == median + offset)
                    #expect(plan == fill.plan(seat: seat, raceSeed: RaceSeed(seed)))
                    #expect(plan.mapVersion == BotRatingMap.currentVersion)
                }
            }
        }
        // A spread, not one value: most of the 301 offsets turn up over 3200 seats, both ends' halves among them.
        #expect(offsets.count > 250)
        #expect(offsets.contains { $0 < -100 } && offsets.contains { $0 > 100 })
        // The offset has a stream of its own (ASCII "botrate"), beside her handling's: drawing it moves no other draw.
        #expect(FleetFill.ratingStream == "botrate".utf8.reduce(0) { $0 << 8 | UInt64($1) })
        #expect(FleetFill.ratingStream != BotTier.handlingStream)
    }

    @Test func theMedianIsTheMiddleRating() {
        #expect(FleetFill.median([]) == nil)
        #expect(FleetFill.median([1500]) == 1500)
        #expect(FleetFill.median([1700, 1200, 1500]) == 1500)
        #expect(FleetFill.median([1400, 1500]) == 1450)
        #expect(FleetFill.median([1400, 1501, 900, 2000]) == 1451)
        #expect(FleetFill(humanRatings: [], fallback: 1500).medianRating == 1500)
        #expect(FleetFill(humanRatings: [1800, 1900, 2000], fallback: 1500).medianRating == 1900)
    }

    @Test func fillSkillNeverLeavesTheBotRange() {
        let range = BotRatingMap.skillRange
        for median in [-200, 400, 1000, 1500, 1800, 2200, 5000] {
            let fill = FleetFill(medianRating: median)
            for seed in Self.seeds.prefix(40) {
                for seat in 0..<16 {
                    let plan = fill.plan(seat: seat, raceSeed: RaceSeed(seed))
                    #expect(range.contains(plan.skill))
                    #expect(BotTier.holding(skill: plan.skill).handlingBand.contains(plan.handling))
                    let driver = fill.driver(seat: seat, raceSeed: RaceSeed(seed))
                    #expect(driver.style.skill == plan.skill && driver.handling == plan.handling)
                    #expect(driver.profile == nil && !driver.isCautious)
                }
            }
        }
        // Everyone at 1500 (until ratings exist): Club to the bottom of Regional, as the owner chose.
        let launch = FleetFill(medianRating: 1500)
        for seed in Self.seeds.prefix(40) {
            for seat in 0..<16 { #expect((0.49...0.65).contains(launch.plan(seat: seat, raceSeed: RaceSeed(seed)).skill)) }
        }
    }

    /// A fleet's bot is her skill and her seed, nothing else: the driver `BotDriver(seat:raceSeed:skill:handling:)`
    /// builds, so two processes, and a race sailed twice, get the same inputs from her.
    @Test func aFillBotSailsTheSameRaceEveryTime() throws {
        let seed = Self.seeds.lowerBound
        func sail() throws -> (digest: UInt64, inputs: Int) {
            let setup = try Self.setup(seed: seed, humans: 1, boats: 6)
            let race = Race(setup: setup, windSeed: WindSeed(seed &+ 77))
            let fill = FleetFill(medianRating: 1500)
            var seats = SeatControllers(setup.seats.indices.map { setup.seats[$0] == .bot ? .bot(fill.driver(seat: $0, raceSeed: setup.raceSeed)) : .human })
            for _ in 0..<(setup.startSequenceTicks + 10 * Race.tickRate) {
                seats.drive(race)
                race.step()
            }
            return (race.digest(), race.log?.inputs.count ?? 0)
        }
        let first = try sail(), second = try sail()
        #expect(first.digest == second.digest && first.inputs == second.inputs && first.inputs > 0)
        // Building fleet bots draws nothing of the race's: a race nobody built bots for starts the same.
        let setup = try Self.setup(seed: seed, humans: 1, boats: 6)
        let untouched = Race(setup: setup, windSeed: WindSeed(seed &+ 77)).digest()
        _ = FleetFill(medianRating: 1500).driver(seat: 1, raceSeed: setup.raceSeed)
        #expect(Race(setup: setup, windSeed: WindSeed(seed &+ 77)).digest() == untouched)
    }

    @Test func takeoverNameIsFreeAndNoOtherNameMoves() throws {
        for seed in Self.seeds {
            let setup = try Self.setup(seed: seed, humans: 6, boats: 16)
            let roster = FleetRoster(setup: setup)
            var dressing = BotDressing(setup: setup)
            #expect(dressing.names == roster.entries.map(\.sailingName))
            let before = dressing.names
            var seen = Set(before.compactMap { $0 })
            // Every human leaves, in an order that isn't seat order.
            for seat in [4, 0, 5, 2, 1, 3] {
                #expect(!dressing.isBot(seat: seat))
                let name = dressing.takeOver(seat: seat)
                #expect(FleetRoster.sailingNames.contains(name))
                #expect(seen.insert(name).inserted, "\(name) is taken (seed \(seed), seat \(seat))")
                #expect(dressing.isBot(seat: seat) && dressing.takeOver(seat: seat) == name)
                for other in setup.seats.indices where before[other] != nil { #expect(dressing.names[other] == before[other]) }
            }
            #expect(Set(dressing.names.compactMap { $0 }).count == 16)
        }
        // With no name in her way she gets the one her seed picks.
        let seed = Self.seeds.lowerBound
        let alone = try RaceSetup(raceSeed: RaceSeed(seed), seats: [.human, .human], laps: 1)
        var dressing = BotDressing(setup: alone)
        let names = FleetRoster.sailingNames
        #expect(dressing.takeOver(seat: 1) == names[Int(botSeed(raceSeed: RaceSeed(seed), seat: 1) % UInt64(names.count))])
    }

    @Test func botLiveryIsAFreeStarterFromTheSeatsSeed() throws {
        let catalogue = try LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1).content
        for seed in Self.seeds.prefix(50) {
            let setup = try Self.setup(seed: seed)
            let dressing = BotDressing(setup: setup)
            for seat in setup.seats.indices {
                let livery = try #require(dressing.livery(seat: seat, catalogue: catalogue))
                // The seat's bot seed, as the client draws it (`FleetLiveries`): not the race seed plus the seat.
                #expect(livery == catalogue.botLivery(boatClass: setup.boatClass.id, seed: botSeed(raceSeed: setup.raceSeed, seat: seat)))
                let design = try #require(catalogue.designs(for: setup.boatClass.id).first { $0.id == livery.design })
                #expect(design.acquisition.isFree)
                #expect(Livery.sailNumbers.contains(livery.sailNumber))
            }
        }
        let setup = try Self.setup(seed: Self.seeds.lowerBound)
        #expect(BotDressing.livery(seat: 3, raceSeed: setup.raceSeed, boatClass: "no-such-class", catalogue: catalogue) == nil)
    }

    @Test func aPrebuiltDriverTakesASeatOverAsAFleetBot() throws {
        let setup = try Self.setup(seed: Self.seeds.lowerBound, humans: 2, boats: 6)
        var seats = SeatControllers(setup: setup)
        let driver = FleetFill(medianRating: 1500).driver(seat: 1, raceSeed: setup.raceSeed)
        seats.takeOver(seat: 1, driver: driver)
        guard case .bot(let taken) = seats[1] else {
            Issue.record("seat 1 is \(seats[1])")
            return
        }
        #expect(taken.style == driver.style && taken.handling == driver.handling && !taken.isCautious)
        #expect(seats[0].isHuman)
    }
}
