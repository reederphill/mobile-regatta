import RegattaCore

/// What a `ScriptedProfileService` plays.
public struct ProfileScenario: Sendable {
    /// Nil when signed out.
    public var profile: Profile?
    /// The designs and safe palette a stored livery is checked against (#118), for boats of `boatClass`.
    public var catalogue: LiveryCatalogue
    public var boatClass: String
    /// The paid designs the player doesn't own.
    public var unowned: Set<DesignID>
    /// Whether the player is between fleet lock and the close, when the livery is locked.
    public var isLiveryLocked: Bool

    public init(profile: Profile?, catalogue: LiveryCatalogue, boatClass: String = "skiff", unowned: Set<DesignID> = [],
                isLiveryLocked: Bool = false) {
        self.profile = profile
        self.catalogue = catalogue
        self.boatClass = boatClass
        self.unowned = unowned
        self.isLiveryLocked = isLiveryLocked
    }
}

/// A `ProfileService` that keeps the stored livery in memory. Given an identity, it follows that identity's Game
/// Center state (#139): signed out, it throws `notSignedIn` whatever the scenario's profile, and once `signIn()` gives
/// a player the scenario's profile is hers, as a real session's read would be after the sign-in.
public actor ScriptedProfileService: ProfileService {
    private var stored: Profile?
    private let scenario: ProfileScenario
    private let identity: (any IdentityService)?

    public init(_ scenario: ProfileScenario, signedInWith identity: (any IdentityService)? = nil) {
        self.scenario = scenario
        self.identity = identity
        stored = scenario.profile
    }

    /// The stored profile while the identity (if any) has a player.
    private func signedInProfile() async throws -> Profile {
        if let identity, await identity.state().player == nil { throw ProfileError.notSignedIn }
        guard let stored else { throw ProfileError.notSignedIn }
        return stored
    }

    public func profile() async throws -> Profile {
        try await signedInProfile()
    }

    public func saveLivery(_ livery: Livery) async throws -> Livery {
        _ = try await signedInProfile()
        guard !scenario.isLiveryLocked else { throw ProfileError.liveryLocked }
        do {
            try scenario.catalogue.validate(livery, boatClass: scenario.boatClass)
        } catch {
            throw ProfileError.invalidLivery(LiveryProblem(error))
        }
        guard !scenario.unowned.contains(livery.design) else { throw ProfileError.invalidLivery(.notOwned) }
        stored?.livery = livery
        return livery
    }
}
