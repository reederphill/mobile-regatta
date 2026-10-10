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

/// The briefing-leave rule (#26, owner Q1, Q2): this many leaves within `window` cost a cooldown of `cooldown`.
public struct BriefingLeaveRule: Sendable, Equatable {
    public var leaves = 3
    public var window: TimeInterval = 60 * 60
    public var cooldown: TimeInterval = 5 * 60

    public init() {}
}

/// Counts briefing leaves (#26, #147): a human who leaves after her fleet locked and before the gun. The `leaves`th
/// within the rolling `window` starts a cooldown until that leave + `cooldown`, and the count starts again from zero
/// (owner Q2). A leave while cooling down lengthens nothing and isn't counted. Serialised per tracker, so two leaves
/// of hers can't both miss the third.
public actor BriefingLeaveTracker {
    public nonisolated let rule: BriefingLeaveRule
    private let store: any RestrictionStore
    private let now: @Sendable () -> Date
    /// Store failures, for the log and tests.
    public private(set) var failures: [String] = []

    public init(store: any RestrictionStore, rule: BriefingLeaveRule = BriefingLeaveRule(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.rule = rule
        self.now = now
    }

    /// The player left a race's briefing now. Returns the cooldown's end if this leave started one.
    @discardableResult
    public func recordLeave(_ playerID: String, race: UUID?) async -> Date? {
        let time = now()
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
