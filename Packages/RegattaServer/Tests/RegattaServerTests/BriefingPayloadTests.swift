import Foundation
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
            #expect(briefing.fleet.map(\.name) == ["P0", "P1"] + (3...10).map { "Seat \($0)" })
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
