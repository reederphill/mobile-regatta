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

/// A `QueueService` that plays its scenario: a stream gives the state now, then one step per read, and
/// finishes when the script runs out (a real stream would wait). `join` and `leave` act on the state last
/// delivered.
public actor ScriptedQueueService: QueueService {
    private var current: QueueState
    private let script: StreamScript<QueueState>
    /// The state before the script's first step: a stream opened at its start gives it first.
    private var scriptStart: QueueState
    private let afterJoin: [QueueState]
    /// Whether a join is under way: after `join`, until the script reaches fleet lock or `leave` is called.
    private var joined = false

    public init(_ scenario: QueueScenario) {
        current = scenario.initial
        script = StreamScript(scenario.background)
        scriptStart = scenario.initial
        afterJoin = scenario.afterJoin
    }

    /// Each stream reads the script with its own cursor (#314): the first read gives the state when the stream was
    /// opened, and every read after it the next step. `join` and `leave` start a new script that every
    /// open stream follows.
    public nonisolated func stateUpdates() -> AsyncStream<QueueState> {
        let cursor = script.cursor()
        return AsyncStream { await self.next(cursor) }
    }

    private func next(_ cursor: StreamCursor) -> QueueState? {
        let loaded = cursor.load()
        var position = loaded.position
        guard loaded.hasStarted else {
            let (start, before) = script.steps(before: position)
            cursor.store(start)
            return before.last ?? scriptStart
        }
        defer { cursor.store(position) }
        guard let (_, state, isFirstRead) = script.next(&position) else { return nil }
        if isFirstRead {
            current = state
            if case .fleetLocked = state { joined = false }
        }
        return state
    }

    public func join() throws {
        guard !joined else { throw QueueError.alreadyQueued }
        switch current {
        case .unavailable(let refusal): throw QueueError.refused(refusal)
        case .queued, .fleetLocked: throw QueueError.alreadyQueued
        case .idle: break
        }
        joined = true
        scriptStart = current
        script.replace(with: afterJoin)
    }

    public func leave() throws {
        guard joined else { throw QueueError.notQueued }
        joined = false
        current = .idle
        scriptStart = .idle
        script.replace(with: [.idle])
    }
}
