import Foundation
import NIOWebSocket
import RegattaCore
import RegattaDevAPI
import RegattaLoadClient
import RegattaProtocol
@testable import RegattaServerKit
import Testing

/// #67 end to end, on the wall clock: a dev server on a free localhost port, and load clients sailing
/// instant races against it over real WebSockets. Serialized so the bandwidth run has the machine.
@Suite(.serialized)
struct EndToEndTests {
    private func withServer(_ config: ServerConfig = .dev(host: "127.0.0.1", port: 0),
                            _ body: (RegattaHTTPServer, LoadClientOptions) async throws -> Void) async throws {
        let server = try await RegattaHTTPServer.start(config: config)
        let options = LoadClientOptions(host: "127.0.0.1", port: server.port, timeout: .seconds(60))
        do {
            try await body(server, options)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func loadClientCompletesAFullRaceAgainstALocalServer() async throws {
        try await withServer { server, options in
            let health = try await DevClient.health(host: options.host, port: options.port)
            #expect(health.status == "ok")
            #expect(health.environment == "dev")
            #expect(health.simulationVersion == RegattaCore.simulationVersion)

            let (race, results) = try await LoadClient.sailInstantRace(
                InstantRaceRequest(clients: 1, raceSeconds: 3, startSeconds: 1, seed: 67), options: options)
            #expect(race.fleetSize == 10)
            #expect(race.bots == 9)
            let report = try #require(try results.first?.get())
            // RaceStart, the race, RaceClosed: sailed to the close.
            #expect(report.completed)
            #expect(report.finalStatus == "finished")
            #expect(report.heldSent > 0)
            #expect(report.pingsSent > 0)
            #expect(report.roundTrips.count > 0)
            // Reported, not gated: a loose bound, so a loaded runner doesn't fail it.
            #expect(report.roundTrips.max < 5000)
            #expect(report.snapshotsRefused == 0)
            #expect(report.undecodableFrames == 0)
            // The race leaves the server when it closes.
            for _ in 0..<100 where await server.registry.count > 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(await server.registry.count == 0)
        }
    }

    /// #27 with a full fleet of humans: every client's downstream about 5 KB/s at most, and under 1 MB
    /// for the race with its join. Printed for the PR; see the README for how it scales with race length.
    @Test func sixteenLoadClientsInOneRaceStayWithinTheBandwidthBudget() async throws {
        try await withServer { _, options in
            let (race, results) = try await LoadClient.sailInstantRace(
                InstantRaceRequest(clients: 16, raceSeconds: 8, startSeconds: 2, seed: 16), options: options)
            #expect(race.fleetSize == 16)
            #expect(race.bots == 0)
            #expect(results.count == 16)
            let reports = try results.map { try $0.get() }
            #expect(Set(reports.map(\.seat)) == Set(0..<16))
            for report in reports {
                #expect(report.completed, "seat \(report.seat): \(report.finalStatus)")
                #expect(BandwidthBudget.issue27.violations(report) == [])
                #expect(report.downstreamBytesPerSecond > 1000, "a 16-boat race sends snapshots at 10 Hz")
            }
            let worst = reports.map(\.downstreamBytesPerSecond).max() ?? 0
            let most = reports.map(\.bytesReceived).max() ?? 0
            let join = reports.map(\.joinBytes).max() ?? 0
            print("16 clients: worst downstream \(Int(worst)) B/s, most bytes \(most) B (join \(join) B) in \(race.startSeconds + (race.raceSeconds ?? 0)) s")
        }
    }

    // MARK: - Handshake and join refusals

    private func connect(_ options: LoadClientOptions) async throws -> WebSocketRaceTransport {
        try await WebSocketRaceTransport.connect(host: options.host, port: options.port, clock: { 0 })
    }

    private func send(_ message: Message, on transport: WebSocketRaceTransport) throws {
        transport.send(try Frame(seq: 1, tick: 0, message: message).encoded())
    }

    /// Frames until one arrives or the connection has closed.
    private func frames(on transport: WebSocketRaceTransport) async throws -> [Frame] {
        for _ in 0..<500 {
            let frames = transport.receive()
            if !frames.isEmpty { return try frames.map { try Frame(decoding: $0) } }
            if !transport.isConnected { return [] }
            try await Task.sleep(for: .milliseconds(10))
        }
        return []
    }

    private func closed(_ transport: WebSocketRaceTransport) async throws -> Bool {
        for _ in 0..<500 where transport.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        return !transport.isConnected
    }

    @Test func theSimulationRevisionMustMatchNotThePlatform() {
        let server = "4/swift-6.3.3/glibc-2.39/x86_64"
        #expect(SeatConnection.canSail(clientSimulationVersion: "4/swift-6.3.3/darwin/arm64", server: server))
        #expect(SeatConnection.canSail(clientSimulationVersion: server, server: server))
        #expect(!SeatConnection.canSail(clientSimulationVersion: "3/swift-6.3.3/darwin/arm64", server: server))
        #expect(!SeatConnection.canSail(clientSimulationVersion: "44/swift-6.3.3/darwin/arm64", server: server))
        #expect(!SeatConnection.canSail(clientSimulationVersion: "4", server: server))
        #expect(!SeatConnection.canSail(clientSimulationVersion: "", server: server))
    }

    @Test func aStaleSimulationVersionGetsUpdateRequired() async throws {
        try await withServer { _, options in
            let transport = try await connect(options)
            try send(.hello(Hello(clientBuild: "test", simulationVersion: "0/old", files: [])), on: transport)
            let reply = try await frames(on: transport)
            #expect(reply.first?.message.type == .updateRequired)
            if case .updateRequired(let update) = reply.first?.message { #expect(update.reason == .simulationVersion) }
            #expect(try await closed(transport))
            await transport.close()
        }
    }

    @Test func aConnectionThatDoesNotJoinInTimeIsClosed() async throws {
        var config = ServerConfig.dev(host: "127.0.0.1", port: 0)
        config.handshakeTimeout = .milliseconds(300)
        try await withServer(config) { _, options in
            // Never says anything.
            let silent = try await connect(options)
            #expect(try await closed(silent))
            #expect(silent.closeReason.code == .policyViolation)
            await silent.close()

            // Says Hello, then never joins.
            let greeted = try await connect(options)
            try send(.hello(Hello(clientBuild: "test", files: [])), on: greeted)
            #expect(try await frames(on: greeted).first?.message.type == .helloAck)
            #expect(try await closed(greeted))
            #expect(greeted.closeReason.code == .policyViolation)
            await greeted.close()
        }
    }

    @Test func forgedTakenAndBotSeatTokensAreRefused() async throws {
        try await withServer { server, options in
            let race = try await DevClient.instantRace(InstantRaceRequest(clients: 1, startSeconds: 60, seed: 5),
                                                         host: options.host, port: options.port)
            let good = [UInt8](try #require(Data(base64Encoded: race.tokens[0])))
            var forged = good
            forged[17] = 1 // seat 1, a bot's

            func join(_ token: [UInt8]) async throws -> (WebSocketRaceTransport, [Frame]) {
                let transport = try await connect(options)
                try send(.hello(Hello(clientBuild: "test", files: [])), on: transport)
                #expect(try await frames(on: transport).first?.message.type == .helloAck)
                try send(.joinRace(JoinRace(token: token)), on: transport)
                return (transport, try await frames(on: transport))
            }

            let (forgedClient, forgedReply) = try await join(forged)
            #expect(forgedReply.isEmpty)
            #expect(try await closed(forgedClient))
            #expect(forgedClient.closeReason.code == .policyViolation)
            await forgedClient.close()

            // A bot's seat, properly signed, isn't a player's to take.
            let key = server.config.tokenKey
            let botSeat = RaceToken(raceID: try #require(UUID(uuidString: race.raceID)), seat: 1, expiresAt: race.tokensExpireAt)
            let (botClient, botReply) = try await join(try #require(botSeat.signed(with: key)))
            #expect(botReply.isEmpty)
            #expect(try await closed(botClient))
            await botClient.close()

            let (seated, seatedReply) = try await join(good)
            #expect(seatedReply.first?.message.type == .raceStart)
            // The same seat again while it's held: refused, and the first connection keeps it.
            let (second, secondReply) = try await join(good)
            #expect(secondReply.isEmpty)
            #expect(try await closed(second))
            #expect(seated.isConnected)
            await second.close()
            await seated.close()
        }
    }
}
