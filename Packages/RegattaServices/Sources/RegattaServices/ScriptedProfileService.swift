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

/// A `ProfileService` that keeps the stored livery in memory.
public actor ScriptedProfileService: ProfileService {
    private var stored: Profile?
    private let scenario: ProfileScenario

    public init(_ scenario: ProfileScenario) {
        self.scenario = scenario
        stored = scenario.profile
    }

    public func profile() throws -> Profile {
        guard let stored else { throw ProfileError.notSignedIn }
        return stored
    }

    public func saveLivery(_ livery: Livery) throws -> Livery {
        guard stored != nil else { throw ProfileError.notSignedIn }
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
