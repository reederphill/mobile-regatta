/// What a `ScriptedProfileService` plays.
public struct ProfileScenario: Sendable {
    /// Nil when signed out.
    public var profile: Profile?
    /// Each design the player may store, with its number of colour slots.
    public var designs: [DesignID: Int]
    /// The paid designs among them the player doesn't own.
    public var unowned: Set<DesignID>
    /// The safe palette.
    public var palette: Set<Swatch>
    /// Whether the player is between fleet lock and the close, when the livery is locked.
    public var isLiveryLocked: Bool

    public init(
        profile: Profile?, designs: [DesignID: Int] = [:], unowned: Set<DesignID> = [], palette: Set<Swatch> = [],
        isLiveryLocked: Bool = false
    ) {
        self.profile = profile
        self.designs = designs
        self.unowned = unowned
        self.palette = palette
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
        guard Livery.sailNumbers.contains(livery.sailNumber) else { throw ProfileError.invalidLivery(.sailNumber) }
        guard let slots = scenario.designs[livery.design] else { throw ProfileError.invalidLivery(.unknownDesign) }
        guard livery.colours.count == slots else { throw ProfileError.invalidLivery(.slotCount) }
        guard livery.colours.allSatisfy(scenario.palette.contains) else { throw ProfileError.invalidLivery(.colour) }
        guard !scenario.unowned.contains(livery.design) else { throw ProfileError.invalidLivery(.notOwned) }
        stored?.livery = livery
        return livery
    }
}
