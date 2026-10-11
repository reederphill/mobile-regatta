import Foundation
import RegattaBots
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// #147: the 15 s briefing's data, sent with the hand-off at fleet lock: everything #130's `BriefingModel` reads from the
/// public setup (#16, #15), the fleet with ratings, bot labels and liveries, her seat and the timings; never the wind seed.
@Suite(.timeLimit(.minutes(1))) struct BriefingPayloadTests {
    static let ownLivery = Livery(design: DesignID("skiff-stripe"), colours: [SwatchID("signal-red"), SwatchID("white")], sailNumber: 42)

    @Test func carriesEveryFieldAndNoWindSeed() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 147),
                                    now: { clock.now },
                                    liveries: { $0.teamPlayerID == "T:0" ? Self.ownLivery : nil },
                                    launch: { fleet, closed in try await log.record(fleet, closed) })
        for index in 0..<2 { try await queue.join(QueueMatchmakerTests.player(index)) }
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)

        for index in 0..<2 {
            let handOff = try await queue.handOff(for: "T:\(index)")
            let briefing = try #require(handOff.briefing)
            // The public setup: venue, conditions, class, rules, laps, sequence (BriefingModel words the wind, shifts,
            // puffs, current and course from these files).
            #expect(briefing.setup == fleet.setup)
            #expect(briefing.setup.venue == fleet.drawn.pairing.venue.ref)
            #expect(briefing.setup.conditions == fleet.drawn.pairing.conditions.ref)
            #expect(briefing.tide == .none)
            #expect(briefing.yourSeat == index && briefing.isMe(index))
            #expect(briefing.briefingSeconds == 15)
            #expect(briefing.gunInSeconds == 75)
            // The fleet by seat: the humans by name rated 1500 (#151 later), the bots labelled and unrated, everyone in a
            // livery, sail numbers unique.
            #expect(briefing.fleet.count == 10)
            #expect(briefing.fleet.map(\.name) == ["P0", "P1"] + FleetRoster(setup: fleet.setup).entries.dropFirst(2).compactMap(\.sailingName))
            #expect(briefing.fleet.map(\.isBot) == [false, false] + Array(repeating: true, count: 8))
            #expect(briefing.fleet.map(\.rating) == [1500, 1500] + Array(repeating: nil, count: 8))
            #expect(briefing.fleet[0].livery == Self.ownLivery)
            #expect(briefing.fleet.allSatisfy { !$0.livery.design.rawValue.isEmpty && !$0.livery.colours.isEmpty })
            #expect(Set(briefing.fleet.map(\.livery.sailNumber)).count == 10)

            // Over the wire and back: the same briefing, and the wind seed's bytes nowhere in it.
            let frame = try Frame(seq: 1, tick: 0, message: .raceSessionReply(ServiceReply(id: 1, result: .handOff(handOff.wire)))).encoded()
            guard case .raceSessionReply(let reply) = try Frame(decoding: frame).message, case .handOff(let wire) = reply.result else {
                Issue.record("not a hand-off")
                return
            }
            #expect(HandOff(wire: wire) == handOff)
            let seed = fleet.windSeed.value
            for bytes in [withUnsafeBytes(of: seed.littleEndian, Array.init), withUnsafeBytes(of: seed.bigEndian, Array.init)] {
                #expect(!Self.contains(frame, bytes), "the wind seed is in the briefing")
            }
            #expect(!String(decoding: frame, as: UTF8.self).contains(String(seed, radix: 16)))
        }
    }

    /// #149: a bot shows under her sailing name with the bot label, in the free starter livery her seat's seed draws
    /// (the seed the client draws it from), and with no rating; a human's rating is the one the fleet's median came from.
    @Test func botsHaveSailingNamesTheSeedsLiveryAndNoRating() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 149),
                                    now: { clock.now },
                                    ratings: { $0.teamPlayerID == "T:0" ? 1720 : 1480 },
                                    launch: { fleet, closed in try await log.record(fleet, closed) })
        for index in 0..<3 { try await queue.join(QueueMatchmakerTests.player(index)) }
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)
        let briefing = try #require(try await queue.handOff(for: "T:1").briefing)
        let catalogue = try #require(OnlineBriefing.catalogue)
        let setup = fleet.setup
        #expect(briefing.fleet.count == 10)
        #expect(briefing.fleet.prefix(3).map(\.rating) == [1720, 1480, 1480])
        #expect(briefing.fleet.prefix(3).allSatisfy { !$0.isBot })
        let names = FleetRoster(setup: setup)
        for seat in 3..<10 {
            let bot = briefing.fleet[seat]
            #expect(bot.isBot && bot.rating == nil)
            #expect(bot.name == names[seat].sailingName && FleetRoster.sailingNames.contains(bot.name))
            let drawn = try #require(catalogue.botLivery(boatClass: setup.boatClass.id, seed: botSeed(raceSeed: setup.raceSeed, seat: seat)))
            // Hers but for the sail number, which the fleet may have moved (#21).
            #expect(bot.livery.design == drawn.design && bot.livery.colours == drawn.colours)
            let design = try #require(catalogue.designs(for: setup.boatClass.id).first { $0.id == bot.livery.design })
            #expect(design.acquisition.isFree)
        }
        #expect(Set(briefing.fleet.map(\.name)).count == 10)
        #expect(Set(briefing.fleet.map(\.livery.sailNumber)).count == 10)
        // Every human gets the same fleet.
        #expect(try await queue.handOff(for: "T:0").briefing?.fleet == briefing.fleet)
    }

    /// A rejoin's hand-off has no briefing: the briefing is over by the gun.
    @Test func aRejoinHasNoBriefing() async throws {
        let rig = LifecycleRig()
        let race = try await rig.race(["T:0"])
        await rig.run(race, to: 30)
        let offer = try await rig.lifecycle.rejoin("T:0")
        #expect(offer.handOff.briefing == nil)
    }

    /// The briefing's sail numbers are the fleet's: a number two boats share shows another on the later one (#21).
    @Test func sharedSailNumbersAreMadeUnique() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .human, .bot])
        var random = SeededRandom(seed: 1)
        var raceDraw = RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 1))
        let drawn = raceDraw.draw(using: &random)
        let draw = try #require(drawn)
        let fleet = LockedFleet(raceID: UUID(), setup: setup, windSeed: WindSeed(1),
                                humans: [QueueMatchmakerTests.player(0), QueueMatchmakerTests.player(1)], drawn: draw)
        let payloads = OnlineBriefing.payloads(fleet, stored: [Self.ownLivery, Self.ownLivery], settings: QueueSettings())
        #expect(payloads.count == 2)
        let numbers = payloads[1].fleet.map(\.livery.sailNumber)
        #expect(numbers[0] == 42 && numbers[1] != 42 && Set(numbers).count == 3)
        #expect(payloads[0].fleet == payloads[1].fleet)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}
