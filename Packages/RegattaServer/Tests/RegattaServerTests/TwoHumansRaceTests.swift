import Foundation
import RegattaCore
import RegattaLoadClient
import RegattaProtocol
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// Two people in one race (#162): the real server in process, and for each player the client's own online session over
/// the real `/service` WebSocket, the queue, the hand-off, and a race client on `/race`. No simulator: what the app adds
/// on top is its own tests' and the e2e run's.
@Suite(.serialized, .timeLimit(.minutes(2))) struct TwoHumansRaceTests {
    /// A dev server whose queue locks 2 s after the first join into a race with a 1 s briefing and a 2 s sequence, closed
    /// `raceSeconds` after the gun.
    static func config(raceSeconds: Int = 3) -> ServerConfig {
        var config = ServerConfig.dev()
        config.queue.lockAfter = 2
        config.queue.catchFinishers = nil
        config.queue.briefingTicks = Race.tickRate
        config.queue.startSequenceTicks = 3 * Race.tickRate
        config.lifecycle.queueRaceCloseAtTick = raceSeconds * Race.tickRate
        return config
    }

    static func options(port: Int) -> QueuePlayer.Options {
        var options = QueuePlayer.Options()
        options.load.port = port
        options.load.timeout = .seconds(60)
        options.lockTimeout = .seconds(30)
        return options
    }

    @Test func twoQueuedHumansShareOneFleetAndJoinTheirSeats() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        let options = Self.options(port: server.port)
        do {
            async let first = QueuePlayer.play(number: 1, options: options)
            async let second = QueuePlayer.play(number: 2, options: options)
            let (one, two) = try await (first, second)
            // One fleet, a seat each.
            #expect(one.handOff.raceID == two.handOff.raceID)
            let briefing = try #require(one.handOff.briefing), other = try #require(two.handOff.briefing)
            #expect(briefing.yourSeat != other.yourSeat)
            #expect(Set([briefing.yourSeat, other.yourSeat]) == [0, 1])
            for payload in [briefing, other] {
                let people = payload.fleet.filter { !$0.isBot }.map(\.name).sorted()
                #expect(people == ["Dev 1", "Dev 2"], "each sees the other as a person: \(payload.fleet.map(\.name))")
                #expect(payload.fleet.count >= 10, "bots fill the fleet")
            }
            // Each joined her own seat with her token and sailed to the close.
            #expect(one.load?.seat == briefing.yourSeat && two.load?.seat == other.yourSeat)
            #expect(one.load?.completed == true && two.load?.completed == true)
            // And the service told each the same closed race, through the session's results stream.
            let closed = try #require(one.closed), same = try #require(two.closed)
            #expect(closed.raceID == one.handOff.raceID && same.raceID == closed.raceID)
            #expect(closed.results.rows.count == closed.roster.count && closed.results == same.results)
            #expect(!closed.roster[0].isBot && !closed.roster[1].isBot)
            // Two people at the gun: a rated race, for both.
            #expect(closed.results.rated)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func aLeaverBeforeTheGunBecomesABotOnTheOthersRoster() async throws {
        let server = try await RegattaHTTPServer.start(config: Self.config())
        var leaving = Self.options(port: server.port)
        leaving.leavesInBriefing = true
        let staying = Self.options(port: server.port)
        do {
            async let stayer = QueuePlayer.play(number: 11, options: staying)
            async let leaver = QueuePlayer.play(number: 12, options: leaving)
            let (stayed, left) = try await (stayer, leaver)
            #expect(stayed.handOff.raceID == left.handOff.raceID)
            let seat = try #require(left.handOff.briefing?.yourSeat), mine = try #require(stayed.handOff.briefing?.yourSeat)
            let closed = try #require(stayed.closed)
            // Her seat sailed on under a bot's name; the one who stayed is still a person.
            #expect(closed.roster[seat].isBot && closed.roster[seat].name != "Dev 12")
            #expect(!closed.roster[mine].isBot && closed.roster[mine].name == "Dev 11")
            #expect(stayed.load?.completed == true && left.load == nil)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

/// The dev server's race length for queue races (#162, `QUEUE_RACE_SECONDS`).
@Suite(.serialized, .timeLimit(.minutes(2))) struct QueueRaceLengthTests {
    @Test func aQueueRaceClosesAtTheDevRaceLength() async throws {
        let server = try await RegattaHTTPServer.start(config: TwoHumansRaceTests.config(raceSeconds: 5))
        do {
            let started = ContinuousClock.now
            let outcome = try await QueuePlayer.play(number: 21, options: TwoHumansRaceTests.options(port: server.port))
            let took = ContinuousClock.now - started
            #expect(outcome.load?.completed == true)
            // 2 s to the lock, 3 s to the gun, 5 s of race: closed where it stood, nowhere near a sailed lap.
            #expect(took > .seconds(9) && took < .seconds(30), "took \(took)")
            let closed = try #require(outcome.closed)
            // Scored as it stood, not cancelled: a row for every boat, hers among them.
            #expect(closed.results.rows.count == closed.roster.count)
            // 5 s after the gun nobody has finished, and a boat that hasn't started yet is scored as one that never did.
            #expect(!closed.results.rows.contains { $0.code == .finished }, "\(closed.results.rows.map(\.code))")
            #expect(!closed.results.rated, "one person at the gun: unrated")
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

/// The loadclient's queue player (#162): the e2e run's second human.
@Suite(.serialized, .timeLimit(.minutes(2))) struct QueuePlayerTests {
    @Test func theHelperSailsToTheClose() async throws {
        let server = try await RegattaHTTPServer.start(config: TwoHumansRaceTests.config())
        do {
            var options = TwoHumansRaceTests.options(port: server.port)
            options.joinAfter = .milliseconds(300)
            let outcome = try await QueuePlayer.play(number: 7001, options: options)
            #expect(outcome.alias == "Dev 7001")
            #expect(outcome.load?.completed == true && outcome.load?.auditViolations == [])
            let briefing = try #require(outcome.handOff.briefing)
            #expect(briefing.fleet[briefing.yourSeat].name == "Dev 7001" && !briefing.fleet[briefing.yourSeat].isBot)
            #expect(outcome.closed?.isClosed == true)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

/// The dev server's race knobs (#162).
@Suite struct ServerConfigTests {
    @Test func devRaceKnobsAreDevOnly() throws {
        let env = ["ENV": "dev", "QUEUE_RACE_SECONDS": "90", "ALL_GONE_GRACE_SECONDS": "120"]
        let config = try ServerConfig.load(from: env)
        #expect(config.lifecycle.queueRaceCloseAtTick == 90 * Race.tickRate)
        #expect(config.lifecycle.allGone.graceTicks == 120 * Race.tickRate)
        // Unset: a queue race sails to its end, and the grace is G3's 30 s.
        let plain = try ServerConfig.load(from: ["ENV": "dev"])
        #expect(plain.lifecycle.queueRaceCloseAtTick == nil && plain.lifecycle.allGone.graceTicks == 30 * Race.tickRate)

        // Outside dev either one is a refusal to start, whatever else would refuse it.
        for name in ["QUEUE_RACE_SECONDS", "ALL_GONE_GRACE_SECONDS"] {
            #expect(throws: ServerConfigError.invalid(variable: name, value: "60", expected: "ENV=dev: it is a dev override")) {
                _ = try DevRaceKnobs(env: [name: "60"], environment: .other("prod"))
            }
            #expect(throws: ServerConfigError.self) { _ = try ServerConfig.load(from: ["ENV": "prod", name: "60"]) }
            for bad in ["0", "-3", "soon", "99999"] {
                #expect(throws: ServerConfigError.self) { _ = try ServerConfig.load(from: ["ENV": "dev", name: bad]) }
            }
        }
        #expect(try DevRaceKnobs(env: [:], environment: .other("prod")) == DevRaceKnobs(env: [:], environment: .dev))
    }
}
