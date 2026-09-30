import Synchronization

/// A `ConnectivityService` that plays a list of statuses: the first is the status now, and each read of a stream
/// moves to the next, dropping any repeat; the stream finishes at the end (a real one stays open).
public actor ScriptedConnectivityService: ConnectivityService {
    private var current: ConnectivityStatus
    private var pending: [ConnectivityStatus]

    /// Starts at `initial`, then changes through `changes`.
    public init(_ initial: ConnectivityStatus, changes: [ConnectivityStatus] = []) {
        current = initial
        pending = changes
    }

    public func status() -> ConnectivityStatus { current }

    public nonisolated func statusUpdates() -> AsyncStream<ConnectivityStatus> {
        let started = Mutex(false)
        return AsyncStream {
            let first = started.withLock { started in
                defer { started = true }
                return !started
            }
            return await self.next(first: first)
        }
    }

    private func next(first: Bool) -> ConnectivityStatus? {
        if first { return current }
        while let status = pending.first {
            pending.removeFirst()
            if status != current {
                current = status
                return status
            }
        }
        return nil
    }
}
