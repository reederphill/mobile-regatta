import NIOCore
import Synchronization

/// How many WebSocket connections the server holds at once, per path (#146, from #145's review R4): per remote
/// address and in all. A connection over a cap is closed as soon as it upgrades, before it is read.
public struct ConnectionLimits: Sendable, Equatable {
    /// `/service`: one per client is the norm; a few more for a reconnect overlapping the old socket.
    public var servicePerAddress = 8
    public var serviceTotal = 512
    /// `/race`: one per seat. Higher per address than `/service`, so a load client on one host can fill a fleet (16).
    public var racePerAddress = 32
    /// `maxRaces` (64) × 16 seats.
    public var raceTotal = 1024

    public init() {}
}

/// Counts one path's open connections against its caps. Thread-safe; each `acquire` that succeeds is released once.
final class ConnectionCounter: Sendable {
    private struct State {
        var total = 0
        var byAddress: [String: Int] = [:]
    }

    let perAddress: Int
    let total: Int
    private let state = Mutex(State())

    init(perAddress: Int, total: Int) {
        self.perAddress = perAddress
        self.total = total
    }

    /// A slot for a connection from `address`, or nil when either cap is reached. A connection with no address
    /// (a Unix socket, a test channel) counts against the total only.
    func acquire(_ address: SocketAddress?) -> Slot? {
        let key = address?.ipAddress
        let granted = state.withLock { state -> Bool in
            guard state.total < total else { return false }
            if let key {
                guard state.byAddress[key, default: 0] < perAddress else { return false }
                state.byAddress[key, default: 0] += 1
            }
            state.total += 1
            return true
        }
        return granted ? Slot(counter: self, key: key) : nil
    }

    fileprivate func release(_ key: String?) {
        state.withLock { state in
            state.total -= 1
            guard let key, let count = state.byAddress[key] else { return }
            state.byAddress[key] = count > 1 ? count - 1 : nil
        }
    }

    /// Open connections, for tests.
    var open: (total: Int, addresses: Int) { state.withLock { ($0.total, $0.byAddress.count) } }

    /// One held connection; `release()` gives it back.
    struct Slot: Sendable {
        let counter: ConnectionCounter
        let key: String?

        func release() { counter.release(key) }
    }
}
