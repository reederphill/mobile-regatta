import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// The online session (#161) against a scripted server, under virtual time: which call opens it, what each refusal
/// leads to, who gets a session at all, and that the app's streams outlive a connection.
@Suite(.timeLimit(.minutes(1))) struct OnlineSessionTests {
    static let kept = FakeService.token(9)

    @Test func resumesWithTheStoredTokenWithoutFetchingASignature() async {
        let rig = SessionRig(tokens: ["T:wren": Self.kept])
        await rig.opened()
        #expect(rig.server.events.items == [.connect, .hello, .resume(Self.kept)])
        #expect(rig.tokens.all == ["T:wren": Self.kept])
        #expect(rig.logs.items == [.connecting(resuming: true), .opened(resumed: true)])
    }

    @Test func signsInWithoutATokenAndStoresItBeforeOpen() async {
        let rig = SessionRig()
        await rig.opened()
        #expect(rig.server.events.items == [.signature, .connect, .hello, .signIn(team: "T:wren")])
        #expect(rig.tokens.all == ["T:wren": FakeService.token(1)])
        // Kept by the time the session says it is open.
        let opened = try! #require(rig.logs.items.firstIndex(of: .opened(resumed: false)))
        #expect(rig.keptAtLog.items[opened] == ["T:wren": FakeService.token(1)])
        #expect(await rig.session.phase == .open(SessionRig.wren.player))
        #expect(await rig.session.identity.state() == .signedIn(SessionRig.wren.player))
    }

    @Test func theSignatureIsFetchedBeforeTheSocketOpens() async throws {
        let rig = SessionRig()
        await rig.opened()
        let events = rig.server.events.items
        #expect(try #require(events.firstIndex(of: .signature)) < #require(events.firstIndex(of: .connect)))
    }

    @Test func sessionExpiredSignsInAgainOnANewConnection() async {
        let rig = SessionRig(tokens: ["T:wren": Self.kept])
        rig.server.script { $0.resume = [.refused(.sessionExpired)] }
        await rig.opened()
        #expect(rig.server.events.items == [
            .connect, .hello, .resume(Self.kept), .closed(link: 1), .signature, .connect, .hello, .signIn(team: "T:wren"),
        ])
        #expect(rig.tokens.all == ["T:wren": FakeService.token(1)])
        // Silently: at once, and never shown as a failure.
        #expect(rig.backoffs == [])
        #expect(!rig.phases.items.contains(.unreachable))
    }

    @Test func staleSignatureRefetchesOnce() async {
        let rig = SessionRig()
        rig.server.script { $0.signIn = [.refused(.staleSignature)] }
        await rig.opened()
        #expect(rig.server.count { $0 == .signature } == 2)
        #expect(rig.server.connects == 2)
        #expect(rig.backoffs == [])

        // Stale twice running is a failure like any other: the back-off, not a third fetch at once.
        let again = SessionRig()
        again.server.script { $0.signIn = [.refused(.staleSignature), .refused(.staleSignature)] }
        await again.session.start()
        await again.sleeper.waitForSleep(of: .seconds(1))
        #expect(again.server.count { $0 == .signature } == 2)
    }

    @Test func anInvalidSignatureIsRetriedOnceThenRefused() async {
        let rig = SessionRig()
        rig.server.script { $0.signIn = [.refused(.invalidSignature), .refused(.invalidSignature)] }
        await rig.session.start()
        await rig.reaches(.refused(.invalidSignature))
        #expect(rig.server.connects == 2)
        #expect(rig.tokens.all == [:])
        // A tap tries again.
        #expect(await rig.session.open() == .open(SessionRig.wren.player))
    }

    @Test func gamePlayerIDConflictIsTerminal() async {
        let rig = SessionRig()
        rig.server.script { $0.signIn = [.refused(.gamePlayerIDConflict)] }
        await rig.session.start()
        await rig.reaches(.refused(.gamePlayerIDConflict))
        #expect(await rig.session.open() == .refused(.gamePlayerIDConflict))
        await rig.session.setActive(false)
        await rig.session.setActive(true)
        #expect(await rig.session.phase == .refused(.gamePlayerIDConflict))
        #expect(rig.server.connects == 1)
        #expect(rig.backoffs == [])
        // Another player on the device is another matter.
        rig.device.set(SessionRig.tern)
        await rig.reaches(.open(SessionRig.tern.player))
    }

    @Test func updateRequiredIsTerminal() async {
        let rig = SessionRig()
        rig.server.script { $0.hello = .updateRequired(UpdateRequired(reason: .clientBuild)) }
        await rig.session.start()
        await rig.reaches(.updateRequired)
        #expect(await rig.session.open() == .updateRequired)
        await rig.session.setActive(false)
        await rig.session.setActive(true)
        await rig.session.setOnline(false)
        await rig.session.setOnline(true)
        #expect(await rig.session.phase == .updateRequired)
        #expect(rig.server.connects == 1)
        var queue = rig.session.queue.stateUpdates().makeAsyncIterator()
        #expect(await queue.next() == .unavailable(.updateRequired))
    }

    @Test func accountSwitchRevokesTheOldSessionAndDeletesItsToken() async {
        let rig = SessionRig()
        await rig.opened()
        rig.device.set(SessionRig.tern)
        await rig.reaches(.open(SessionRig.tern.player))
        await rig.server.events.wait { $0.contains(.signOut(link: 1)) && $0.contains(.closed(link: 1)) }
        #expect(rig.tokens.all == ["T:tern": FakeService.token(2)])
        #expect(rig.server.count { $0 == .signIn(team: "T:tern") } == 1)

        // Signed out of Game Center altogether: revoked, forgotten, and nothing more is tried.
        rig.device.set(nil)
        await rig.reaches(.idle)
        await rig.server.events.wait { $0.contains(.signOut(link: 2)) && $0.contains(.closed(link: 2)) }
        #expect(rig.tokens.all == [:])
        #expect(rig.server.connects == 2)
    }

    @Test func aTokenLeftByAnotherAccountIsDeleted() async {
        let rig = SessionRig(tokens: ["T:tern": Self.kept])
        await rig.opened()
        #expect(rig.tokens.all == ["T:wren": FakeService.token(1)])
    }

    @Test func restrictionChangeReconnectsAndResumes() async {
        let rig = SessionRig()
        await rig.opened()
        var restricted = SessionRig.wren
        restricted.player.isUnderage = true
        rig.device.set(restricted)
        // The server reads the flags again from the resume.
        await rig.reaches(.open(restricted.player))
        #expect(rig.server.events.items.suffix(4) == [.closed(link: 1), .connect, .hello, .resume(FakeService.token(1))])
        #expect(rig.server.count { if case .signOut = $0 { true } else { false } } == 0)
        #expect(rig.tokens.all == ["T:wren": FakeService.token(1)])
    }

    @Test func noSessionForAPlayerWhoCanDoNeither() async {
        var neither = SessionRig.wren
        neither.player.isMultiplayerGamingRestricted = true
        neither.player.isPersonalizedCommunicationRestricted = true
        let rig = SessionRig(player: neither)
        await rig.session.deviceChanged(neither)
        #expect(await rig.session.open() == .idle)
        #expect(rig.server.events.items == [])

        // Under age she can still race: a session.
        var underage = SessionRig.wren
        underage.player.isUnderage = true
        let racing = SessionRig(player: underage)
        await racing.opened()
        // Multiplayer-restricted alone she can still chat.
        var chatting = SessionRig.wren
        chatting.player.isMultiplayerGamingRestricted = true
        let lobby = SessionRig(player: chatting)
        await lobby.opened()
    }

    @Test func noAttemptsOfflineOrBackgrounded() async {
        let rig = SessionRig(isOnline: false)
        await rig.session.deviceChanged(SessionRig.wren)
        #expect(await rig.session.open() == .idle)
        #expect(rig.server.events.items == [])
        // The path is back: at once.
        await rig.session.setOnline(true)
        await rig.opens(1)
        #expect(rig.backoffs == [])

        // The background closes the socket and keeps the token.
        await rig.session.setActive(false)
        #expect(await rig.session.phase == .idle)
        #expect(rig.server.events.items.last == .closed(link: 1))
        #expect(await rig.session.open() == .idle)
        #expect(rig.server.connects == 1)
        await rig.session.setActive(true)
        await rig.opens(2)
        #expect(rig.server.events.items.last == .resume(FakeService.token(1)))

        let background = SessionRig(isActive: false)
        await background.session.deviceChanged(SessionRig.wren)
        #expect(await background.session.open() == .idle)
        #expect(background.server.events.items == [])
    }

    @Test func streamsSurviveAReconnect() async {
        let rig = SessionRig()
        await rig.opened()
        var queue = rig.session.queue.stateUpdates().makeAsyncIterator()
        var identity = rig.session.identity.stateUpdates().makeAsyncIterator()
        #expect(await queue.next() == .idle)
        #expect(await identity.next() == .signedIn(SessionRig.wren.player))
        rig.server.push(.unavailable(.suspended(until: 1_760_400_000)))
        #expect(await queue.next() == .unavailable(.suspended(until: 1_760_400_000)))

        rig.server.script { $0.queue = .unavailable(.cooldown(secondsRemaining: 252)) }
        rig.server.dropLink()
        await rig.opens(2)
        // The same streams, the new connection's words.
        #expect(await identity.next() == .signedOut)
        #expect(await identity.next() == .signedIn(SessionRig.wren.player))
        #expect(await queue.next() == .unavailable(.cooldown(secondsRemaining: 252)))
        rig.server.push(.idle)
        #expect(await queue.next() == .idle)
    }

    @Test func aTapWaitsForTheTryItStarts() async {
        let rig = SessionRig(player: nil, afterSignIn: SessionRig.wren)
        await rig.session.start()
        // "Sign in" is the device's sheet, then a session.
        #expect(await rig.session.identity.signIn() == .signedIn(SessionRig.wren.player))

        let failing = SessionRig()
        failing.server.script { $0.connectFailures = 3 }
        await failing.session.deviceChanged(SessionRig.wren)
        // The try under way fails: the tap hears so, and the session keeps at it behind.
        #expect(await failing.session.open() == .unreachable)
        #expect(await failing.session.phase == .connecting)
        // A tap during the back-off doesn't sit it out.
        await failing.sleeper.waitForSleep(of: .seconds(1))
        #expect(await failing.session.open() == .unreachable)
        failing.server.script { $0.connectFailures = 0 }
        await failing.sleeper.waitForSleep(of: .seconds(1))
        #expect(await failing.session.open() == .open(SessionRig.wren.player))
    }

    @Test func aServerThatNeverAnswersIsGivenUpOnAtTheDeadline() async {
        let rig = SessionRig()
        rig.server.script { $0.hello = nil }
        await rig.session.start()
        await rig.sleeper.waitForSleep(of: SessionRig.openDeadline)
        rig.sleeper.advance(by: SessionRig.openDeadline)
        await rig.sleeper.waitForSleep(of: .seconds(1))
        #expect(rig.server.events.items.contains(.closed(link: 1)))
        #expect(rig.logs.items.contains(.failed(.handshake)))
    }
}

