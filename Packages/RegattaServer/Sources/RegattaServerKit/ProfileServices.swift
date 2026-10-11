import Foundation
import Persistence
import Ratings
import RegattaCore
import RegattaServices

// The profile as one signed-in player reads it (#151, #25): her rating with its provisional badge, completed races,
// wins and any racing suspension, from the rating store and the restriction store. Her stored livery, the livery lock
// and the earned designs are #159's: they come through two seams, which until then give a starter livery and no
// progress.

/// The profile's livery half (#159): the stored livery, and storing one (validation, ownership and the lock from
/// fleet lock to the close are the backend's). Throws `ProfileError` for what the player did wrong.
public protocol LiveryProfileBackend: Sendable {
    func livery(of player: AccountPlayer) async throws -> Livery
    func save(_ livery: Livery, for player: AccountPlayer) async throws -> Livery
}

/// The earned designs at a number of completed races (#159, #21).
public typealias EarnedProgressSource = @Sendable (_ player: AccountPlayer, _ completedRaces: Int) async -> EarnedProgress

/// Nothing stores liveries yet (#159).
public struct LiveryStorageUnavailable: Error, Equatable, Sendable {
    public init() {}
}

/// Until #159: every player's livery is the starter livery the briefing shows for her (stable per player), and
/// nothing can be stored. `save` fails as any request the server can't serve does (no answer on the wire).
public struct StarterLiveries: LiveryProfileBackend {
    public var boatClass: String

    public init(boatClass: String = RaceFiles.defaults.boatClass.ref.id) { self.boatClass = boatClass }

    public func livery(of player: AccountPlayer) async throws -> Livery {
        OnlineBriefing.catalogue?.newPlayerLivery(boatClass: boatClass, seed: OnlineBriefing.stableSeed(player.teamPlayerID))
            ?? Livery(design: DesignID("plain"), colours: [], sailNumber: 1)
    }

    public func save(_ livery: Livery, for player: AccountPlayer) async throws -> Livery { throw LiveryStorageUnavailable() }
}

/// The profile for one connection's player; nil: nobody is signed in.
public struct ServerProfileService: ProfileService {
    public let player: AccountPlayer?
    public let ratings: any RatingBook
    public let restrictions: any RestrictionStore
    public let liveries: any LiveryProfileBackend
    public let progress: EarnedProgressSource
    public let config: RatingConfig
    public let now: @Sendable () -> Date

    public init(player: AccountPlayer?, ratings: any RatingBook, restrictions: any RestrictionStore,
                liveries: any LiveryProfileBackend = StarterLiveries(),
                progress: @escaping EarnedProgressSource = { _, _ in EarnedProgress(earned: [], next: nil) },
                config: RatingConfig = RatingConfig(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.player = player
        self.ratings = ratings
        self.restrictions = restrictions
        self.liveries = liveries
        self.progress = progress
        self.config = config
        self.now = now
    }

    /// One read of the rating store (name, rating, counts) and one of her restrictions. A player no race has rated
    /// shows 1500 with the provisional badge. A win is any closed online race she finished first, bots or not; the
    /// rating only ever moves against humans. A suspension shows while it applies.
    public func profile() async throws -> Profile {
        guard let player else { throw ProfileError.notSignedIn }
        let standing = try await ratings.standing(of: player.teamPlayerID) ?? PlayerStanding()
        let rating = standing.rating ?? PlayerRating(config)
        let suspension = try await restrictions.restrictions(of: player.teamPlayerID).suspension.flatMap { stored -> RacingSuspension? in
            guard stored.applies(at: now()) else { return nil }
            return RacingSuspension(until: stored.until.map { Int64($0.timeIntervalSince1970.rounded(.down)) })
        }
        return Profile(gamePlayerID: GamePlayerID(player.gamePlayerID), nickname: standing.displayName ?? player.alias,
                       rating: Rating(value: rating.displayed, isProvisional: rating.isProvisional),
                       completedRaces: standing.completedRaces, wins: standing.wins, suspension: suspension,
                       progress: await progress(player, standing.completedRaces), livery: try await liveries.livery(of: player))
    }

    public func saveLivery(_ livery: Livery) async throws -> Livery {
        guard let player else { throw ProfileError.notSignedIn }
        return try await liveries.save(livery, for: player)
    }
}
