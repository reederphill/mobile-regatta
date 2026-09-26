import RegattaClient
import RegattaCore
import RegattaProtocol

/// The handshake and join on a new race connection (#18, #68), polled like `RaceClient` so a test can run
/// it on a virtual clock: `Hello` with the simulation version and the bundled data files, then `HelloAck`
/// or `UpdateRequired`; `JoinRace` with the race token, then `RaceStart`. The first join and every
/// reconnect go through it.
///
/// Anything else, the connection closing, or no `RaceStart` within `timeout`, fails it: the server has no
/// join-refused message and closes the connection instead (`SeatConnection`).
nonisolated final class RaceJoin {
    enum State: Equatable {
        case awaitingAck
        case awaitingStart
        case joined(RaceStart)
        /// The server won't race this build: the app shows the update prompt, and doesn't retry.
        case updateRequired(UpdateRequired.Reason)
        case failed(String)
    }

    /// A builder choice: the server's own handshake timeout is 10 s.
    static let timeout: UInt64 = 10_000_000

    private(set) var state = State.awaitingAck
    private let connection: RaceTransport
    private let token: [UInt8]
    private let deadline: UInt64
    /// Frames that arrived after the `RaceStart`, in the same read: the race's, for the client.
    private var leftover: [[UInt8]] = []

    /// Says `Hello` on `connection` at `now` (monotonic microseconds).
    init(connection: RaceTransport, token: [UInt8], clientBuild: String, now: UInt64) {
        self.connection = connection
        self.token = token
        deadline = now + Self.timeout
        send(.hello(Hello(clientBuild: clientBuild, files: Self.bundledFiles)), seq: 1)
    }

    /// The data files this build races with (ADR 0004), sent in `Hello`: the bundled defaults a race setup
    /// names. The server doesn't check them yet; it compares only the simulation revision.
    static let bundledFiles: [FileRef] = {
        let files = RaceFiles.defaults
        return [files.boatClass.ref, files.venue.ref, files.conditions.ref, files.rulesConfiguration.ref]
    }()

    var isFinished: Bool {
        switch state {
        case .awaitingAck, .awaitingStart: false
        case .joined, .updateRequired, .failed: true
        }
    }

    /// The connection, once joined, for `RaceClient`: it yields the frames that came in behind the
    /// `RaceStart` first.
    private(set) var transport: RaceTransport?

    /// Reads what has arrived and moves the handshake on.
    func poll(now: UInt64) {
        guard !isFinished else { return }
        for bytes in connection.receive() {
            guard !isFinished else {
                leftover.append(bytes)
                continue
            }
            guard let frame = try? Frame(decoding: bytes) else { return fail("undecodable frame in the handshake") }
            receive(frame)
        }
        if case .joined = state {
            transport = leftover.isEmpty ? connection : Replaying(leftover, then: connection)
        }
        guard !isFinished else { return }
        if !connection.isConnected { return fail("the server closed the connection") }
        if now >= deadline { fail("no answer from the server") }
    }

    private func receive(_ frame: Frame) {
        switch (state, frame.message) {
        case (.awaitingAck, .helloAck):
            state = .awaitingStart
            send(.joinRace(JoinRace(token: token)), seq: 2)
        case (_, .updateRequired(let update)):
            state = .updateRequired(update.reason)
        case (.awaitingStart, .raceStart(let start)):
            state = .joined(start)
        default:
            fail("expected \(state == .awaitingAck ? "HelloAck" : "RaceStart"), got \(frame.message.type)")
        }
    }

    private func fail(_ reason: String) {
        state = .failed(reason)
    }

    private func send(_ message: Message, seq: UInt32) {
        guard let bytes = try? Frame(seq: seq, tick: 0, message: message).encoded() else { return }
        connection.send(bytes)
    }

    /// A joined connection that hands out the frames the handshake read past first.
    private final class Replaying: RaceTransport {
        private var pending: [[UInt8]]
        private let connection: RaceTransport

        init(_ pending: [[UInt8]], then connection: RaceTransport) {
            self.pending = pending
            self.connection = connection
        }

        var isConnected: Bool { !pending.isEmpty || connection.isConnected }
        func send(_ frame: [UInt8]) { connection.send(frame) }

        func receive() -> [[UInt8]] {
            defer { pending.removeAll() }
            return pending + connection.receive()
        }
    }
}
