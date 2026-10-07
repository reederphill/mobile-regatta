import Synchronization

/// The steps a scripted fake's streams play, each stream reading them through its own `StreamCursor` (#314), so
/// two streams on one fake each see every step. A stream starts where the script stood when it was opened (the
/// steps read before that are history) and reads on at its own pace; the first stream to read a step moves the
/// fake's state. `replace(with:)` starts a new script (a queue join, say) that every open stream follows from its
/// first step. Behind a mutex so a stream can take its start when it is opened, outside the fake's actor.
final class StreamScript<Step: Sendable>: Sendable {
    private struct Storage {
        var steps: [Step]
        var generation = 0
        /// How many steps of this script some stream has read.
        var delivered = 0

        /// `position` in the script now: the start of a new script if one replaced its own.
        func current(_ position: StreamCursor.Position) -> StreamCursor.Position {
            generation == position.generation ? position : StreamCursor.Position(generation: generation, index: 0)
        }
    }

    private let storage: Mutex<Storage>

    init(_ steps: [Step]) { storage = Mutex(Storage(steps: steps)) }

    /// Adds a step at the end, for every stream to read.
    func append(_ step: Step) { storage.withLock { $0.steps.append(step) } }

    /// Adds a step the fake has already taken (a sign-in that answers at once): the open streams still read it, a
    /// stream opened later starts after it.
    func appendTaken(_ step: Step) {
        storage.withLock {
            $0.steps.append(step)
            $0.delivered = $0.steps.count
        }
    }

    /// Swaps in a new script that every open stream reads from its start.
    func replace(with steps: [Step]) {
        storage.withLock {
            $0.steps = steps
            $0.generation += 1
            $0.delivered = 0
        }
    }

    /// A cursor for a stream opened now: it starts after the steps already read.
    func cursor() -> StreamCursor {
        StreamCursor(at: storage.withLock { StreamCursor.Position(generation: $0.generation, index: $0.delivered) })
    }

    /// Where a stream at `position` really is, in the script now, and the steps before it, oldest first.
    func steps(before position: StreamCursor.Position) -> (position: StreamCursor.Position, steps: [Step]) {
        storage.withLock { storage in
            let position = storage.current(position)
            return (position, Array(storage.steps.prefix(position.index)))
        }
    }

    /// The step at `position` and whether it is the first read of it (the fake's state moves on), moving
    /// `position` past it; nil when the stream has read the whole script.
    func next(_ position: inout StreamCursor.Position) -> (index: Int, step: Step, isFirstRead: Bool)? {
        storage.withLock { storage in
            position = storage.current(position)
            guard position.index < storage.steps.count else { return nil }
            let index = position.index
            position.index += 1
            let isFirstRead = position.index > storage.delivered
            if isFirstRead { storage.delivered = position.index }
            return (index, storage.steps[index], isFirstRead)
        }
    }
}

/// One stream's place in a `StreamScript`, taken when the stream is opened. Its first read gives the state at
/// that place; each read after it, the next step.
final class StreamCursor: Sendable {
    struct Position: Sendable {
        var generation: Int
        var index: Int
    }

    private let state: Mutex<(position: Position, hasStarted: Bool)>

    init(at start: Position) { state = Mutex((start, false)) }

    /// The stream's place, and whether it has given its first value. A stream reads one value at a time, so a load
    /// and the store after it never interleave with another read of the same stream.
    func load() -> (position: Position, hasStarted: Bool) { state.withLock { $0 } }

    func store(_ position: Position) { state.withLock { $0 = (position, true) } }
}
