import Foundation
import NIOCore
import NIOPosix
import RegattaClient
import RegattaCore
import RegattaDevAPI
import RegattaProtocol

/// What a load client does with the helm: a fixed, deterministic script, so runs compare.
public struct InputScript: Hashable, Sendable {
    /// Seconds per rudder change.
    public var rudderPeriod: Double
    /// The rudder values it cycles through.
    public var rudders: [Int8]
    /// Seconds between tacks (a tap), from the first period on. Nil: never tacks.
    public var tackEvery: Double?

    /// Weaves the helm every 2 s and tacks every 15 s: plenty of held inputs and some taps, well under the caps.
    public static let weave = InputScript(rudderPeriod: 2, rudders: [0, 40, 0, -40], tackEvery: 15)

    public init(rudderPeriod: Double, rudders: [Int8], tackEvery: Double?) {
        self.rudderPeriod = rudderPeriod
        self.rudders = rudders
        self.tackEvery = tackEvery
    }

    /// The held input `seconds` after the race start came, for `seat` (seats are out of phase).
    public func held(at seconds: Double, seat: Int) -> BoatInput {
        guard !rudders.isEmpty else { return .neutral }
        let step = Int((seconds / rudderPeriod).rounded(.down)) + seat
        return BoatInput(rudder: rudders[step % rudders.count])
    }

    /// Whether a tack falls in (`from`, `to`].
    public func tacks(from: Double, to: Double) -> Bool {
        guard let every = tackEvery, every > 0 else { return false }
        return (to / every).rounded(.down) > (from / every).rounded(.down) && to >= every
    }
}

public struct LoadClientOptions: Sendable {
    public var host: String
    public var port: Int
    /// Client updates a second, as the app's display link would call them.
    public var frameRate: Int
    public var script: InputScript
    /// Gives up after this long, whatever the race is doing.
    public var timeout: Duration
    public var handshakeTimeout: Duration
    public var clientBuild: String

    public init(host: String = "127.0.0.1", port: Int = 8080, frameRate: Int = 30, script: InputScript = .weave,
                timeout: Duration = .seconds(3600), handshakeTimeout: Duration = .seconds(10),
                clientBuild: String = "regatta-loadclient") {
        self.host = host
        self.port = port
        self.frameRate = frameRate
        self.script = script
        self.timeout = timeout
        self.handshakeTimeout = handshakeTimeout
        self.clientBuild = clientBuild
    }
}

/// Round trips a client measured with its clock pings, in milliseconds.
public struct RoundTrips: Codable, Hashable, Sendable {
    public var count: Int
    public var min: Double
    public var median: Double
    public var p95: Double
    public var max: Double

    init(micros samples: [UInt64]) {
        let sorted = samples.sorted().map { Double($0) / 1000 }
        count = sorted.count
        func at(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        min = sorted.first ?? 0
        median = at(0.5)
        p95 = at(0.95)
        max = sorted.last ?? 0
    }
}

/// One load client's race, as it measured it.
public struct LoadReport: Codable, Hashable, Sendable {
    public var seat: Int
    /// `RaceClosed` (or `RaceCancelled`) came: the race was sailed to its end.
    public var completed: Bool
    /// Bytes received, TCP payload from the connect to the close: the upgrade, the handshake, the join and the race.
    public var bytesReceived: Int
    public var bytesSent: Int
    /// Bytes received up to and including `RaceStart`: the join.
    public var joinBytes: Int
    /// Seconds from the connect to the close.
    public var seconds: Double
    /// `(bytesReceived − joinBytes) / seconds after RaceStart`: the race's downstream rate.
    public var downstreamBytesPerSecond: Double
    /// Clock-ping round trips, from each pong's arrival: the network and the server.
    public var roundTrips: RoundTrips
    /// The same pings as the client's clock sync saw them: plus the wait for the next update (a frame).
    public var clientRoundTrips: RoundTrips
    public var heldSent: Int
    public var tapsSent: Int
    public var pingsSent: Int
    public var resyncRequests: Int
    public var resyncsApplied: Int
    public var snapshotsRefused: Int
    public var undecodableFrames: Int
    /// Race events the server sent this seat.
    public var serverEvents: Int
    /// The client's status at the end.
    public var finalStatus: String
    /// The server's close reason, if it closed the connection with one.
    public var closeReason: String?
}

/// The #27 budget for one client's downstream: about 5 KB/s during a race, under 1 MB per race with the join.
public struct BandwidthBudget: Hashable, Sendable {
    public var bytesPerSecond: Double
    public var bytesPerRace: Int

    public static let issue27 = BandwidthBudget(bytesPerSecond: 5 * 1024, bytesPerRace: 1_000_000)

    public init(bytesPerSecond: Double, bytesPerRace: Int) {
        self.bytesPerSecond = bytesPerSecond
        self.bytesPerRace = bytesPerRace
    }