extension OnlineSessionTests {
    /// Game Center can take its time over a signature: the try fails at the deadline, with no socket opened.
    @Test func aSignatureThatNeverComesIsAFailedTry() async {
        let rig = SessionRig(signatureNeverComes: true)
        await rig.session.start()
        await rig.sleeper.waitForSleep(of: SessionRig.signatureDeadline)
        rig.sleeper.advance(by: SessionRig.signatureDeadline)
        await rig.sleeper.waitForSleep(of: .seconds(1))
        #expect(rig.logs.items == [.failed(.noSignature)])
        #expect(rig.server.connects == 0)
    }
}

@Suite(.timeLimit(.minutes(1))) struct KeepAliveTests {
    @Test func pingsEveryThirtySecondsAndNeverLeavesA120sGap() async {
        let rig = SessionRig()
        await rig.opened()
        var pingedAt: [Duration] = [.zero]
        for round in 1...6 {
            await rig.sleeper.waitForSleep(of: .seconds(30))
            rig.sleeper.advance(by: .seconds(30))
            await rig.server.events.wait { events in events.filter { $0 == .ping }.count == round }
            pingedAt.append(rig.sleeper.now)
        }
        #expect(Array(pingedAt.dropFirst()) == [30, 60, 90, 120, 150, 180].map { Duration.seconds($0) })
        // The server drops a connection idle for 120 s.
        #expect(zip(pingedAt, pingedAt.dropFirst()).allSatisfy { $1 - $0 < .seconds(120) })
        #expect(rig.server.connects == 1)
        #expect(await rig.session.phase == .open(SessionRig.wren.player))
    }

    @Test func aLatePongReconnects() async {
        let rig = SessionRig()
        await rig.opened()
        rig.server.script { $0.answersPings = false }
        await rig.sleeper.waitForSleep(of: .seconds(30))
        rig.sleeper.advance(by: .seconds(30))
        await rig.sleeper.waitForSleep(of: .seconds(10))
        #expect(rig.server.connects == 1)
        rig.server.script { $0.answersPings = true }
        rig.sleeper.advance(by: .seconds(10))
        // The dead link is closed before the new one opens, at once, with the token.
        await rig.opens(2)
        #expect(rig.server.events.items.suffix(5) == [.ping, .closed(link: 1), .connect, .hello, .resume(FakeService.token(1))])
        #expect(rig.logs.items.contains(.linkLost))
        #expect(rig.backoffs == [])
    }

    @Test func aLinkTheServerClosesReconnectsAtOnce() async {
        let rig = SessionRig()
        await rig.opened()
        rig.server.dropLink()
        await rig.opens(2)
        #expect(rig.backoffs == [])
    }
}

