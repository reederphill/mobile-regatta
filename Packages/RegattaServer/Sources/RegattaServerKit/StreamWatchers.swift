import Foundation
import Synchronization

/// The streams players hold on a service, by player (#469): the queue's states, a race's results, rating changes.
///
/// A stream is registered before `open` returns and removed the moment it terminates, both synchronously, so the
/// removal can never arrive ahead of the registration and leave a watcher nobody reads (the services hand out their
/// streams from non-isolated calls; registering in a task could lose to the stream being dropped at once).
///
/// A new watcher is unprimed: `send(_:to:)` passes it by until its owner has given it its first words with `prime`, so
/// the first thing a stream says is its owner's considered answer, never a change that happened to come first.
/// `finish` ends every stream of a player, primed or not.
///
/// Thread-safe. No stream is finished while the lock is held (a finish runs the stream's termination handler, which
/// takes the lock).
final class StreamWatchers<Element: Sendable>: Sendable {
    private struct Watcher {
        let continuation: AsyncStream<Element>.Continuation
        var primed = false
        var last: Element?
    }

    private let watchers = Mutex<[String: [UUID: Watcher]]>([:])

    /// A stream for `key`, registered. `onClose` runs after it terminated and was removed (not when `finish` ends it).
    func open(_ key: String, bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy,
              onClose: @escaping @Sendable () -> Void = {}) -> (stream: AsyncStream<Element>, token: UUID) {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let token = UUID()
        watchers.withLock { $0[key, default: [:]][token] = Watcher(continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            guard let self, self.remove(key, token) else { return }
            onClose()
        }
        return (stream, token)
    }

    @discardableResult
    private func remove(_ key: String, _ token: UUID) -> Bool {
        watchers.withLock { all in
            guard all[key]?.removeValue(forKey: token) != nil else { return false }
            if all[key]?.isEmpty == true { all[key] = nil }
            return true
        }
    }

    /// Whether `key` has a stream open, primed or not.
    func isWatched(_ key: String) -> Bool { watchers.withLock { $0[key] != nil } }

    /// Whether `key` has a primed stream open.
    func hasPrimed(_ key: String) -> Bool { watchers.withLock { $0[key]?.values.contains(where: \.primed) ?? false } }

    /// Every key with a stream open.
    var keys: [String] { watchers.withLock { Array($0.keys) } }

    /// The watcher's first words, in order; from here `send(_:to:)` reaches it. False, and nothing sent, if its stream
    /// has gone.
    @discardableResult
    func prime(_ key: String, _ token: UUID, _ first: [Element] = []) -> Bool {
        watchers.withLock { all in
            guard var watcher = all[key]?[token] else { return false }
            for element in first { watcher.continuation.yield(element) }
            watcher.primed = true
            if let last = first.last { watcher.last = last }
            all[key]?[token] = watcher
            return true
        }
    }

    /// To one watcher, primed or not; nothing if its stream has gone.
    func send(_ element: Element, to key: String, _ token: UUID) {
        watchers.withLock { all in
            guard var watcher = all[key]?[token] else { return }
            watcher.continuation.yield(element)
            watcher.last = element
            all[key]?[token] = watcher
        }
    }

    /// To every primed watcher of `key`. Returns how many there were.
    @discardableResult
    func send(_ element: Element, to key: String) -> Int {
        send(element, to: key) { _ in true }
    }

    private func send(_ element: Element, to key: String, where wanted: (Element?) -> Bool) -> Int {
        watchers.withLock { all in
            var sent = 0
            for (token, var watcher) in all[key] ?? [:] where watcher.primed {
                sent += 1
                guard wanted(watcher.last) else { continue }
                watcher.continuation.yield(element)
                watcher.last = element
                all[key]?[token] = watcher
            }
            return sent
        }
    }

    /// Ends every stream of `key`, primed or not, after `last` if given.
    func finish(_ key: String, last: Element? = nil) {
        let ended = watchers.withLock { $0.removeValue(forKey: key) } ?? [:]
        for watcher in ended.values { Self.finish(watcher, last) }
    }

    /// Ends one stream, after `last` if given.
    func finish(_ key: String, _ token: UUID, last: Element? = nil) {
        let ended = watchers.withLock { all -> Watcher? in
            let watcher = all[key]?.removeValue(forKey: token)
            if all[key]?.isEmpty == true { all[key] = nil }
            return watcher
        }
        if let ended { Self.finish(ended, last) }
    }

    /// Ends every stream.
    func finishAll() {
        let ended = watchers.withLock { all in
            defer { all = [:] }
            return all
        }
        for watcher in ended.values.flatMap(\.values) { Self.finish(watcher, nil) }
    }

    private static func finish(_ watcher: Watcher, _ last: Element?) {
        if let last { watcher.continuation.yield(last) }
        watcher.continuation.finish()
    }
}

extension StreamWatchers where Element: Equatable {
    /// To every primed watcher of `key` whose last element differs.
    func sendIfChanged(_ element: Element, to key: String) {
        _ = send(element, to: key) { $0 != element }
    }
}
