import RegattaServices

/// What `QueueService` promises (#16, #26, #34).
public struct QueueServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// Free to join. Once joined the queue counts down and ends in fleet lock, without the player leaving.
        case joinable
        /// A queue cooldown is running (#26): the state counts it down to `.idle`.
        case cooldown
        /// An online racing suspension is in force (#26).
        case suspended
        /// Game Center has no player.
        case notSignedIn
        /// The current terms aren't accepted.
        case termsNotAccepted
        /// Game Center's `isMultiplayerGamingRestricted`.
        case multiplayerRestricted
    }

    public let name = "QueueService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any QueueService) async throws {
        try await joinToFleetLock(makeService(.joinable))
        try await leaveIsFree(makeService(.joinable))
        try await cooldownCountsDown(makeService(.cooldown))
        try await refused(makeService(.suspended)) { if case .suspended = $0 { true } else { false } }
        try await refused(makeService(.notSignedIn)) { $0 == .notSignedIn }
        try await refused(makeService(.termsNotAccepted)) { $0 == .termsNotAccepted }
        try await refused(makeService(.multiplayerRestricted)) { $0 == .multiplayerRestricted }
    }

    /// Joining, the countdown and the queued count, lock-imminent, and fleet lock.
    private func joinToFleetLock(_ service: any QueueService) async throws {
        var reader = StreamReader(service.stateUpdates())
        try await require(await reader.next() == .idle, "the first state of a joinable queue isn't .idle")
        try await service.join()
        try await requireThrows(QueueError.alreadyQueued, "join() while queued") { try await service.join() }

        let (states, locked) = await reader.read { $0 == .fleetLocked }
        try await require(locked, "the queue ended without reaching fleet lock; it read \(states)")
        var queued: [QueuedStatus] = []
        for state in states.dropLast() {
            guard case .queued(let status) = state else { try fail("\(state) between joining and fleet lock, not .queued") }
            queued.append(status)
        }
        try await require(!queued.isEmpty, "fleet lock came with no queued state before it")
        for status in queued {
            try await require(status.queuedPlayers >= 1, "\(status.queuedPlayers) players queued, and the player is one")
            try await require(status.secondsToLock >= 0, "a countdown of \(status.secondsToLock) s")
        }
        try await require(queued[queued.count - 1].isLockImminent, "fleet lock came without lock-imminent before it: \(queued[queued.count - 1])")

        // Once locked, the queue is done with the player.
        try await requireThrows(QueueError.alreadyQueued, "join() after fleet lock") { try await service.join() }
        try await requireThrows(QueueError.notQueued, "leave() after fleet lock") { try await service.leave() }
    }

    /// Leaving the queue is free, and so is joining again.
    private func leaveIsFree(_ service: any QueueService) async throws {
        var reader = StreamReader(service.stateUpdates())
        try await require(await reader.next() == .idle, "the first state of a joinable queue isn't .idle")
        try await requireThrows(QueueError.notQueued, "leave() before joining") { try await service.leave() }

        try await service.join()
        let (waiting, isQueued) = await reader.read { if case .queued = $0 { true } else { false } }
        try await require(isQueued, "joining never showed as queued; it read \(waiting)")
        try await service.leave()
        let (left, isIdle) = await reader.read { $0 == .idle }
        try await require(isIdle, "leaving never showed as .idle; it read \(left)")
        try await require(!left.contains(.fleetLocked), "leaving ended in fleet lock: \(left)")
        try await requireThrows(QueueError.notQueued, "leave() after leaving") { try await service.leave() }

        try await service.join()
    }

    /// A cooldown shows as a countdown to `.idle`, refuses joining meanwhile, and lets the player join after.
    private func cooldownCountsDown(_ service: any QueueService) async throws {
        var reader = StreamReader(service.stateUpdates())
        guard case .unavailable(.cooldown(let start)) = await reader.next() else { try fail("a queue in cooldown doesn't start in .unavailable(.cooldown)") }
        try await require(start > 0, "a cooldown of \(start) s")
        do {
            try await service.join()
            try fail("join() during a cooldown didn't throw")
        } catch QueueError.refused(.cooldown) {
        }

        let (rest, isIdle) = await reader.read { $0 == .idle }
        try await require(isIdle, "the cooldown never ended; it read \(rest)")
        var previous = start
        for state in rest.dropLast() {
            guard case .unavailable(.cooldown(let seconds)) = state else { try fail("\(state) during a cooldown") }
            try await require(seconds < previous, "the cooldown went from \(previous) s to \(seconds) s")
            previous = seconds
        }
        try await service.join()
    }

    /// A refusal shows as the state, and is why joining throws.
    private func refused(_ service: any QueueService, is expected: (QueueRefusal) -> Bool) async throws {
        var reader = StreamReader(service.stateUpdates())
        guard case .unavailable(let refusal) = await reader.next(), expected(refusal) else {
            try fail("the first state isn't the expected refusal")
        }
        do {
            try await service.join()
            try fail("join() didn't throw, though \(refusal)")
        } catch QueueError.refused(let thrown) {
            try await require(expected(thrown), "join() refused with \(thrown), and the state says \(refusal)")
        }
        try await requireThrows(QueueError.notQueued, "leave() while refused") { try await service.leave() }
    }
}