@Suite(.timeLimit(.minutes(1))) struct BackoffTests {
    @Test func growsToThirtyWithJitterAndResets() async {
        let backoff = Backoff()
        #expect((1...8).map { backoff.delay(afterFailures: $0, jitter: 0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(backoff.delay(afterFailures: 1, jitter: 1) == .milliseconds(1200))
        #expect(backoff.delay(afterFailures: 1, jitter: -1) == .milliseconds(800))
        #expect(backoff.delay(afterFailures: 7, jitter: 1) == .seconds(36))
        #expect(backoff.delay(afterFailures: 7, jitter: -1) == .seconds(24))
        // A draw out of range moves it no further.
        #expect(backoff.delay(afterFailures: 3, jitter: 5) == .milliseconds(4800))

        // In the session: one try at once, then 1 s, 2 s; a session that opens starts the count over.
        let rig = SessionRig()
        rig.server.script { $0.connectFailures = 3 }
        await rig.session.start()
        for seconds in [1, 2, 4] {
            await rig.sleeper.waitForSleep(of: .seconds(seconds))
            rig.sleeper.advance(by: .seconds(seconds))
        }
        await rig.opens(1)
        rig.server.script { $0.connectFailures = 2 }
        rig.server.dropLink()
        for seconds in [1, 2] {
            await rig.sleeper.waitForSleep(of: .seconds(seconds))
            rig.sleeper.advance(by: .seconds(seconds))
        }
        await rig.opens(2)
        #expect(rig.backoffs == [1, 2, 4, 1, 2].map { Duration.seconds($0) })
        #expect(rig.server.connects == 7)
    }

    @Test func stopsAfterSixUntilForeground() async {
        let rig = SessionRig()
        rig.server.script { $0.connectFailures = 100 }
        await rig.session.start()
        for seconds in [1, 2, 4, 8, 16] {
            await rig.sleeper.waitForSleep(of: .seconds(seconds))
            rig.sleeper.advance(by: .seconds(seconds))
        }
        await rig.reaches(.unreachable)
        #expect(rig.server.connects == 6)
        #expect(rig.sleeper.sleepingNow == [])
        #expect(rig.logs.items.last == .gaveUp)
        // Nothing more on its own: neither the path nor the player's state changing back to the same.
        await rig.session.setOnline(true)
        await rig.session.deviceChanged(SessionRig.wren)
        #expect(await rig.session.phase == .unreachable)
        #expect(rig.server.connects == 6)

        // The foreground starts over.
        await rig.session.setActive(false)
        await rig.session.setActive(true)
        await rig.sleeper.waitForSleep(of: .seconds(1))
        #expect(rig.server.connects == 7)

        // And so does a tap, once the tries have run out again.
        for seconds in [1, 2, 4, 8, 16] {
            await rig.sleeper.waitForSleep(of: .seconds(seconds))
            rig.sleeper.advance(by: .seconds(seconds))
        }
        await rig.reaches(.unreachable)
        rig.server.script { $0.connectFailures = 0 }
        #expect(await rig.session.open() == .open(SessionRig.wren.player))
    }
}

