import Foundation
import os
import RegattaClient

/// A race connection over a `URLSessionWebSocketTask` (#68): one binary message per `Frame`, as the
/// server's `/race` endpoint speaks it (ADR 0006 is the server side; the app uses URLSession).
///
/// `RaceClient` polls it from the display loop, so what arrives on URLSession's queue is buffered until
/// `receive()`. It counts as connected until the socket has failed or closed *and* its last frame has been
/// read: the server sends `RaceClosed` and closes straight after, and the client must still see the close.
/// A closed one never opens again; reconnecting is a new transport (`RaceTransport`).
nonisolated final class WebSocketTransport: RaceTransport, @unchecked Sendable {
    private struct State {
        var inbox: [[UInt8]] = []
        var isOpen = true
        var closeReason: String?
    }

    private let task: URLSessionWebSocketTask
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Opens `url` (`ws://host:port/race`) at once; frames sent before the handshake completes wait for it.
    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
        receiveNext()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
    }

    var isConnected: Bool {
        state.withLock { $0.isOpen || !$0.inbox.isEmpty }
    }

    /// Why the connection ended, once it has: the server's close reason or the error.
    var closeReason: String? {
        state.withLock { $0.closeReason }
    }

    func send(_ frame: [UInt8]) {
        guard state.withLock({ $0.isOpen }) else { return }
        task.send(.data(Data(frame))) { [weak self] error in
            if let error { self?.ended(error.localizedDescription) }
        }
    }

    func receive() -> [[UInt8]] {
        state.withLock { state in
            defer { state.inbox.removeAll() }
            return state.inbox
        }
    }

    /// Closes the socket; anything unread can still be read.
    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        ended("closed by the app")
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                state.withLock { $0.inbox.append([UInt8](data)) }
                receiveNext()
            case .success:
                // The protocol is binary only; a text message can't be a frame.
                receiveNext()
            case .failure(let error):
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                ended(reason.flatMap { $0.isEmpty ? nil : $0 } ?? error.localizedDescription)
            }
        }
    }

    private func ended(_ reason: String) {
        state.withLock { state in
            guard state.isOpen else { return }
            state.isOpen = false
            state.closeReason = reason
        }
    }
}
