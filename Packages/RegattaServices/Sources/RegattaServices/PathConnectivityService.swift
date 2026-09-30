#if canImport(Network)
import Dispatch
import Network
import Synchronization

/// Connectivity from the system's network path (`NWPathMonitor`): what the app's `PathConnectivity` placeholder
/// does, behind `ConnectivityService`; #242 swaps the app over. Only where Network exists (not on Linux).
/// Unchecked: its state is behind the mutex, and the monitor is only started and cancelled.
public final class PathConnectivityService: ConnectivityService, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let state: Mutex<State>

    private struct State {
        /// Optimistic until the first path update, so Race online doesn't flash "Offline" at launch.
        var current = ConnectivityStatus.online
        var listeners: [Int: AsyncStream<ConnectivityStatus>.Continuation] = [:]
        var nextListener = 0
    }

    public init() {
        state = Mutex(State())
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied ? .online : .offline)
        }
        monitor.start(queue: DispatchQueue(label: "com.phillreeder.regatta.connectivity"))
    }

    deinit {
        monitor.cancel()
        state.withLock { $0.listeners.values.forEach { $0.finish() } }
    }

    private func update(_ status: ConnectivityStatus) {
        let listeners = state.withLock { state -> [AsyncStream<ConnectivityStatus>.Continuation] in
            guard state.current != status else { return [] }
            state.current = status
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield(status) }
    }

    public func status() -> ConnectivityStatus { state.withLock { $0.current } }

    public func statusUpdates() -> AsyncStream<ConnectivityStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectivityStatus.self)
        let id = state.withLock { state in
            let id = state.nextListener
            state.nextListener += 1
            state.listeners[id] = continuation
            continuation.yield(state.current)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }
}
#endif
