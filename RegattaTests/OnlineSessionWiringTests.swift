import Foundation
import os
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Testing
@testable import Regatta

/// A `/service` peer in the test: `Hello` is acknowledged, a sign-in or resume opens a session, the terms and the
/// queue's state are what the test set. No network.
nonisolated final class StubService: Sendable {
    struct State {
        var isReachable = true
        var terms = WireTermsStatus.needsAcceptance(current: 1, lastAccepted: nil)
        var queue = QueueState.idle
        var connects = 0
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func connect() throws -> StubLink {
        try state.withLock { state in
            state.connects += 1
            guard state.isReachable else { throw ServiceLinkError.closed }
            return StubLink(self)
        }
    }

    var connects: Int { state.withLock { $0.connects } }
}

nonisolated final class StubLink: SessionLink {
    let incoming: AsyncStream<[UInt8]>
    private let frames: AsyncStream<[UInt8]>.Continuation
    private let player = OSAllocatedUnfairLock<WirePlayer?>(initialState: nil)
    private let service: StubService

    init(_ service: StubService) {
        self.service = service
        (incoming, frames) = AsyncStream.makeStream()
    }

    private func deliver(_ message: Message) { frames.yield(try! Frame(seq: 0, tick: 0, message: message).encoded()) }

    func send(_ frame: [UInt8]) {
        guard let message = try? Frame(decoding: frame).message else { return }
        switch message {
        case .hello: deliver(.helloAck(HelloAck(serverBuild: "stub")))
        case .sessionRequest(let request):
            switch request.call {
            case .signIn(_, let player), .resume(_, let player):
                self.player.withLock { $0 = player }
                deliver(.sessionReply(ServiceReply(id: request.id, result: .signedIn(token: Array(repeating: 7, count: 32), player: player))))
            case .signOut: deliver(.sessionReply(ServiceReply(id: request.id, result: .signedOut)))
            }
        case .identityRequest(let request):
            deliver(.identityReply(ServiceReply(id: request.id, result: .state(player.withLock { $0 }))))
        case .termsRequest(let request):
            let result: TermsResult = service.state.withLock { state in
                guard case .accept(let version) = request.call else { return .status(state.terms) }
                guard case .needsAcceptance(let current, _) = state.terms else { return .status(state.terms) }
                guard version == current else { return .staleVersion(current: current) }
                state.terms = .accepted(version: version)
                return .status(state.terms)
            }
            deliver(.termsReply(ServiceReply(id: request.id, result: result)))
        default:
            // The queue's stream is opened and never answered: the tests show the status its states themselves.
            break
        }
    }

    func close() { frames.finish() }
    func ping() async throws {}
}

/// The online session under `OnlineStatus` (#161): what Race online's gate does with a session that opens, one that
/// can't, terms the build is too old for, and a player who gets no session.
@MainActor @Suite struct OnlineSessionWiringTests {
    private static let wren = DevicePlayer(teamPlayerID: "T:wren", player: GameCenterPlayer(gamePlayerID: GamePlayerID("G:wren"), alias: "Wren"))

    private struct Rig {
        let service = StubService()
        let tokens = InMemorySessionTokenStore()
        let session: OnlineSession
        let status: OnlineStatus

        @MainActor init(player: DevicePlayer?) async {
            let (service, tokens) = (service, tokens)
            let device = ScriptedDeviceIdentity(player: player) { player in
                IdentitySignature(gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID,
                                  publicKeyURL: "https://test.invalid/key.cer", signature: [1], salt: [2], timestamp: 3)
            }
            // A wait that only its cancelling ends: the back-off never comes round in a test.
            session = OnlineSession(OnlineSession.Dependencies(
                connect: { try service.connect() }, device: device, tokens: tokens,
                sleep: { _ in for await _ in AsyncStream<Void>.makeStream().stream {}; throw CancellationError() },
                jitter: { 0 }, clientBuild: "test"))
            var services = ServiceSet.fake(.signedOut)
            services.identity = session.identity
            services.terms = session.terms
            services.queue = session.queueStatus
            status = OnlineStatus(services: services, session: OnlineStatus.Session(session: session, device: device))
            await status.deviceChanged(player)
        }
    }

    /// Game Center signed in on the phone, no session yet: the tap opens one, then the terms, then through.
    @Test func raceOnlineOpensTheSessionThenAsksForTheTerms() async {
        let rig = await Rig(player: Self.wren)
        #expect(!rig.status.lobbyStatus.isSignedIn, "signed in is the session's word")
        #expect(rig.status.access.next == .signIn)
        let analytics = Analytics(transport: ScriptedAnalyticsTransport(), storage: InMemoryAnalyticsStorage(), isSharing: true,
                                  makeInstallID: { "test" }, now: { 0 })

        #expect(await rig.status.passGate(analytics: analytics) == .terms)
        #expect(rig.status.sessionPhase == .open(Self.wren.player))
        #expect(rig.status.lobbyStatus.termsVersion == TermsVersion(1))
        #expect(rig.tokens.all.keys.sorted() == ["T:wren"])
        #expect(rig.status.restrictionLine == nil)
        #expect(!rig.status.isOpeningSession && !rig.status.tapFailed)
        // Game Center's sheet was never a prospect: nothing logged for it.
        #expect(analytics.pending.isEmpty)

        #expect(await rig.status.acceptTerms(TermsVersion(1), analytics: analytics))
        #expect(await rig.status.passGate(analytics: analytics) == .proceed)
    }

    /// The version the sheet showed is the one accepted: a newer one current by the tap doesn't take.
    @Test func agreeAcceptsTheVersionTheSheetShowed() async {
        let rig = await Rig(player: Self.wren)
        #expect(await rig.status.passGate(analytics: .discarding()) == .terms)
        rig.service.state.withLock { $0.terms = .needsAcceptance(current: 2, lastAccepted: nil) }
        #expect(!(await rig.status.acceptTerms(TermsVersion(1), analytics: .discarding())))
        #expect(!rig.status.lobbyStatus.hasAcceptedTerms)
    }

    /// An unreachable server is said only after a tap fails; the tap after it tries again.
    @Test func anUnreachableServerShowsOnlyAfterATap() async {
        let rig = await Rig(player: Self.wren)
        rig.service.state.withLock { $0.isReachable = false }
        await rig.session.deviceChanged(Self.wren)
        rig.status.show(await rig.session.phase)
        #expect(rig.status.restrictionLine == nil, "nothing up front")
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: rig.status.lobbyStatus).isEnabled)

        #expect(await rig.status.passGate(analytics: .discarding()) == .stopped)
        #expect(rig.status.tapFailed)
        #expect(rig.status.restrictionLine == .unreachable)
        #expect(rig.status.restrictionLine?.allowsTap == true)

        rig.service.state.withLock { $0.isReachable = true }
        #expect(await rig.status.passGate(analytics: .discarding()) == .terms)
        #expect(rig.status.restrictionLine == nil)
    }

    /// Terms newer than the text the build carries: no sheet, "Update to race online".
    @Test func termsNewerThanTheBundledTextAskForAnUpdate() async {
        let rig = await Rig(player: Self.wren)
        rig.service.state.withLock { $0.terms = .needsAcceptance(current: TermsOfUse.version.rawValue + 1, lastAccepted: nil) }
        #expect(await rig.status.passGate(analytics: .discarding()) == .stopped)
        #expect(rig.status.termsPrompt == .updateRequired)
        #expect(rig.status.lobbyStatus.termsVersion == nil, "no sheet to open")
        #expect(rig.status.restrictionLine == .updateRequired)
    }

    /// A suspension or the cooldown from the queue's stream stops the gate, with its line; `.idle` clears it.
    @Test func theQueuesRefusalsStopTheGate() async {
        let rig = await Rig(player: Self.wren)
        rig.service.state.withLock { $0.terms = .accepted(version: 1) }
        #expect(await rig.status.passGate(analytics: .discarding()) == .proceed)
        rig.status.show(.unavailable(.suspended(until: nil)))
        #expect(rig.status.restrictionLine == .suspended(until: nil))
        #expect(await rig.status.passGate(analytics: .discarding()) == .stopped)
        rig.status.show(QueueState.idle)
        #expect(rig.status.restrictionLine == nil)
        #expect(await rig.status.passGate(analytics: .discarding()) == .proceed)
    }

    /// A player who can neither chat nor race online gets no session, and Race online still says why.
    @Test func aPlayerWhoCanDoNeitherIsSignedInWithNoSession() async {
        var neither = Self.wren
        neither.player.isMultiplayerGamingRestricted = true
        neither.player.isUnderage = true
        let rig = await Rig(player: neither)
        await rig.session.deviceChanged(neither)
        #expect(rig.status.lobbyStatus.isSignedIn)
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: rig.status.lobbyStatus) == RaceOnlineAvailability(isEnabled: false, reason: "Practice races only"))
        #expect(await rig.status.passGate(analytics: .discarding()) == .stopped)
        #expect(rig.service.connects == 0)
        #expect(rig.status.restrictionLine == nil)
    }

    /// The lobby's Try again is the tap again: an unreachable server shows there after a tap that failed, where the
    /// area would ask her to sign in to Game Center, and the next tap that gets a session clears it. A sign-in the
    /// server refused shows there the same way.
    @Test func theLobbysTryAgainOpensTheSession() async {
        let rig = await Rig(player: Self.wren)
        rig.service.state.withLock { $0.isReachable = false }
        func panel() -> LobbyPanelState {
            LobbyPanelState(isOnline: true, status: rig.status.lobbyStatus, retryLine: rig.status.lobbyRetryLine)
        }
        #expect(panel() == .signIn, "nothing up front")

        #expect(!(await rig.status.signIn(analytics: .discarding())))
        #expect(rig.status.tapFailed && rig.status.lobbyRetryLine == .unreachable)
        #expect(panel() == .tryAgain(.unreachable))
        #expect(!rig.status.isOpeningSession, "the spinner is the tap's wait alone")
        // Offline says offline, whatever the server did.
        #expect(LobbyPanelState(isOnline: false, status: rig.status.lobbyStatus, retryLine: .unreachable) == .offline)

        #expect(!(await rig.status.signIn(analytics: .discarding())), "Try again, the server still away")
        #expect(panel() == .tryAgain(.unreachable))
        rig.service.state.withLock { $0.isReachable = true }
        #expect(await rig.status.signIn(analytics: .discarding()))
        #expect(!rig.status.tapFailed && rig.status.lobbyRetryLine == nil)
        #expect(panel() == .acceptTerms)
    }

    /// An I agree the server doesn't take keeps the sheet, with its line; a newer version is no failure; the line
    /// goes with the sheet.
    @Test func aSaveThatFailsSaysSoOnTheSheet() async {
        let failing = OnlineStatus(services: .fake(.termsSaveFailed))
        #expect(await failing.passGate(analytics: .discarding()) == .terms)
        #expect(!failing.termsSaveFailed)
        #expect(!(await failing.acceptTerms(TermsVersion(1), analytics: .discarding())))
        #expect(failing.termsSaveFailed)
        #expect(!failing.lobbyStatus.hasAcceptedTerms)
        failing.termsSheetClosed()
        #expect(!failing.termsSaveFailed)

        // Through the session: the link gone by the tap.
        let rig = await Rig(player: Self.wren)
        #expect(await rig.status.passGate(analytics: .discarding()) == .terms)
        await rig.session.setOnline(false)
        #expect(!(await rig.status.acceptTerms(TermsVersion(1), analytics: .discarding())))
        #expect(rig.status.termsSaveFailed)
        await rig.session.setOnline(true)
        #expect(await rig.session.open() == .open(Self.wren.player))
        #expect(await rig.status.acceptTerms(TermsVersion(1), analytics: .discarding()))
        #expect(!rig.status.termsSaveFailed, "a save that takes clears the line")

        let bumped = OnlineStatus(services: .fake(.termsBump))
        await bumped.refreshAccount()
        #expect(!(await bumped.acceptTerms(TermsVersion(1), analytics: .discarding())))
        #expect(!bumped.termsSaveFailed, "the sheet shows the newer version instead")
    }

    /// Race online under the server's and the session's lines: no tap under a suspension, the cooldown, an update or a
    /// refusal; a tap under an unreachable server or a failed sign-in; none while a tap waits; the matrix's own line
    /// first.
    @Test func raceOnlineFollowsTheLine() {
        let now = Date(timeIntervalSince1970: 1_791_720_000)
        var signedIn = LobbyStatus()
        signedIn.isSignedIn = true
        signedIn.hasAcceptedTerms = true
        func availability(_ line: RestrictionLine?, isOnline: Bool = true, isConnecting: Bool = false) -> RaceOnlineAvailability {
            RaceOnlineAvailability(isOnline: isOnline, lobbyStatus: signedIn, line: line, isConnecting: isConnecting)
        }
        for line: RestrictionLine in [.suspended(until: nil), .cooldown(until: now.addingTimeInterval(252)), .cannotRace, .updateRequired] {
            #expect(!availability(line).isEnabled, "\(line)")
            #expect(availability(line).text(now: now) == line.text(now: now))
        }
        #expect(availability(.cooldown(until: now.addingTimeInterval(252))).text(now: now.addingTimeInterval(2)) == "Cooling off 4:10")
        for line: RestrictionLine in [.unreachable, .couldNotSignIn] {
            #expect(availability(line).isEnabled, "\(line): the tap tries again")
            #expect(availability(line).text(now: now) == line.text(now: now))
        }
        #expect(availability(nil).isEnabled && availability(nil).text(now: now) == nil)

        let connecting = availability(nil, isConnecting: true)
        #expect(!connecting.isEnabled && connecting.isConnecting && connecting.text(now: now) == nil)
        #expect(!availability(.unreachable, isConnecting: true).isEnabled)

        let offline = availability(.suspended(until: nil), isOnline: false)
        #expect(!offline.isEnabled && offline.text(now: now) == "Offline" && offline.line == nil)
    }

    /// The fake scenarios (#161) reach Home as their lines: the queue's refusals as its stream gives them.
    @Test func theFakeScenariosShowTheirLines() async throws {
        let now = Date(timeIntervalSince1970: 1_791_720_000)
        let lines: [(FakeServiceScenario, RestrictionLine)] = [
            (.suspended, .suspended(until: Date(timeIntervalSince1970: TimeInterval(FakeServiceScenario.suspendedUntil)))),
            (.suspendedPermanent, .suspended(until: nil)),
            (.cooldown, .cooldown(until: now.addingTimeInterval(TimeInterval(FakeServiceScenario.cooldownSeconds)))),
            (.cannotRace, .cannotRace),
            (.updateRequired, .updateRequired),
        ]
        for (scenario, line) in lines {
            let services = ServiceSet.fake(scenario)
            let status = OnlineStatus(services: services, now: { now })
            await status.refreshAccount()
            var states = services.queue.stateUpdates().makeAsyncIterator()
            status.show(try #require(await states.next()))
            #expect(status.restrictionLine == line, "\(scenario)")
            #expect(await status.passGate(analytics: .discarding()) == .stopped, "\(scenario)")
            let availability = RaceOnlineAvailability(isOnline: true, lobbyStatus: status.lobbyStatus, line: status.restrictionLine)
            #expect(!availability.isEnabled, "\(scenario)")
            // The lobby area is as for any signed-in player: a suspension from racing is no chat mute.
            #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus, retryLine: status.lobbyRetryLine) == .lobby)
        }
        #expect(RestrictionLine.cooldown(until: now.addingTimeInterval(TimeInterval(FakeServiceScenario.cooldownSeconds))).text(now: now) == "Cooling off 4:12")
    }

    /// The scenarios that are the session's own states play a real session over a server that isn't one.
    @Test func theSessionScenariosPlayASession() async throws {
        for scenario in FakeServiceScenario.allCases where !scenario.playsSession { #expect(FakeSession.make(scenario) == nil) }

        func status(_ scenario: FakeServiceScenario) throws -> (OnlineStatus, OnlineSession) {
            let fake = try #require(FakeSession.make(scenario))
            var services = ServiceSet.fake(scenario)
            services.identity = fake.session.identity
            services.terms = fake.session.terms
            services.queue = fake.session.queueStatus
            return (OnlineStatus(services: services, session: fake), fake.session)
        }

        let (unreachable, unreachableSession) = try status(.unreachable)
        await unreachable.deviceChanged(FakeSession.player)
        #expect(unreachable.restrictionLine == nil, "nothing up front")
        #expect(await unreachable.passGate(analytics: .discarding()) == .stopped)
        #expect(unreachable.restrictionLine == .unreachable && unreachable.lobbyRetryLine == .unreachable)
        await unreachableSession.shutdown()

        let (failed, failedSession) = try status(.sessionFailed)
        await failed.deviceChanged(FakeSession.player)
        #expect(await failed.passGate(analytics: .discarding()) == .stopped)
        #expect(failed.sessionPhase == .refused(.invalidSignature))
        #expect(failed.restrictionLine == .couldNotSignIn)
        #expect(failed.lobbyRetryLine == .couldNotSignIn)
        #expect(LobbyPanelState(isOnline: true, status: failed.lobbyStatus, retryLine: failed.lobbyRetryLine) == .tryAgain(.couldNotSignIn),
                "the lobby area's Try again, not a Sign in to Game Center")
        #expect(RaceOnlineAvailability(isOnline: true, lobbyStatus: failed.lobbyStatus, line: failed.restrictionLine).isEnabled)
        await failedSession.shutdown()
    }

    /// With no session (no endpoint) nothing of #161 shows: the app as before.
    @Test func withoutASessionNothingChanges() async {
        let status = OnlineStatus(services: .fake(.signedOut))
        #expect(status.sessionPhase == nil && status.restrictionLine == nil && status.termsPrompt == .none)
        #expect(await status.passGate(analytics: .discarding()) == .terms)
        #expect(!status.tapFailed)
    }

    /// The endpoint (#161): Debug's `-onlineHost` or a set Settings field; else Info.plist's, `wss://` only; else none.
    @Test func theEndpointIsTheDevHostOrTheBundlesSecureURL() throws {
        let name = "OnlineSessionWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func url(_ arguments: [String] = [], info: [String: Any] = [:]) -> String? {
            OnlineEndpoint.serviceURL(launchOptions: LaunchOptions(arguments: ["Regatta"] + arguments), defaults: defaults, info: info)?.absoluteString
        }
        #expect(url() == nil)
        #expect(url(info: [OnlineEndpoint.infoKey: ""]) == nil)
        #expect(url(info: [OnlineEndpoint.infoKey: "ws://plain.example/service"]) == nil, "never unencrypted from the bundle")
        #expect(url(info: [OnlineEndpoint.infoKey: "wss://regatta.example/service"]) == "wss://regatta.example/service")
        #expect(url(["-onlineHost", "127.0.0.1:8080"]) == "ws://127.0.0.1:8080/service")
        // The Settings field's built-in default is no endpoint; a host typed into it is.
        defaults.set("10.0.0.2:8080", forKey: RaceServer.addressDefaultsKey)
        #expect(url() == "ws://10.0.0.2:8080/service")
        // The shipped Info.plist names none until #167.
        #expect((Bundle.main.infoDictionary?[OnlineEndpoint.infoKey] as? String) == "")
    }

    /// URLSession's default message cap is 1 MiB; the socket takes the protocol's largest frame.
    @Test func theSocketTakesTheProtocolsLargestFrame() throws {
        let link = URLSessionServiceLink(url: try #require(URL(string: "ws://127.0.0.1:9/service")), session: .shared, resumes: false)
        #expect(link.maximumMessageSize == serviceFrameLimit)
        link.close()
    }
}

