import Foundation
import Synchronization

/// The extra check on free text that passed the word list (#152): a toxicity classifier, somebody else's service.
///
/// It is an extra, never the gate (owner 2026-10-11): when it can't answer (down, slow, refusing, its breaker open),
/// the message goes through on the word list alone. Only a `true` blocks. An implementation is handed the text and
/// nothing else: no player, no ids.
public protocol ToxicityClassifier: Sendable {
    /// Whether the classifier flags `text`. Throws when it can't say.
    func isFlagged(_ text: String) async throws -> Bool
}

/// What the classifier made of a message, as the posting pipeline reads it.
public enum ToxicityScreening: Equatable, Sendable {
    case clean
    case flagged
    /// No answer: the message passes on the word list alone, and the pass is counted.
    case unavailable(Unavailable)

    public enum Unavailable: String, Equatable, Sendable, CaseIterable {
        /// No answer inside the time limit.
        case timeout
        /// The call failed: the network, a status that isn't 200, an answer that can't be read.
        case error
        /// Too many failures in a row: not asked at all until the breaker's probe.
        case breakerOpen
        /// Too many calls in flight.
        case busy
    }
}

/// Stops asking a classifier that keeps failing: `threshold` failures in a row open the breaker for `openSeconds`;
/// after that one call is let through as a probe, and its answer closes the breaker or opens it again. Time is the
/// caller's (seconds on any monotonic clock). A value type: the caller holds the lock.
public struct CircuitBreaker: Sendable, Equatable {
    public var threshold: Int
    public var openSeconds: Double
    private var failures = 0
    private var openUntil: Double?
    private var probing = false

    public init(threshold: Int = 5, openSeconds: Double = 30) {
        self.threshold = max(1, threshold)
        self.openSeconds = openSeconds
    }

    public var isOpen: Bool { openUntil != nil }

    /// Whether a call may go out at `now`. True once, for the probe, when an open breaker's time is up.
    public mutating func allows(at now: Double) -> Bool {
        guard let openUntil else { return true }
        guard now >= openUntil, !probing else { return false }
        probing = true
        return true
    }

    public mutating func succeeded() {
        failures = 0
        openUntil = nil
        probing = false
    }

    public mutating func failed(at now: Double) {
        failures += 1
        if probing || failures >= threshold {
            openUntil = now + openSeconds
            probing = false
        }
    }
}

/// A classifier for tests and dev: flags the texts containing one of its phrases, or fails, or never answers, as told.
/// It keeps what it was asked, so a test can see that only the text went out.
public final class FakeToxicityClassifier: ToxicityClassifier {
    public enum Behaviour: Sendable, Equatable {
        /// Answers: flagged when the text contains one of `flagging` (case-insensitive).
        case answers
        case fails
        /// Never answers: it waits until `release()`.
        case hangs
    }

    public struct Failed: Error, Equatable, Sendable {
        public init() {}
    }

    private struct State {
        var behaviour: Behaviour
        var flagging: [String]
        var asked: [String] = []
        var hanging: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    public init(_ behaviour: Behaviour = .answers, flagging: [String] = []) {
        state = Mutex(State(behaviour: behaviour, flagging: flagging.map { $0.lowercased() }))
    }

    public func set(_ behaviour: Behaviour) { state.withLock { $0.behaviour = behaviour } }

    /// Every text it was asked about, in order.
    public var asked: [String] { state.withLock { $0.asked } }

    /// Lets every hanging call go (each then fails).
    public func release() {
        let hanging = state.withLock { state in
            defer { state.hanging = [] }
            return state.hanging
        }
        for continuation in hanging { continuation.resume() }
    }

    public func isFlagged(_ text: String) async throws -> Bool {
        let (behaviour, flagging) = state.withLock { state in
            state.asked.append(text)
            return (state.behaviour, state.flagging)
        }
        switch behaviour {
        case .answers:
            let lowered = text.lowercased()
            return flagging.contains { lowered.contains($0) }
        case .fails:
            throw Failed()
        case .hangs:
            await withCheckedContinuation { continuation in state.withLock { $0.hanging.append(continuation) } }
            throw Failed()
        }
    }
}
