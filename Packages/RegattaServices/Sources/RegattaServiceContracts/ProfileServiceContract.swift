import RegattaServices

/// What `ProfileService` promises (#21, #25, #26).
public struct ProfileServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        case signedOut
        /// Signed in, no completed online race yet.
        case newPlayer
        /// Signed in with completed races and at least one win and one earned design.
        case established
        /// Under a temporary online racing suspension.
        case suspended
        /// Under a permanent racing ban.
        case banned
        /// Between fleet lock and the close.
        case liveryLocked
    }

    public let name = "ProfileService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any ProfileService) async throws {
        let signedOut = try await makeService(.signedOut)
        try await requireThrows(ProfileError.notSignedIn, "profile() while signed out") { try await signedOut.profile() }

        let new = try await makeService(.newPlayer)
        let fresh = try await new.profile()
        try await require(fresh.rating.isProvisional, "a new player's rating isn't provisional: \(fresh.rating)")
        try await require(fresh.completedRaces == 0 && fresh.wins == 0, "a new player has \(fresh.completedRaces) races, \(fresh.wins) wins")
        try await require(fresh.progress.earned.isEmpty, "a new player has earned \(fresh.progress.earned)")
        try await require((fresh.progress.next?.completedRaces ?? 0) > 0, "a new player has no design to earn next: \(fresh.progress)")
        try await require(fresh.suspension == nil, "a new player is suspended")
        try await requireValid(fresh.livery, "a new player's livery")
        try await requireThrows(ProfileError.notSignedIn, "saveLivery() while signed out") { try await signedOut.saveLivery(fresh.livery) }
        try await savingLivery(new, fresh)

        let established = try await makeService(.established).profile()
        try await require(established.completedRaces > 0 && established.wins > 0, "an established player has \(established.completedRaces) races, \(established.wins) wins")
        try await require(established.wins <= established.completedRaces, "\(established.wins) wins in \(established.completedRaces) races")
        try await require(!established.progress.earned.isEmpty, "an established player has earned nothing")
        if let next = established.progress.next {
            try await require(next.completedRaces > established.completedRaces, "the next design (\(next.completedRaces) races) is already reached at \(established.completedRaces)")
            try await require(!established.progress.earned.contains(next.design), "the next design is already earned")
        }
        try await requireValid(established.livery, "an established player's livery")

        let suspended = try await makeService(.suspended).profile()
        try await require(suspended.suspension.map { !$0.isPermanent } == true, "a suspension shows as \(String(describing: suspended.suspension))")
        let banned = try await makeService(.banned).profile()
        try await require(banned.suspension?.isPermanent == true, "a racing ban shows as \(String(describing: banned.suspension))")

        let locked = try await makeService(.liveryLocked)
        let before = try await locked.profile()
        var change = before.livery
        change.sailNumber = change.sailNumber % Livery.sailNumbers.upperBound + 1
        try await requireThrows(ProfileError.liveryLocked, "saveLivery() after fleet lock") { try await locked.saveLivery(change) }
        try await require(try await locked.profile() == before, "a refused livery changed the profile")
    }

    private func requireValid(_ livery: Livery, _ what: String) async throws {
        try await require(Livery.sailNumbers.contains(livery.sailNumber), "\(what) has sail number \(livery.sailNumber)")
        try await require(Livery.slotCounts.contains(livery.colours.count), "\(what) has \(livery.colours.count) colours")
    }

    /// A valid livery is stored and shown, idempotently; an invalid one stores nothing.
    private func savingLivery(_ service: any ProfileService, _ profile: Profile) async throws {
        func refused(_ problem: LiveryProblem, _ what: String, _ edit: (inout Livery) -> Void) async throws {
            var livery = profile.livery
            edit(&livery)
            try await requireThrows(ProfileError.invalidLivery(problem), what) { try await service.saveLivery(livery) }
            try await require(try await service.profile() == profile, "\(what) changed the profile")
        }
        try await refused(.sailNumber, "sail number 0") { $0.sailNumber = 0 }
        try await refused(.sailNumber, "sail number \(Livery.sailNumbers.upperBound + 1)") { $0.sailNumber = Livery.sailNumbers.upperBound + 1 }
        try await refused(.unknownDesign, "an unknown design") { $0.design = DesignID("contract-no-such-design") }
        try await refused(.slotCount, "four colours") { $0.colours = Array(repeating: $0.colours[0], count: 4) }

        var change = profile.livery
        change.sailNumber = change.sailNumber % Livery.sailNumbers.upperBound + 1
        let stored = try await service.saveLivery(change)
        try await require(stored == change, "saveLivery() stored \(stored), not \(change)")
        try await require(try await service.profile().livery == change, "the profile doesn't show the stored livery")
        try await require(try await service.saveLivery(change) == change, "storing the same livery again changed it")
    }
}
