import Synchronization

/// What a `ScriptedQueueService` plays. Each step is delivered when the stream is next read, so a run doesn't
/// depend on time.
public struct QueueScenario: Sendable {
    /// The state the first read of a stream gives.
    public var initial: QueueState
    /// The changes that follow with no one joining: a cooldown counting down to `.idle`, say.
    public var background: [QueueState]
    /// The changes that follow a successful `join`, replacing any background ones still to come: the
    /// countdown and the queued count, ending in `.fleetLocked`.
    public var afterJoin: [QueueState]

    public init(initial: QueueState, background: [QueueState] = [], afterJoin: [QueueState] = []) {
        self.initial = initial
        self.background = background
        self.afterJoin = afterJoin
    }
}

/// A `QueueService` that plays its scenario: the stream gives the initial state, then one step per read, and
/// finishes when the script runs out (a real stream would wait). `join` and `leave` act on the state last
/// delivered.
public actor ScriptedQueueService: QueueService {
    private var current: QueueState
    private var pending: [QueueState]
    private let afterJoin: [QueueState]
    /// Whether a join is under way: after `join`, until the script reaches fleet lock or `leave` is called.
    private var joined = false

    public init(_ scenario: QueueScenario) {
        current = scenario.initial
        pending = scenario.background
        afterJoin = scenario.afterJoin
    }

    /// Streams share the script: the first read of each gives the state now, and every read after it the
    /// next step, whichever stream makes it.
    public nonisolated func stateUpdates() -> AsyncStream<QueueState> {
        let started = Mutex(false)
        return AsyncStream {
            let first = started.withLock { started in
                defer { started = true }
                return !started
            }
            return await self.next(first: first)
        }
    }

    private func next(first: Bool) -> QueueState? {
        if first { return current }
        guard !pending.isEmpty else { return nil }
        current = pending.removeFirst()
        if case .fleetLocked = current { joined = false }
        return current
    }

    public func join() throws {
        guard !joined else { throw QueueError.alreadyQueued }
        switch current {
        case .unavailable(let refusal): throw QueueError.refused(refusal)
        case .queued, .fleetLocked: throw QueueError.alreadyQueued
        case .idle: break
        }
        joined = true
        pending = afterJoin
    }

    public func leave() throws {
        guard joined else { throw QueueError.notQueued }
        joined = false
        current = .idle
        pending = [.idle]
    }
}
