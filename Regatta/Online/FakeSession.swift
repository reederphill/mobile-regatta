#if DEBUG
import Foundation
import RegattaProtocol
import RegattaServiceClient
import RegattaServices

/// The online session a `-fakeServices` scenario plays (#161): `session-failed`, `unreachable` and `connecting` are the
/// session's own states, which no scripted service says. The real `OnlineSession` runs over a server that isn't one,
/// so Home shows what it would on the network: nothing up front, the spinner on a tap, then the line and the lobby's
/// Try again. Debug builds only, like the fakes.
nonisolated enum FakeSession {
    static let player = DevicePlayer(teamPlayerID: "T:fake-1",
                                     player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:fake-1"), alias: "Sailor"))

    /// The session and the device identity under it; nil for a scenario the scripted services play whole.
    static func make(_ scenario: FakeServiceScenario) -> OnlineStatus.Session? {
        guard scenario.playsSession else { return nil }
        let device = ScriptedDeviceIdentity(player: player) { player in
            IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID,
                              publicKeyURL: "https://scripted.invalid/gc-public-key.cer", signature: [1], salt: [2], timestamp: 3)
        }
        let session = OnlineSession(OnlineSession.Dependencies(
            connect: { try await Self.connect(scenario) }, device: device, tokens: InMemorySessionTokenStore(),
            sleep: { try await Task.sleep(for: $0) }, jitter: { 0 }, clientBuild: "fake"))
        return OnlineStatus.Session(session: session, device: device)
    }

    private static func connect(_ scenario: FakeServiceScenario) async throws -> any SessionLink {
        switch scenario {
        case .sessionFailed: return RefusingLink()
        case .connecting:
            // Never answers: the wait ends when the session gives the try up.
            try await Task.sleep(for: .seconds(86400))
            throw ServiceLinkError.closed
        default: throw ServiceLinkError.closed
        }
    }
}

/// A `/service` peer that takes the handshake and refuses every sign-in: the signature is never good enough.
private nonisolated final class RefusingLink: SessionLink {
    let incoming: AsyncStream<[UInt8]>
    private let frames: AsyncStream<[UInt8]>.Continuation

    init() {
        (incoming, frames) = AsyncStream.makeStream()
    }

    private func deliver(_ message: Message) {
        guard let frame = try? Frame(seq: 0, tick: 0, message: message).encoded() else { return }
        frames.yield(frame)
    }

    func send(_ frame: [UInt8]) {
        guard let message = try? Frame(decoding: frame).message else { return }
        switch message {
        case .hello: deliver(.helloAck(HelloAck(serverBuild: "fake")))
        case .sessionRequest(let request):
            deliver(.sessionReply(ServiceReply(id: request.id, result: .refused(.invalidSignature))))
        default: break
        }
    }

    func close() { frames.finish() }
    func ping() async throws {}
}
#endif
