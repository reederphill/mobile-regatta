import Foundation
import os
import RegattaProtocol
import RegattaServiceClient

/// A service connection (`/service`, #145) over a `URLSessionWebSocketTask`, as the online session reads it (#161):
/// one binary message per frame, and the WebSocket's own ping for the keep-alive.
///
/// `maximumMessageSize` is raised to the protocol's frame cap (`serviceFrameLimit`): URLSession's default is 1 MiB,
/// and a larger frame would fail the socket.
nonisolated final class URLSessionServiceLink: SessionLink, @unchecked Sendable {
    // @unchecked: `task` is thread-safe; the rest are Sendable lets.
    let incoming: AsyncStream<[UInt8]>
    private let frames: AsyncStream<[UInt8]>.Continuation
    private let task: URLSessionWebSocketTask
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    /// Opens `url` and returns once the server has answered a ping, so a server that isn't there fails here, within
    /// `timeout`, and not at the first frame.
    static func connect(to url: URL, session: URLSession = .shared, timeout: Duration = .seconds(10)) async throws -> URLSessionServiceLink {
        let link = URLSessionServiceLink(url: url, session: session)
        let deadline = Task {
            try await Task.sleep(for: timeout)
            link.close()
        }
        defer { deadline.cancel() }
        do {
            try await link.ping()
        } catch {
            link.close()
            throw error
        }
        return link
    }

    /// `resumes` false leaves the socket unopened, for a test of how it is set up.
    init(url: URL, session: URLSession, resumes: Bool = true) {
        (incoming, frames) = AsyncStream.makeStream()
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = serviceFrameLimit
        guard resumes else { return }
        task.resume()
        receiveNext()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    /// The largest message the socket takes: the protocol's frame cap.
    var maximumMessageSize: Int { task.maximumMessageSize }

    func send(_ frame: [UInt8]) {
        guard !isClosed.withLock({ $0 }) else { return }
        task.send(.data(Data(frame))) { [weak self] error in
            if error != nil { self?.close() }
        }
    }

    func close() {
        let first = isClosed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        task.cancel(with: .normalClosure, reason: nil)
        frames.finish()
    }

    func ping() async throws {
        if isClosed.withLock({ $0 }) { throw ServiceLinkError.closed }
        // URLSession may call the handler again when the task ends: only the first call counts.
        let answered = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                let first = answered.withLock { answered in
                    defer { answered = true }
                    return !answered
                }
                guard first else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                frames.yield([UInt8](data))
                receiveNext()
            case .success:
                // The protocol is binary only; a text message can't be a frame.
                receiveNext()
            case .failure:
                close()
            }
        }
    }
}

/// Where the services are (#161). A Debug build takes `-onlineHost`, or the Settings page's field once it has been
/// set, as `ws://host/service`; otherwise Info.plist's `RegattaServiceURL`, which must be `wss://` and is empty until
/// the server has a home (#167). With none, the app runs as it did before the online session: Game Center's own
/// state, the terms kept on the device.
nonisolated enum OnlineEndpoint {
    static let infoKey = "RegattaServiceURL"

    static func serviceURL(launchOptions: LaunchOptions, defaults: UserDefaults, info: [String: Any]) -> URL? {
        #if DEBUG
        if let host = launchOptions.onlineHost ?? defaults.string(forKey: RaceServer.addressDefaultsKey), !host.isEmpty {
            return URL(string: "ws://\(host)/service")
        }
        #endif
        guard let text = info[infoKey] as? String, let url = URL(string: text), url.scheme == "wss", url.host != nil else { return nil }
        return url
    }

    /// The race endpoint beside the services' (#162): the same scheme, host and port, at `/race`.
    static func raceURL(_ serviceURL: URL) -> URL? {
        guard var parts = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        parts.path = "/race"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}
