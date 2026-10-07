import RegattaCore
import RegattaServices
import Testing

/// The scripted fakes' streams (#314): each stream reads the script with its own cursor, and nothing queued
/// for a stream is lost.
@Suite struct FakeStreamTests {
    static func all<Element: Sendable>(_ stream: AsyncStream<Element>) async -> [Element] {
        var items: [Element] = []
        for await item in stream { items.append(item) }
        return items
    }

    /// Two streams opened together each read the whole script, whichever reads first.
    @Test func twoStreamsOnOneFakeEachReadTheWholeScript() async {
        let queue = Fixtures.queue(.cooldown)
        let (queueA, queueB) = (queue.stateUpdates(), queue.stateUpdates())
        let queueScript: [QueueState] = [
            .unavailable(.cooldown(secondsRemaining: 3)), .unavailable(.cooldown(secondsRemaining: 2)),
            .unavailable(.cooldown(secondsRemaining: 1)), .idle,
        ]
        #expect(await Self.all(queueA) == queueScript)
        #expect(await Self.all(queueB) == queueScript)

        let identity = ScriptedIdentityService(IdentityScenario(initial: .signedIn(Fixtures.ana), background: [.signedOut]))
        let (identityA, identityB) = (identity.stateUpdates(), identity.stateUpdates())
        #expect(await Self.all(identityA) == [.signedIn(Fixtures.ana), .signedOut])
        #expect(await Self.all(identityB) == [.signedIn(Fixtures.ana), .signedOut])
        #expect(await identity.state() == .signedOut, "the first read of a change moves the fake")

        let connectivity = ScriptedConnectivityService(.online, changes: [.offline, .offline, .online])
        let (pathA, pathB) = (connectivity.statusUpdates(), connectivity.statusUpdates())
        #expect(await Self.all(pathA) == [.online, .offline, .online])
        #expect(await Self.all(pathB) == [.online, .offline, .online])

        let refund = StoreScenario(products: Fixtures.products, owned: [Fixtures.paid], background: [[]])
        let store = ScriptedStoreService(refund)
        let (ownedA, ownedB) = (store.ownershipUpdates(), store.ownershipUpdates())
        #expect(await Self.all(ownedA) == [[Fixtures.paid], []])
        #expect(await Self.all(ownedB) == [[Fixtures.paid], []])

        let lobby = Fixtures.lobby(.racing)
        let (feedA, feedB) = (lobby.feed(), lobby.feed())
        let lobbyA = await Self.all(feedA)
        #expect(lobbyA.count == 3)
        #expect(await Self.all(feedB) == lobbyA)
    }

    /// A stream opened after others have read on starts at the state then, not at the script's start.
    @Test func aLateStreamStartsAtTheStateNow() async {
        let queue = Fixtures.queue(.cooldown)
        var early = queue.stateUpdates().makeAsyncIterator()
        _ = await early.next()
        _ = await early.next()
        #expect(await Self.all(queue.stateUpdates()) == [.unavailable(.cooldown(secondsRemaining: 2)), .unavailable(.cooldown(secondsRemaining: 1)), .idle])
    }

    /// Joining starts a new script: a stream already open follows it.
    @Test func joiningSwapsTheScriptForOpenStreams() async throws {
        let queue = Fixtures.queue(.joinable)
        let (watching, other) = (queue.stateUpdates(), queue.stateUpdates())
        var reader = watching.makeAsyncIterator()
        #expect(await reader.next() == .idle)
        var otherReader = other.makeAsyncIterator()
        #expect(await otherReader.next() == .idle)
        try await queue.join()
        var rest: [QueueState] = []
        while let state = await reader.next() { rest.append(state) }
        #expect(rest.last == .fleetLocked)
        var otherRest: [QueueState] = []
        while let state = await otherReader.next() { otherRest.append(state) }
        #expect(otherRest == rest)
    }

    /// Two purchases before the stream is read both land (#314): they were snapshots of the same owned set.
    @Test func twoPurchasesBeforeAReadBothLand() async throws {
        for checkout in [StoreScenario.Checkout.askToBuy(approved: true), .completes] {
            let store = ScriptedStoreService(StoreScenario(products: Fixtures.products, checkout: checkout))
            let updates = store.ownershipUpdates()
            var reader = updates.makeAsyncIterator()
            #expect(await reader.next() == [], "\(checkout)")
            for product in Fixtures.products { _ = try await store.purchase(product.id) }
            var last: Set<DesignID>?
            while let owned = await reader.next() { last = owned }
            #expect(last == [Fixtures.paid, Fixtures.paidWave], "\(checkout)")
            #expect(await store.ownedDesigns() == [Fixtures.paid, Fixtures.paidWave], "\(checkout)")
        }
    }

    /// The own line a post queues on the feed isn't stored twice when the feed brings it.
    @Test func anOwnPostIsInTheHistoryOnce() async throws {
        let lobby = Fixtures.lobby(.open)
        let feed = lobby.feed()
        let message = try await lobby.post("fair winds")
        _ = await Self.all(feed)
        #expect(try await lobby.history().filter { $0.id == message.id }.count == 1)
    }
}
