/// What a `ScriptedDataDeletionService` plays.
public struct DataDeletionScenario: Sendable {
    public var isSignedIn: Bool
    /// What the server holds for the player; empty for nothing.
    public var held: Set<OnlineData>
    /// Whether the player has raced online, so race logs name her.
    public var hasRaced: Bool

    public init(isSignedIn: Bool = true, held: Set<OnlineData>, hasRaced: Bool) {
        self.isSignedIn = isSignedIn
        self.held = held
        self.hasRaced = hasRaced
    }
}

/// A `DataDeletionService` that deletes in memory.
public actor ScriptedDataDeletionService: DataDeletionService {
    private let isSignedIn: Bool
    private var held: Set<OnlineData>
    private var hasRaced: Bool
    private var issued = 0

    public init(_ scenario: DataDeletionScenario) {
        isSignedIn = scenario.isSignedIn
        held = scenario.held
        hasRaced = scenario.hasRaced
    }

    public func plan() throws -> DeletionPlan {
        guard isSignedIn else { throw DataDeletionError.notSignedIn }
        guard !held.isEmpty || hasRaced else { throw DataDeletionError.nothingToDelete }
        issued += 1
        return DeletionPlan(deletes: held, anonymisesRaceLogs: hasRaced, confirmation: DeletionConfirmation(token: "delete-\(issued)"))
    }

    public func delete(confirmedBy confirmation: DeletionConfirmation) throws {
        guard isSignedIn else { throw DataDeletionError.notSignedIn }
        guard !held.isEmpty || hasRaced else { throw DataDeletionError.nothingToDelete }
        guard let number = Int(confirmation.token.dropFirst("delete-".count)), confirmation.token.hasPrefix("delete-"),
              (1...issued).contains(number) else { throw DataDeletionError.invalidConfirmation }
        held = []
        hasRaced = false
    }
}