/// No token and no signature in anything the client can print (#161).
@Suite(.timeLimit(.minutes(1))) struct TokenHygieneTests {
    /// How `bytes` could show up in text: as an array, a run of it, or hex.
    static func renderings(of bytes: [UInt8]) -> [String] {
        let hex = bytes.prefix(4).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        return ["\(bytes)", bytes.prefix(4).map(String.init).joined(separator: ", "), hex]
    }

    static func printed(_ value: Any) -> String {
        var dumped = ""
        dump(value, to: &dumped)
        return "\(value)\n\(String(reflecting: value))\n\(dumped)"
    }

    @Test func noErrorOrLogContainsTheTokenOrSignature() async throws {
        let token = FakeService.token(9)
        let secrets = Self.renderings(of: token) + Self.renderings(of: FakeService.token(1)) + Self.renderings(of: SessionRig.signatureBytes)
        var text: [String] = []

        // The reply that used to print the call, token and all: `signedOut` to a resume, and to a sign-in.
        let rig = SessionRig(tokens: ["T:wren": token])
        rig.server.script { $0.answersSessionCallsWith = .signedOut }
        let link = try rig.server.connect()
        let remote = RemoteSession(ServiceConnection(link))
        let signature = try await rig.device.identitySignature()
        do {
            _ = try await remote.resume(token: token, as: SessionRig.wren.player)
            Issue.record("signedOut isn't an answer to a resume")
        } catch {
            #expect(error as? ServiceLinkError == .unexpectedReply("signedOut to resume"))
            text.append(Self.printed(error))
        }
        do {
            _ = try await remote.signIn(signature, as: SessionRig.wren.player)
            Issue.record("signedOut isn't an answer to a sign-in")
        } catch {
            #expect(error as? ServiceLinkError == .unexpectedReply("signedOut to signIn"))
            text.append(Self.printed(error))
        }
        text.append(Self.printed(OpenSession(token: token, player: SessionRig.wren.player)))

        // A session's whole life: a wrong answer, an expired token, a sign-in, a lost link, an account gone.
        await rig.session.start()
        await rig.sleeper.waitForSleep(of: .seconds(1))
        rig.server.script {
            $0.answersSessionCallsWith = nil
            $0.resume = [.refused(.sessionExpired)]
        }
        rig.sleeper.advance(by: .seconds(1))
        await rig.opens(1)
        rig.server.dropLink()
        await rig.opens(2)
        rig.device.set(nil)
        await rig.reaches(.idle)
        #expect(rig.logs.items.contains(.failed(.sessionCall)) && rig.logs.items.contains(.refused(.sessionExpired)))
        #expect(rig.logs.items.contains(.opened(resumed: false)) && rig.logs.items.contains(.opened(resumed: true)))
        text += rig.logs.items.map(Self.printed) + rig.phases.items.map(Self.printed)

        for secret in secrets {
            #expect(text.filter { $0.contains(secret) } == [], "printed \(secret)")
        }
        // The scan can find one: the token does print when asked for outright.
        #expect("\(token)".contains(secrets[0]) && "\(token)".contains(secrets[1]))
    }
}