    /// What `report` exceeds, in words; empty if nothing.
    public func violations(_ report: LoadReport) -> [String] {
        var found: [String] = []
        if report.downstreamBytesPerSecond > bytesPerSecond {
            found.append("seat \(report.seat): \(Int(report.downstreamBytesPerSecond)) B/s down > \(Int(bytesPerSecond))")
        }
        if report.bytesReceived >= bytesPerRace {
            found.append("seat \(report.seat): \(report.bytesReceived) B down this race >= \(bytesPerRace)")
        }
        return found
    }
}

/// The headless client (#67): joins a race with a token over a WebSocket, sails it with `RaceClient` (#64)
/// on a scripted helm, and measures bytes and round trips.
public enum LoadClient {
    /// Sails the race `token` names, from the handshake to the close.
    public static func sail(token: [UInt8], options: LoadClientOptions = LoadClientOptions(),
                            group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> LoadReport {
        let origin = ContinuousClock.now
        let micros: @Sendable () -> UInt64 = {
            let (seconds, attoseconds) = (ContinuousClock.now - origin).components
            return UInt64(seconds) * 1_000_000 + UInt64(attoseconds / 1_000_000_000_000)
        }
        let transport = try await WebSocketRaceTransport.connect(host: options.host, port: options.port, clock: micros, group: group)
        do {
            let report = try await sail(transport, token: token, options: options, micros: micros)
            await transport.close()
            return report
        } catch {
            await transport.close()
            throw error
        }
    }

    private static func sail(_ transport: WebSocketRaceTransport, token: [UInt8], options: LoadClientOptions,
                             micros: () -> UInt64) async throws -> LoadReport {
        send(.hello(Hello(clientBuild: options.clientBuild, files: [])), seq: 1, on: transport)
        let ack = try await next(on: transport, within: options.handshakeTimeout, "HelloAck")
        switch ack.message {
        case .helloAck: break
        case .updateRequired(let update): throw LoadClientError.handshake("update required: \(update.reason)")
        default: throw LoadClientError.handshake("expected HelloAck, got \(ack.message.type)")
        }
        send(.joinRace(JoinRace(token: token)), seq: 2, on: transport)
        let joined = try await next(on: transport, within: options.handshakeTimeout, "RaceStart")
        guard case .raceStart(let start) = joined.message else {
            throw LoadClientError.handshake("expected RaceStart, got \(joined.message.type)")
        }
        let joinBytes = transport.wireBytes.received
        let startedAt = micros()

        let client = RaceClient(start: start, transport: transport)
        let frame = UInt64(1_000_000 / max(1, options.frameRate))
        let deadline = startedAt + UInt64(options.timeout.components.seconds) * 1_000_000
        var clientRoundTrips: [UInt64] = []
        var pongsSeen = 0
        var serverEvents = 0
        var lastSeconds = 0.0
        var completed = false
        while true {
            let now = micros()
            let seconds = Double(now - startedAt) / 1_000_000
            client.setHeld(options.script.held(at: seconds, seat: client.seat))
            if options.script.tacks(from: lastSeconds, to: seconds) { client.tap(.tackGybe, now: now) }
            lastSeconds = seconds
            client.update(now: now)

            let pongs = client.clock.pongs
            if pongs > pongsSeen {
                clientRoundTrips += client.clock.samples.suffix(min(pongs - pongsSeen, client.clock.samples.count)).map(\.roundTrip)
                pongsSeen = pongs
            }
            serverEvents += client.drainServerEvents().count
            if client.status == .finished {
                completed = true
                break
            }
            if client.status == .disconnected || now >= deadline { break }
            let next = now + frame
            let after = micros()
            if next > after { try await Task.sleep(for: .microseconds(next - after), tolerance: .milliseconds(2)) }
        }
        let endedAt = micros()
        let bytes = transport.wireBytes
        let raceSeconds = max(0.001, Double(endedAt - startedAt) / 1_000_000)
        let stats = client.stats
        let close = transport.closeReason
        return LoadReport(
            seat: client.seat, completed: completed, bytesReceived: bytes.received, bytesSent: bytes.sent,
            joinBytes: joinBytes, seconds: Double(endedAt) / 1_000_000,
            downstreamBytesPerSecond: Double(bytes.received - joinBytes) / raceSeconds,
            roundTrips: RoundTrips(micros: transport.pongRoundTrips),
            clientRoundTrips: RoundTrips(micros: clientRoundTrips), heldSent: stats.heldSent, tapsSent: stats.tapsSent,
            pingsSent: stats.pingsSent, resyncRequests: stats.resyncRequests, resyncsApplied: stats.resyncsApplied,
            snapshotsRefused: stats.snapshotsRefused, undecodableFrames: stats.undecodableFrames,
            serverEvents: serverEvents, finalStatus: "\(client.status)",
            closeReason: close.reason.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Creates an instant race (`POST /dev/instant-race`) and sails every seat of it at once, one client
    /// per token. Each client's result, by seat order.
    public static func sailInstantRace(_ request: InstantRaceRequest, options: LoadClientOptions = LoadClientOptions(),
                                       group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton)
        async throws -> (race: InstantRaceResponse, reports: [Result<LoadReport, any Error>]) {
        let race = try await DevClient.instantRace(request, host: options.host, port: options.port, group: group)
        let tokens = try race.tokens.map { text in
            guard let data = Data(base64Encoded: text) else { throw LoadClientError.handshake("token isn't base64") }
            return [UInt8](data)
        }
        let reports = await withTaskGroup(of: (Int, Result<LoadReport, any Error>).self) { group in
            for (index, token) in tokens.enumerated() {
                group.addTask {
                    do { return (index, .success(try await sail(token: token, options: options))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<LoadReport, any Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (race, reports)
    }

    // MARK: - Handshake

    private static func send(_ message: Message, seq: UInt32, on transport: WebSocketRaceTransport) {
        guard let bytes = try? Frame(seq: seq, tick: 0, message: message).encoded() else { return }
        transport.send(bytes)
    }

    /// The next frame to arrive; any after it go back for `RaceClient`.
    private static func next(on transport: WebSocketRaceTransport, within timeout: Duration, _ what: String) async throws -> Frame {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let frames = transport.receive()
            if let first = frames.first {
                transport.unreceive(Array(frames.dropFirst()))
                return try Frame(decoding: first)
            }
            guard transport.isConnected else {
                let close = transport.closeReason
                throw LoadClientError.handshake("closed waiting for \(what): \(close.reason ?? "no reason")")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw LoadClientError.timedOut("waiting for \(what)")
    }
}
