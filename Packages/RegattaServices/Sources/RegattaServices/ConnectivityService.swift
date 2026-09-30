// Whether the device can reach the network (#25). Race online and the lobby need it; practice, My boat (owned
// designs from StoreKit's cache), Help and Settings don't. Offline, Race online is disabled and labelled "Offline",
// and the lobby area says "Lobby needs a connection".

public enum ConnectivityStatus: Hashable, Sendable {
    case online
    case offline

    public var isOnline: Bool { self == .online }
}

public protocol ConnectivityService: Sendable {
    /// Whether the device is online now.
    func status() async -> ConnectivityStatus
    /// The status now, then each change: never the same status twice in a row.
    func statusUpdates() -> AsyncStream<ConnectivityStatus>
}
