import RegattaCore

// The player's online profile (#25, #21, #26): rating and badge, races and wins, any racing suspension, progress to
// the next earned design, and the livery the server stores so it follows the player across devices.

/// An online racing suspension (#26), shown with its end time. Practice races are always allowed, and racing
/// penalties never touch chat.
public struct RacingSuspension: Equatable, Sendable {
    /// When it ends, seconds since the epoch; nil for a permanent racing ban.
    public var until: Int64?

    public init(until: Int64?) { self.until = until }

    public var isPermanent: Bool { until == nil }
}

/// A design earned by completing online races (#21): for example at 10, 50 and 200.
public struct EarnedMilestone: Equatable, Sendable {
    public var design: DesignID
    /// Completed races it takes.
    public var completedRaces: Int

    public init(design: DesignID, completedRaces: Int) {
        self.design = design
        self.completedRaces = completedRaces
    }
}

/// Where the player is on the earned designs: "32 / 50 races" (#25).
public struct EarnedProgress: Equatable, Sendable {
    /// The designs earned so far, in milestone order.
    public var earned: [DesignID]
    /// The next design to earn, nil once every one is earned.
    public var next: EarnedMilestone?

    public init(earned: [DesignID], next: EarnedMilestone?) {
        self.earned = earned
        self.next = next
    }
}

public struct Profile: Equatable, Sendable {
    public var gamePlayerID: GamePlayerID
    public var nickname: String
    /// With its provisional badge. A new player starts at 1500, provisional.
    public var rating: Rating
    /// Completed online races: finished, by distance, DSQ or OCS; never RET or a cancelled race (G6).
    public var completedRaces: Int
    public var wins: Int
    /// An active racing suspension, nil with none.
    public var suspension: RacingSuspension?
    public var progress: EarnedProgress
    /// The stored livery. A new player's is a random free starter design in random palette colours with a
    /// random sail number.
    public var livery: Livery

    public init(
        gamePlayerID: GamePlayerID, nickname: String, rating: Rating, completedRaces: Int, wins: Int,
        suspension: RacingSuspension?, progress: EarnedProgress, livery: Livery
    ) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
        self.rating = rating
        self.completedRaces = completedRaces
        self.wins = wins
        self.suspension = suspension
        self.progress = progress
        self.livery = livery
    }
}

/// What's wrong with a livery the player tried to store.
public enum LiveryProblem: Hashable, Sendable {
    /// Outside `Livery.sailNumbers`.
    case sailNumber
    /// Not the design's number of colour slots.
    case slotCount
    /// A colour not in the safe palette, or not allowed in its slot.
    case colour
    /// No such design for the boat class.
    case unknownDesign
    /// A paid design the player doesn't own: it can be tried on, not raced (#21).
    case notOwned
}

extension LiveryProblem {
    /// The problem `LiveryCatalogue.validate` found, as the profile reports it.
    public init(_ error: LiveryError) {
        switch error {
        case .sailNumber: self = .sailNumber
        case .unknownDesign, .wrongBoatClass: self = .unknownDesign
        case .slotCount: self = .slotCount
        case .unknownSwatch, .swatchNotAllowed: self = .colour
        }
    }
}

public enum ProfileError: Error, Equatable, Sendable {
    /// Game Center has no player: the profile shows only a sign-in prompt (#25).
    case notSignedIn
    case invalidLivery(LiveryProblem)
    /// The livery locks at fleet lock, since the briefing has shown it, until the race closes (#21).
    case liveryLocked
}

public protocol ProfileService: Sendable {
    /// The signed-in player's profile. Throws `ProfileError.notSignedIn` when signed out.
    func profile() async throws -> Profile
    /// Stores the livery for the player and returns it as stored; the profile then shows it. An invalid livery
    /// throws `ProfileError.invalidLivery` and stores nothing. Storing the same livery again changes nothing.
    func saveLivery(_ livery: Livery) async throws -> Livery
}
