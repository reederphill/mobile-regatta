import Foundation
import NIOWebSocket
import RaceHost
import RegattaCore
import RegattaProtocol

/// One race connection's protocol, whatever carries it (#18: framing independent of the transport): the
/// handshake, the join, then every frame to the race host. Fed each binary message in order.
///
/// 1. `Hello`: a protocol version or simulation revision other than the server's (`canSail`) gets
///    `UpdateRequired` and the connection closes; otherwise `HelloAck`. Dev auth (`SeatAuthPolicy.dev`) asks nothing more.
/// 2. `JoinRace`: the race token must be signed by this server, unexpired, and name a running race's
///    human seat that no connection holds. Then the race's host takes over: `RaceStart`, and the race.
/// 3. Everything after goes to `RaceHost.receive(_:from:)`.
///
/// Anything out of turn, or a bad token, closes the connection with a policy-violation close: the
/// protocol has no join-refused message. So does not being seated within `ServerConfig.handshakeTimeout`
/// (the server's read loop enforces that).
struct SeatConnection {
    enum Phase {
        case awaitingHello
        case awaitingJoin
        case seated(RaceSession, seat: Int)
        case closed
    }

    let config: ServerConfig
    let registry: RaceRegistry
    let transport: WebSocketSeatTransport
    /// Unix seconds now, for token expiry.
    let now: @Sendable () -> Int64
    private(set) var phase = Phase.awaitingHello
    private var seq: UInt32 = 1

    init(config: ServerConfig, registry: RaceRegistry, transport: WebSocketSeatTransport,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.config = config
        self.registry = registry
        self.transport = transport
        self.now = now
    }

    var isClosed: Bool { if case .closed = phase { true } else { false } }
    var isSeated: Bool { if case .seated = phase { true } else { false } }

    mutating func receive(_ bytes: [UInt8]) async {
        switch phase {
        case .awaitingHello: hello(bytes)
        case .awaitingJoin: await join(bytes)
        case .seated(let session, let seat): await session.host.receive(bytes, from: seat)
        case .closed: break
        }
    }

    /// The connection has gone: gives up the seat.
    mutating func ended() async {
        if case .seated(let session, let seat) = phase { await session.leave(seat: seat, transport: transport) }
        phase = .closed
    }

    private mutating func hello(_ bytes: [UInt8]) {
        guard let version = Frame.helloProtocolVersion(in: bytes) else { return refuse("expected Hello") }
        guard version == wireProtocolVersion else { return updateRequired(.protocolVersion) }
        guard let frame = try? Frame(decoding: bytes), case .hello(let hello) = frame.message else {
            return refuse("undecodable Hello")
        }
        guard Self.canSail(clientSimulationVersion: hello.simulationVersion) else { return updateRequired(.simulationVersion) }
        // Dev auth (`config.auth`, the only policy): no attestation (#158), no account; data files are
        // checked when #81 resolves them.
        send(.helloAck(HelloAck(serverBuild: config.serverBuild)))
        phase = .awaitingJoin
    }

    /// Whether a client on `clientSimulationVersion` sails here: the same simulation revision. The platform
    /// half (toolchain, C library, architecture) is the server's alone: only its results are authoritative
    /// (ADR 0002), and a client "just has to be close enough for prediction" (#18). Comparing the whole string
    /// would turn away every iOS and macOS client from the Linux server.
    static func canSail(clientSimulationVersion: String, server: String = RegattaCore.simulationVersion) -> Bool {
        func revision(_ version: String) -> Substring? {
            guard let slash = version.firstIndex(of: "/") else { return nil }
            return version[..<slash]
        }
        guard let client = revision(clientSimulationVersion) else { return false }
        return client == revision(server)
    }

    private mutating func join(_ bytes: [UInt8]) async {
        guard let frame = try? Frame(decoding: bytes), case .joinRace(let join) = frame.message else {
            return refuse("expected JoinRace")
        }
        let token: RaceToken
        do {
            token = try RaceToken.verify(join.token, key: config.tokenKey, now: now())
        } catch {
            return refuse("race token \(error)")
        }
        guard let session = await registry.session(token.raceID) else { return refuse("no such race") }
        do {
            try await session.join(seat: token.seat, transport: transport)
        } catch {
            return refuse("seat \(token.seat): \(error)")
        }
        phase = .seated(session, seat: token.seat)
    }

    private mutating func updateRequired(_ reason: UpdateRequired.Reason) {
        send(.updateRequired(UpdateRequired(reason: reason)))
        transport.close(code: .normalClosure, reason: "update required")
        phase = .closed
    }

    private mutating func refuse(_ reason: String) {
        transport.close(code: .policyViolation, reason: String(reason.prefix(120)))
        phase = .closed
    }

    private mutating func send(_ message: Message) {
        guard let bytes = try? Frame(seq: seq, tick: 0, message: message).encoded() else { return }
        seq += 1
        transport.send(bytes)
    }
}