@Suite(.timeLimit(.minutes(1))) struct TermsFlowTests {
    @Test func aServerVersionAheadOfTheBundledTextAsksForUpdate() async throws {
        let bundled = TermsVersion(2)
        #expect(TermsPrompt(status: .needsAcceptance(current: TermsVersion(3), lastAccepted: bundled), bundled: bundled) == .updateRequired)
        #expect(TermsPrompt(status: .needsAcceptance(current: TermsVersion(3), lastAccepted: nil), bundled: bundled) == .updateRequired)
        // The text she can read: the sheet, for the version the server asks for.
        #expect(TermsPrompt(status: .needsAcceptance(current: bundled, lastAccepted: TermsVersion(1)), bundled: bundled) == .sheet(bundled))
        #expect(TermsPrompt(status: .needsAcceptance(current: TermsVersion(1), lastAccepted: nil), bundled: bundled) == .sheet(TermsVersion(1)))
        #expect(TermsPrompt(status: .accepted(TermsVersion(3)), bundled: bundled) == .none)
        #expect(TermsPrompt(status: nil, bundled: bundled) == .none)
    }

    @Test func theServerDecidesTheTermsThroughTheSession() async throws {
        let rig = SessionRig()
        let terms = rig.session.terms
        // No session, no answer: the app treats the terms as due.
        await #expect(throws: OnlineSessionError.notConnected) { try await terms.status() }
        await rig.opened()
        #expect(try await terms.status() == .needsAcceptance(current: TermsVersion(2), lastAccepted: nil))
        await #expect(throws: TermsError.staleVersion(current: TermsVersion(2))) { try await terms.accept(TermsVersion(1)) }
        #expect(try await terms.accept(TermsVersion(2)) == .accepted(TermsVersion(2)))
        // The same service after a reconnect.
        rig.server.dropLink()
        await rig.opens(2)
        #expect(try await terms.status() == .accepted(TermsVersion(2)))
    }
}
