/// A `ConnectivityService` that plays a list of statuses: the first is the status now, and each read of a stream
/// moves to the next, dropping any repeat; the stream finishes at the end (a real one stays open). Each stream
/// reads the list with its own cursor (#314).
public actor ScriptedConnectivityService: ConnectivityService {
    private var current: ConnectivityStatus
    private let initial: ConnectivityStatus
    private let script: StreamScript<ConnectivityStatus>

    /// Starts at `initial`, then changes through `changes`.
    public init(_ initial: ConnectivityStatus, changes: [ConnectivityStatus] = []) {
        current = initial
        self.initial = initial
        var steps: [ConnectivityStatus] = []
        for status in changes where status != (steps.last ?? initial) { steps.append(status) }
        script = StreamScript(steps)
    }

    public func status() -> ConnectivityStatus { current }

    public nonisolated func statusUpdates() -> AsyncStream<ConnectivityStatus> {
        let cursor = script.cursor()
        return AsyncStream { await self.next(cursor) }
    }

    private func next(_ cursor: StreamCursor) -> ConnectivityStatus? {
        let loaded = cursor.load()
        var position = loaded.position
        guard loaded.hasStarted else {
            let (start, before) = script.steps(before: position)
            cursor.store(start)
            return before.last ?? initial
        }
        defer { cursor.store(position) }
        guard let (_, status, isFirstRead) = script.next(&position) else { return nil }
        if isFirstRead { current = status }
        return status
    }
}
