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
    func save(_ state: AnalyticsState)
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
        var isFlushing = false
    }

    private let transport: any AnalyticsTransport
    private let storage: any AnalyticsStorage
    private let makeInstallID: @Sendable () -> String
    private let now: @Sendable () -> Int64
    private let state: Mutex<State>

    /// `makeInstallID` makes a random id, once per install; `now` is seconds since the epoch.
    public init(transport: any AnalyticsTransport, storage: any AnalyticsStorage, isSharing: Bool,
                makeInstallID: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Int64) {
        self.transport = transport
        self.storage = storage
        self.makeInstallID = makeInstallID
        self.now = now
        var stored = storage.load()
        if !isSharing && !stored.pending.isEmpty {
            stored.pending = []
            storage.save(stored)
        }
        state = Mutex(State(stored: stored, isSharing: isSharing))
    }

    /// Logs nothing and sends nothing: for previews and tests that don't look.
    public static func discarding() -> Analytics {
        Analytics(transport: ScriptedAnalyticsTransport(), storage: InMemoryAnalyticsStorage(), isSharing: false,
                  makeInstallID: { "discarding" }, now: { 0 })
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
            storage.save(state.stored)
            return id
        }
    }

    /// Buffers an event, numbered and timed now, unless Share usage data is off.
    public func log(_ event: UsageEvent) {
        state.withLock { state in
            guard state.isSharing else { return }
            let sequence = state.stored.nextSequence
            state.stored.nextSequence += 1
            state.stored.pending.append(AnalyticsEvent(sequence: sequence, name: event.name, time: now(), properties: event.properties))
            if state.stored.pending.count > Self.bufferLimit {
                state.stored.pending.removeFirst(state.stored.pending.count - Self.bufferLimit)
            }
            storage.save(state.stored)
        }
    }

    /// Share usage data changed. Off clears the buffer, and a send in flight leaves nothing behind; the install id
    /// and the sequence carry on.
    public func setSharing(_ isSharing: Bool) {
        state.withLock { state in
            guard state.isSharing != isSharing else { return }
            state.isSharing = isSharing
            guard !isSharing else { return }
            state.generation += 1
            state.stored.pending = []
            storage.save(state.stored)
        }
    }

    /// Sends the buffer oldest first, in batches of at most `AnalyticsBatch.maxEvents`, removing each batch once
    /// it's sent. A failed send stops and keeps the rest for next time. One flush runs at a time; with Share usage
    /// data off it never calls the transport.
    public func flush() async {
        guard state.withLock({ state in
            guard state.isSharing, !state.isFlushing else { return false }
            state.isFlushing = true
            return true
        }) else { return }
        defer { state.withLock { $0.isFlushing = false } }
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
                storage.save(state.stored)
                return true
            }
            guard carryOn else { return }
        }
    }
}
