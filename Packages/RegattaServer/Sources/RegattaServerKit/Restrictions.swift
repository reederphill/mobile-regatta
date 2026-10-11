import Foundation
import Persistence
import RegattaServices
import Synchronization

// What keeps a signed-in player out of the queue (#26, #147): an online racing suspension (#153 sets it), a failed App
// Attest (a flag until #158), and the cooldown three briefing leaves in an hour cost. The gate's refusals (not signed
// in, multiplayer restricted, terms) come first, at the service endpoint (#145); these after them, in that order.

/// The queue's restrictions, stored (#147): Postgres in production (`PlayerRestrictionStore`), memory for a dev server
/// and tests. The matchmaker reads only this; #153 and #158 call its setters.
public protocol RestrictionStore: Sendable {
    func restrictions(of playerID: String) async throws -> PlayerRestrictions
    /// The restrictions of each of `playerIDs` in one read (#469); `.none` for a player with none stored.
    func restrictions(of playerIDs: [String]) async throws -> [String: PlayerRestrictions]
    /// Her briefing leaves at or after `since`, oldest first; older ones are pruned.
    func briefingLeaves(of playerID: String, since: Date) async throws -> [Date]
    func recordBriefingLeave(_ playerID: String, race: UUID?, at time: Date) async throws
    func clearBriefingLeaves(of playerID: String) async throws
    func setCooldown(_ playerID: String, until: Date?) async throws
    /// Sets or lifts (nil) her online racing suspension (#153).
    func setSuspension(_ playerID: String, _ suspension: StoredSuspension?) async throws
    /// Sets or clears her failed-attestation flag (#158).
    func setAttestationFailed(_ playerID: String, _ failed: Bool) async throws
}

extension PlayerRestrictionStore: RestrictionStore {}

/// The restrictions in memory: a dev server without a database, and tests. Lost on restart.
public final class InMemoryRestrictionStore: RestrictionStore {
    private struct State {
        var restrictions: [String: PlayerRestrictions] = [:]
        var leaves: [String: [Date]] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func restrictions(of playerID: String) async throws -> PlayerRestrictions {
        state.withLock { $0.restrictions[playerID] ?? .none }
    }

    public func restrictions(of playerIDs: [String]) async throws -> [String: PlayerRestrictions] {
        state.withLock { state in
            Dictionary(playerIDs.map { ($0, state.restrictions[$0] ?? .none) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func briefingLeaves(of playerID: String, since: Date) async throws -> [Date] {
        state.withLock { state in
            let kept = (state.leaves[playerID] ?? []).filter { $0 >= since }.sorted()
            state.leaves[playerID] = kept.isEmpty ? nil : kept
            return kept
        }
    }

    public func recordBriefingLeave(_ playerID: String, race: UUID?, at time: Date) async throws {
        state.withLock { $0.leaves[playerID, default: []].append(time) }
    }

    public func clearBriefingLeaves(of playerID: String) async throws { state.withLock { $0.leaves[playerID] = nil } }

    public func setCooldown(_ playerID: String, until: Date?) async throws {
        state.withLock { $0.restrictions[playerID, default: .none].cooldownUntil = until }
    }

    public func setSuspension(_ playerID: String, _ suspension: StoredSuspension?) async throws {
        state.withLock { $0.restrictions[playerID, default: .none].suspension = suspension }
    }

    public func setAttestationFailed(_ playerID: String, _ failed: Bool) async throws {
        state.withLock { $0.restrictions[playerID, default: .none].attestationFailed = failed }
    }
}

extension PlayerRestrictions {
    /// Why she can't queue at `time`, if anything stops her: suspended, then attestation failed, then the cooldown
    /// (Q4). Reason data only; the client words it (#25, Q7).
    public func refusal(at time: Date) -> QueueRefusal? {
        if let suspension, suspension.applies(at: time) {
            return .suspended(until: suspension.until.map { Int64($0.timeIntervalSince1970.rounded(.down)) })
        }
        if attestationFailed { return .attestationFailed }
        if let cooldownUntil, cooldownUntil > time {
            return .cooldown(secondsRemaining: Int(cooldownUntil.timeIntervalSince(time).rounded(.up)))
        }
        return nil
    }
}

/// The queue couldn't read a player's restrictions when she asked to join (#469): she isn't queued. Failing closed: a
/// suspended player mustn't race because the store didn't answer. Not a `QueueError` (the wire has no word for it): her
/// request fails as any the server can't serve does, and she may ask again.
public struct RestrictionsUnreadable: Error, Equatable, Sendable {
    public init() {}
}

/// `withDeadline`'s work took longer than its limit.
struct DeadlineExceeded: Error, Equatable {}

/// `work`'s result, or `DeadlineExceeded` once `limit` has passed. The caller goes on at the deadline whether or not
/// the work notices that it was cancelled (a store call stuck in a dead connection); its late result is dropped.
func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withCheckedThrowingContinuation { continuation in
        race.start(continuation)
        let timer = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            race.finish(.failure(DeadlineExceeded()))
        }
        race.worker(Task {
            let result: Result<T, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            timer.cancel()
            race.finish(result)
        })
    }
}

/// The first result wins; the worker is cancelled when it wasn't the worker's.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var worker: Task<Void, Never>?
        var finished = false
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<T, any Error>) { state.withLock { $0.continuation = continuation } }

