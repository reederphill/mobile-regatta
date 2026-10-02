import Synchronization

// The device's usage analytics (#28, #128): events wait in a persisted buffer and go to the race server in batches
// through an `AnalyticsTransport`, keyed to a random install ID. Share usage data off means nothing is buffered and
// nothing sent, and turning it off clears the buffer. The clock, the id maker and the storage come in from the app.

/// What `Analytics` keeps between launches.
public struct AnalyticsState: Equatable, Sendable {
    /// Made once, on first use; kept until the app's data goes (a reinstall).
    public var installID: InstallID?
    /// The sequence the next event gets: from 1, never reused.
    public var nextSequence: Int
    /// Events not yet sent, oldest first.
    public var pending: [AnalyticsEvent]

    public init(installID: InstallID? = nil, nextSequence: Int = 1, pending: [AnalyticsEvent] = []) {
        self.installID = installID
        self.nextSequence = nextSequence
        self.pending = pending
    }
}

/// Where `Analytics` keeps its state: the app's defaults, or memory.
public protocol AnalyticsStorage: Sendable {
    func load() -> AnalyticsState
    /// Throws when `state` couldn't be stored, leaving what was stored before.
    func save(_ state: AnalyticsState) throws
}

/// Keeps the state in memory: tests and UI tests. A new one is a fresh install.
public final class InMemoryAnalyticsStorage: AnalyticsStorage {
    private let state: Mutex<AnalyticsState>

    public init(_ state: AnalyticsState = AnalyticsState()) { self.state = Mutex(state) }

    public func load() -> AnalyticsState { state.withLock { $0 } }
    public func save(_ state: AnalyticsState) { self.state.withLock { $0 = state } }
}

public final class Analytics: Sendable {
    /// The most events kept waiting; past it the oldest go.
    public static let bufferLimit = 500

    private struct State {
        var stored: AnalyticsState
        var isSharing: Bool
        /// Bumped whenever the buffer is cleared, so a send in flight doesn't remove what came after.
        var generation = 0
        /// The flush running now, which a later `flush()` joins.
        var flushing: Task<Void, Never>?
    }

    private let transport: any AnalyticsTransport
    private let storage: any AnalyticsStorage
    private let makeInstallID: @Sendable () -> String
    private let now: @Sendable () -> Int64
    /// `discarding()`'s: off for good, whatever `setSharing` is told.
    private let isDiscarding: Bool
    private let state: Mutex<State>

    /// `makeInstallID` makes a random id, once per install; `now` is seconds since the epoch.
    public convenience init(transport: any AnalyticsTransport, storage: any AnalyticsStorage, isSharing: Bool,
                            makeInstallID: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Int64) {
        self.init(transport: transport, storage: storage, isSharing: isSharing, isDiscarding: false,
                  makeInstallID: makeInstallID, now: now)
    }

    private init(transport: any AnalyticsTransport, storage: any AnalyticsStorage, isSharing: Bool, isDiscarding: Bool,
                 makeInstallID: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Int64) {
        self.transport = transport
        self.storage = storage
        self.makeInstallID = makeInstallID
        self.now = now
        self.isDiscarding = isDiscarding
        var stored = storage.load()
        if !isSharing && !stored.pending.isEmpty {
            stored.pending = []
            try? storage.save(stored)
        }
        state = Mutex(State(stored: stored, isSharing: isSharing))
    }

    /// Logs nothing and sends nothing, even told Share usage data is on: for previews and tests that don't look.
    public static func discarding() -> Analytics {
        Analytics(transport: ScriptedAnalyticsTransport(), storage: InMemoryAnalyticsStorage(), isSharing: false,
                  isDiscarding: true, makeInstallID: { "discarding" }, now: { 0 })
    }

    /// Share usage data.
    public var isSharing: Bool { state.withLock { $0.isSharing } }

    /// Events waiting to be sent, oldest first.
    public var pending: [AnalyticsEvent] { state.withLock { $0.stored.pending } }

    /// This install's id, made the first time it's asked for.
    public var installID: InstallID {
        state.withLock { state in
            if let id = state.stored.installID { return id }
            let id = InstallID(makeInstallID())
            state.stored.installID = id
            try? storage.save(state.stored)
            return id
        }
    }

    /// Buffers an event, numbered and timed now, unless Share usage data is off. An event the storage can't keep is
    /// dropped, so what's waiting is never ahead of what's stored.
    public func log(_ event: UsageEvent) {
        state.withLock { state in
            guard state.isSharing else { return }
            var stored = state.stored
            let sequence = stored.nextSequence
            stored.nextSequence += 1
            stored.pending.append(AnalyticsEvent(sequence: sequence, name: event.name, time: now(), properties: event.properties))
            if stored.pending.count > Self.bufferLimit {
                stored.pending.removeFirst(stored.pending.count - Self.bufferLimit)
            }
            guard (try? storage.save(stored)) != nil else { return }
            state.stored = stored
        }
    }

    /// Share usage data changed. Off clears the buffer, and a send in flight leaves nothing behind; the install id
    /// and the sequence carry on. A `discarding()` analytics stays off.
    public func setSharing(_ isSharing: Bool) {
        guard !isDiscarding else { return }
        state.withLock { state in
            guard state.isSharing != isSharing else { return }
            state.isSharing = isSharing
            guard !isSharing else { return }
            state.generation += 1
            state.stored.pending = []
            try? storage.save(state.stored)
        }
    }

    /// Sends the buffer oldest first, in batches of at most `AnalyticsBatch.maxEvents`, removing each batch once
    /// it's sent. A failed send stops and keeps the rest for next time. One flush runs at a time: a call while one
    /// runs waits for it to finish. With Share usage data off it never calls the transport.
    public func flush() async {
        let running = state.withLock { state -> Task<Void, Never> in
            if let running = state.flushing { return running }
            // The task can't take the lock to clear itself until this returns, so it's stored first.
            let running = Task { await self.drain() }
            state.flushing = running
            return running
        }
        await running.value
    }

    private func drain() async {
        defer { state.withLock { $0.flushing = nil } }
        guard isSharing else { return }
        let id = installID
        while true {
            let next: (events: [AnalyticsEvent], generation: Int)? = state.withLock { state in
                guard state.isSharing, !state.stored.pending.isEmpty else { return nil }
                return (Array(state.stored.pending.prefix(AnalyticsBatch.maxEvents)), state.generation)
            }
            guard let next else { return }
            do {
                _ = try await transport.send(AnalyticsBatch(installID: id, events: next.events))
            } catch {
                return
            }
            let sent = Set(next.events.map(\.sequence))
            let carryOn = state.withLock { state in
                guard state.generation == next.generation else { return false }
                state.stored.pending.removeAll { sent.contains($0.sequence) }
                // Removing only shrinks what was stored; were it to fail, a relaunch resends and the server dedupes.
                try? storage.save(state.stored)
                return true
            }
            guard carryOn else { return }
        }
    }
}
