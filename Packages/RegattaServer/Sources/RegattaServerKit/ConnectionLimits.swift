import NIOCore
import NIOHTTP1
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

/// Whose connection it is, for the per-address caps (#469).
///
/// By default the socket's own address. Behind a reverse proxy (Fly's edge, a load balancer) that is the proxy's, and
/// every client would share one address's cap: then `header` names the request header the proxy sets to the client's
/// address (`CLIENT_ADDRESS_HEADER`), and the caps count that address instead. No header is trusted unless it is named
/// here: a client can send any header it likes, so the setting is only safe when every connection comes through the
/// proxy and the proxy sets or overwrites the header (`Fly-Client-IP`) or appends to it (`X-Forwarded-For`).
///
/// An IPv6 client is counted by its /64 prefix: a host is given at least a /64 and can pick any address in it, so
/// counting whole addresses would cap nothing. An IPv4-mapped IPv6 address counts as its IPv4 address.
public struct ClientAddressRule: Sendable, Equatable {
    /// The header a trusted proxy sets; nil: none is trusted.
    public var header: String?
    /// For a header that lists addresses (`X-Forwarded-For`: each proxy appends the address it took the request from):
    /// which entry, counted from the right, the trusted proxies vouch for. 1 with one proxy in front of the server; one
    /// more for each further trusted proxy in the chain. Entries to the left of it are the client's own word.
    public var trustedHops = 1

    public init(header: String? = nil, trustedHops: Int = 1) {
        self.header = header
        self.trustedHops = trustedHops
    }

    /// The key a connection from `remote`, upgraded by a request with `headers`, is counted under; nil for none (a
    /// Unix socket: counted against the total only). A connection without the header, or with one that isn't an
    /// address, is counted under the socket's address: behind the proxy that is the proxy's, one cap for them all.
    public func key(remote: SocketAddress?, headers: HTTPHeaders) -> String? {
        if let header {
            let entries = headers[canonicalForm: header]
            if entries.count >= trustedHops, trustedHops >= 1, let forwarded = Self.parse(entries[entries.count - trustedHops]) {
                return Self.key(forwarded)
            }
        }
        return Self.key(remote)
    }

    /// The key an address is counted under: an IPv4 address itself, an IPv6 address's /64.
    public static func key(_ address: SocketAddress?) -> String? {
        switch address {
        case .v4: return address?.ipAddress
        case .v6(let v6):
            let bytes = withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return bytes[12...].map { String($0) }.joined(separator: ".")
            }
            let groups = stride(from: 0, to: 8, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
            return groups.joined(separator: ":") + "::/64"
        case .unixDomainSocket, nil: return nil
        }
    }

    /// An address as a proxy writes it: `203.0.113.7`, `203.0.113.7:4711`, `2001:db8::1`, `[2001:db8::1]:4711`.
    static func parse(_ entry: Substring) -> SocketAddress? {
        var host = entry.drop { $0 == " " || $0 == "\t" }
        while let last = host.last, last == " " || last == "\t" { host = host.dropLast() }
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { return nil }
            host = host[host.index(after: host.startIndex)..<end]
        } else if host.contains("."), let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            host = host[..<colon]
        }
        return try? SocketAddress(ipAddress: String(host), port: 0)
    }
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
    /// (a Unix socket, a test channel) counts against the total only. An IPv6 address counts as its /64 (#469).
    func acquire(_ address: SocketAddress?) -> Slot? { acquire(key: ClientAddressRule.key(address)) }

    /// A slot for a connection counted under `key` (`ClientAddressRule.key`), or nil when either cap is reached.
    func acquire(key: String?) -> Slot? {
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
