// Settings → Delete my online data (#28), with a confirmation step. It deletes the profile, rating, chat history
// and reports filed, and the player's Game Center leaderboard entry, and swaps the player's ID in kept race logs
// for a random one so other players' results stay valid. Purchases stay with the Apple ID and can be restored.
// The inactivity job (24 months without a signed-in online session, G8) runs the same deletion.

/// What the server holds for a player online.
public enum OnlineData: Hashable, CaseIterable, Sendable {
    case profile
    case rating
    case livery
    case chatHistory
    case reportsFiled
    case leaderboardEntry
    /// The terms acceptance record (#34): after deletion the player is asked to accept again.
    case termsAcceptance
}

/// Proof that the player saw a plan and confirmed it, opaque here.
public struct DeletionConfirmation: Hashable, Sendable {
    public let token: String

    public init(token: String) { self.token = token }
}

/// What deleting would do now, for the confirmation step.
public struct DeletionPlan: Equatable, Sendable {
    /// What is deleted.
    public var deletes: Set<OnlineData>
    /// Whether the player's ID in kept race logs is swapped for a random one. Always, once she has raced online.
    public var anonymisesRaceLogs: Bool
    /// What confirming this plan hands to `delete(confirmedBy:)`.
    public var confirmation: DeletionConfirmation

    public init(deletes: Set<OnlineData>, anonymisesRaceLogs: Bool, confirmation: DeletionConfirmation) {
        self.deletes = deletes
        self.anonymisesRaceLogs = anonymisesRaceLogs
        self.confirmation = confirmation
    }

    /// What Delete my online data always takes away when the player has it (#28).
    public static let required: Set<OnlineData> = [.profile, .rating, .chatHistory, .reportsFiled, .leaderboardEntry]
}

public enum DataDeletionError: Error, Equatable, Sendable {
    case notSignedIn
    /// The server holds nothing for the player: she never went online, or has already deleted it.
    case nothingToDelete
    /// A confirmation this service didn't issue.
    case invalidConfirmation
}

public protocol DataDeletionService: Sendable {
    /// What deleting would do, and the confirmation to pass on if the player agrees. Throws
    /// `DataDeletionError.nothingToDelete` when there is nothing.
    func plan() async throws -> DeletionPlan
    /// Deletes the player's online data, once she has confirmed `plan()`'s plan. Afterwards `plan()` throws
    /// `nothingToDelete`, and so does a second `delete`.
    func delete(confirmedBy confirmation: DeletionConfirmation) async throws
}