    func worker(_ task: Task<Void, Never>) {
        let late = state.withLock { state -> Bool in
            state.worker = task
            return state.finished
        }
        if late { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, worker) = state.withLock { state -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?) in
            defer {
                state.continuation = nil
                state.finished = true
            }
            return (state.continuation, state.worker)
        }
        guard let continuation else { return }
        continuation.resume(with: result)
        worker?.cancel()
    }
}

/// The briefing-leave rule (#26, owner Q1, Q2): this many leaves within `window` cost a cooldown of `cooldown`.
public struct BriefingLeaveRule: Sendable, Equatable {
    public var leaves = 3
    public var window: TimeInterval = 60 * 60
    public var cooldown: TimeInterval = 5 * 60

    public init() {}
}

/// Counts briefing leaves (#26, #147): a human who leaves after her fleet locked and before the gun. The `leaves`th
/// within the rolling `window` starts a cooldown until that leave + `cooldown`, and the count starts again from zero
/// (owner Q2). A leave while cooling down lengthens nothing and isn't counted. One player's leaves are counted one after
/// the other (`inFlight`: the actor alone doesn't do that, it lets a second leave in while the first waits on the
/// store), so two of hers at once can't both miss the third, nor one be counted into a cooldown the other just started.
public actor BriefingLeaveTracker {
    public nonisolated let rule: BriefingLeaveRule
    private let store: any RestrictionStore
    private let now: @Sendable () -> Date
    /// Store failures, for the log and tests.
    public private(set) var failures: [String] = []
    /// Each player's leave being counted now: her next waits for it (#469).
    private var inFlight: [String: Task<Date?, Never>] = [:]

    public init(store: any RestrictionStore, rule: BriefingLeaveRule = BriefingLeaveRule(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.rule = rule
        self.now = now
    }

    /// The player left a race's briefing now. Returns the cooldown's end if this leave started one.
    @discardableResult
    public func recordLeave(_ playerID: String, race: UUID?) async -> Date? {
        let time = now()
        let earlier = inFlight[playerID]
        let counting = Task {
            _ = await earlier?.value
            return await self.count(playerID, race: race, at: time)
        }
        inFlight[playerID] = counting
        let until = await counting.value
        if inFlight[playerID] == counting { inFlight[playerID] = nil }
        return until
    }

    private func count(_ playerID: String, race: UUID?, at time: Date) async -> Date? {
        do {
            if let until = try await store.restrictions(of: playerID).cooldownUntil, until > time { return nil }
            try await store.recordBriefingLeave(playerID, race: race, at: time)
            let recent = try await store.briefingLeaves(of: playerID, since: time - rule.window)
            guard recent.count >= rule.leaves else { return nil }
            let until = time + rule.cooldown
            try await store.setCooldown(playerID, until: until)
            try await store.clearBriefingLeaves(of: playerID)
            return until
        } catch {
            failures.append("briefing leave \(playerID): \(error)")
            FileHandle.standardError.write(Data("RegattaServer: can't record a briefing leave: \(error)\n".utf8))
            return nil
        }
    }
}
