import RegattaServices

/// What `DataDeletionService` promises (#28).
public struct DataDeletionServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// Signed in, has raced online and holds every kind of online data.
        case hasOnlineData
        /// Signed in, and the server holds nothing for the player.
        case nothingHeld
        case signedOut
    }

    public let name = "DataDeletionService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any DataDeletionService) async throws {
        let service = try await makeService(.hasOnlineData)
        let plan = try await service.plan()
        try await require(plan.deletes.isSuperset(of: DeletionPlan.required), "the plan keeps \(DeletionPlan.required.subtracting(plan.deletes))")
        try await require(plan.anonymisesRaceLogs, "the plan leaves the player's ID in the race logs")

        try await requireThrows(DataDeletionError.invalidConfirmation, "delete() with a confirmation never issued") {
            try await service.delete(confirmedBy: DeletionConfirmation(token: "contract-forged"))
        }
        // Confirms the latest plan: a service may void a confirmation once it issues a newer one.
        let latest = try await service.plan()
        try await require(latest.deletes == plan.deletes, "a refused deletion deleted something")

        try await service.delete(confirmedBy: latest.confirmation)
        try await requireThrows(DataDeletionError.nothingToDelete, "plan() after deleting") { try await service.plan() }
        try await requireThrows(DataDeletionError.nothingToDelete, "delete() twice") {
            try await service.delete(confirmedBy: latest.confirmation)
        }

        let empty = try await makeService(.nothingHeld)
        try await requireThrows(DataDeletionError.nothingToDelete, "plan() with nothing held") { try await empty.plan() }

        let signedOut = try await makeService(.signedOut)
        try await requireThrows(DataDeletionError.notSignedIn, "plan() while signed out") { try await signedOut.plan() }
        try await requireThrows(DataDeletionError.notSignedIn, "delete() while signed out") {
            try await signedOut.delete(confirmedBy: plan.confirmation)
        }
    }
}