/// The lines under Race online for the server's refusals and the session's phases (#161).
@Suite struct RestrictionLinesTests {
    private static let london: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_GB")
    /// 2026-10-11 12:00:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_720_000)

    private static func text(_ line: RestrictionLine?, at now: Date = now) -> String? {
        line?.text(now: now, calendar: london, locale: locale)
    }

    @Test func refusalsMapToTheReasonLines() {
        func line(_ refusal: QueueRefusal) -> RestrictionLine? { RestrictionLine(queue: .unavailable(refusal), now: Self.now) }
        // Three days on, late in the evening: the day, no time.
        let until = Int64(Self.now.timeIntervalSince1970) + 3 * 86400 + 9 * 3600
        #expect(Self.text(line(.suspended(until: until))) == "Racing paused until Wed 14 Oct")
        #expect(Self.text(line(.suspended(until: nil))) == "Racing closed")
        #expect(Self.text(line(.cooldown(secondsRemaining: 252))) == "Cooling off 4:12")
        #expect(Self.text(line(.attestationFailed)) == "Can't race online right now")
        #expect(Self.text(line(.updateRequired)) == "Update to race online")
        // The gating matrix's own.
        for refusal: QueueRefusal in [.notSignedIn, .termsNotAccepted, .multiplayerRestricted] { #expect(line(refusal) == nil) }
        for state: QueueState in [.idle, .fleetLocked, .queued(QueuedStatus(queuedPlayers: 3, secondsToLock: 9))] {
            #expect(RestrictionLine(queue: state, now: Self.now) == nil)
        }

        // The session's phases.
        #expect(Self.text(RestrictionLine(phase: .updateRequired, tapFailed: false)) == "Update to race online")
        #expect(Self.text(RestrictionLine(phase: .refused(.gamePlayerIDConflict), tapFailed: false)) == "Can't race online right now")
        #expect(Self.text(RestrictionLine(phase: .refused(.invalidSignature), tapFailed: false)) == "Couldn't sign in")
        #expect(Self.text(RestrictionLine(phase: .unreachable, tapFailed: true)) == "Can't reach the server")
        #expect(Self.text(RestrictionLine(phase: .connecting, tapFailed: true)) == "Can't reach the server")
        for phase: SessionPhase in [.unreachable, .connecting, .idle] { #expect(RestrictionLine(phase: phase, tapFailed: false) == nil) }
        #expect(RestrictionLine(phase: .open(GameCenterPlayer(gamePlayerID: GamePlayerID("G:x"), alias: "X")), tapFailed: true) == nil)

        // Only the two a tap can mend leave Race online tappable.
        #expect(RestrictionLine.unreachable.allowsTap && RestrictionLine.couldNotSignIn.allowsTap)
        for line: RestrictionLine in [.suspended(until: nil), .cooldown(until: Self.now), .cannotRace, .updateRequired] { #expect(!line.allowsTap) }
    }

    /// The cooldown's seconds become an instant on receipt and count down on the device.
    @Test func theCooldownCountsDown() throws {
        let line = try #require(RestrictionLine(queue: .unavailable(.cooldown(secondsRemaining: 252)), now: Self.now))
        #expect(line == .cooldown(until: Self.now.addingTimeInterval(252)))
        #expect(Self.text(line, at: Self.now.addingTimeInterval(1)) == "Cooling off 4:11")
        #expect(Self.text(line, at: Self.now.addingTimeInterval(1.5)) == "Cooling off 4:11")
        #expect(Self.text(line, at: Self.now.addingTimeInterval(193)) == "Cooling off 0:59")
        #expect(Self.text(line, at: Self.now.addingTimeInterval(243)) == "Cooling off 0:09")
        // Until the server's `.idle` says it is over.
        #expect(Self.text(line, at: Self.now.addingTimeInterval(300)) == "Cooling off 0:00")
    }

    /// `OnlineStatus` times a cooldown from when the queue said it.
    @MainActor @Test func theStatusKeepsTheQueuesLine() {
        let status = OnlineStatus(services: .fake(.signedOut), now: { Self.now })
        status.show(.unavailable(.cooldown(secondsRemaining: 30)))
        #expect(status.queueLine == .cooldown(until: Self.now.addingTimeInterval(30)))
        status.show(QueueState.idle)
        #expect(status.queueLine == nil)
    }
}

/// The session tokens in the Keychain (#161), each test under a service name of its own.
@Suite struct KeychainSessionTokenStoreTests {
    private static func store() -> KeychainSessionTokenStore {
        KeychainSessionTokenStore(service: "com.phillreeder.regatta.session.tests.\(UUID().uuidString)")
    }

    private static let token: [UInt8] = (0..<32).map { UInt8($0) }

    @Test func aTokenRoundTripsPerAccount() throws {
        let store = Self.store()
        defer { try? store.removeAll(except: nil) }
        #expect(try store.token(for: "T:wren") == nil)
        try store.setToken(Self.token, for: "T:wren")
        try store.setToken(Self.token.reversed(), for: "T:tern")
        #expect(try store.token(for: "T:wren") == Self.token)
        #expect(try store.token(for: "T:tern") == Self.token.reversed())
        // A newer token replaces the old.
        try store.setToken([9] + Self.token.dropFirst(), for: "T:wren")
        #expect(try store.token(for: "T:wren") == [9] + Self.token.dropFirst())
        #expect(try store.accounts().sorted() == ["T:tern", "T:wren"])

        try store.removeToken(for: "T:wren")
        try store.removeToken(for: "T:wren")
        #expect(try store.token(for: "T:wren") == nil)
        #expect(try store.token(for: "T:tern") == Self.token.reversed())
        // Another store's items are another's.
        #expect(try Self.store().accounts() == [])
    }

    @Test func everyoneElsesTokensCanBeForgotten() throws {
        let store = Self.store()
        defer { try? store.removeAll(except: nil) }
        for account in ["T:a", "T:b", "T:c"] { try store.setToken(Self.token, for: account) }
        try store.removeAll(except: "T:b")
        #expect(try store.accounts() == ["T:b"])
        try store.removeAll(except: nil)
        #expect(try store.accounts() == [])
    }

    /// The Keychain outlives the app: a fresh install starts with none, once.
    @Test func aFreshInstallPurgesWhatAnEarlierInstallLeft() throws {
        let store = Self.store()
        defer { try? store.removeAll(except: nil) }
        let name = "KeychainSessionTokenStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        try store.setToken(Self.token, for: "T:left-behind")
        store.purgeOnFreshInstall(defaults: defaults)
        #expect(try store.accounts() == [])
        // Not again: this install's own token stays.
        try store.setToken(Self.token, for: "T:wren")
        store.purgeOnFreshInstall(defaults: defaults)
        #expect(try store.token(for: "T:wren") == Self.token)
    }
}
