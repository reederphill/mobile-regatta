import Foundation
import RaceHost
import RegattaDevAPI

/// The races running on this server, by id, so a race token finds its race. Holds nothing of any race's
/// state (#31): each `RaceSession` owns its own, and leaves the registry when it closes.
public actor RaceRegistry {
    private var races: [UUID: RaceSession] = [:]
    private var drivers: [UUID: Task<Void, Never>] = [:]
    public let maxRaces: Int

    public init(maxRaces: Int = 64) { self.maxRaces = maxRaces }

    public var count: Int { races.count }

    public func session(_ id: UUID) -> RaceSession? { races[id] }

    public enum StartError: Error, Equatable, Sendable {
        case full
    }

    /// Starts driving `session` on the wall clock; it leaves the registry when it closes.
    /// `onClose` hears how it closed.
    public func start(_ session: RaceSession, onClose: (@Sendable (RaceOutcome) -> Void)? = nil) throws(StartError) {
        guard races.count < maxRaces else { throw .full }
        races[session.id] = session
        drivers[session.id] = Task { [weak self] in
            let outcome = await session.run()
            await self?.remove(session.id)
            onClose?(outcome)
        }
    }

    private func remove(_ id: UUID) {
        races[id] = nil
        drivers[id] = nil
    }

    /// Closes every race where it stands (server shutdown).
    public func closeAll() async {
        let running = Array(drivers.values)
        for driver in running { driver.cancel() }
        for driver in running { await driver.value }
    }
}
