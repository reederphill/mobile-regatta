import Foundation
import Persistence
import RegattaCore
import RegattaServices
import Synchronization

// Seat liveries on the server (#159, #21). A player's livery is stored per Game Center player, so it follows her
// across devices; until she stores one she wears a starter livery derived from her id. Storing one checks it against
// the catalogue and her designs: free designs are everyone's, an earned design is hers once her completed online races
// reach its threshold (`earnedProgressResultCodes`, G6; a cancelled race counts nothing, #30), and paid designs are
// nobody's until purchases are verified (#399, post-1.0). It locks at fleet lock, since the briefing shows it, until
// the race closes. Bots wear seeded free starters (`BotDressing`), and the briefing resolves equal sail numbers.

/// Where players' liveries are kept: Postgres in production (`PlayerLiveryStore`, migration 0013), memory for a dev
/// server without a database and for tests.
public protocol LiveryStore: Sendable {
    /// The livery the player stored, or nil.
    func livery(of playerID: String) async throws -> Livery?
    /// Stores `livery` as the player's. False when the store doesn't know the player.
    func save(_ livery: Livery, for playerID: String, at time: Date) async throws -> Bool
    /// Forgets the player's livery: she wears her starter again.
    func delete(of playerID: String) async throws
}

extension PlayerLiveryStore: LiveryStore {}

/// Liveries in memory. Lost on restart.
public final class InMemoryLiveryStore: LiveryStore {
    private let liveries = Mutex<[String: Livery]>([:])

    public init() {}

    public func livery(of playerID: String) async throws -> Livery? { liveries.withLock { $0[playerID] } }

    public func save(_ livery: Livery, for playerID: String, at time: Date) async throws -> Bool {
        liveries.withLock { $0[playerID] = livery }
        return true
    }

    public func delete(of playerID: String) async throws { liveries.withLock { $0[playerID] = nil } }
}

/// A boat class's earned designs (#21), by the completed online races each takes, fewest first.
public struct EarnedDesigns: Sendable, Equatable {
    public let milestones: [EarnedMilestone]

    public init(catalogue: LiveryCatalogue?, boatClass: String) {
        milestones = (catalogue?.designs(for: boatClass) ?? []).compactMap { design -> EarnedMilestone? in
            guard case .earned(let races) = design.acquisition else { return nil }
            return EarnedMilestone(design: design.id, completedRaces: races)
        }.enumerated().sorted { ($0.element.completedRaces, $0.offset) < ($1.element.completedRaces, $1.offset) }.map(\.element)
    }

    /// The designs earned at `completedRaces`, and the next one to earn.
    public func progress(completedRaces: Int) -> EarnedProgress {
        EarnedProgress(earned: milestones.filter { $0.completedRaces <= completedRaces }.map(\.design),
                       next: milestones.first { $0.completedRaces > completedRaces })
    }

    /// The designs a player earns with her `completedRaces`-th completed race.
    public func unlocked(at completedRaces: Int) -> [DesignID] {
        milestones.filter { $0.completedRaces == completedRaces }.map(\.design)
    }
}

extension AnalyticsEventName {
    /// The server's event (#28, #159): a player earned a design. Keyed to her.
    public static let earnedUnlock = AnalyticsEventName("earned_unlock")
}

/// The stored liveries behind the profile, the briefing and the lobby (#159).
public struct StoredLiveries: LiveryProfileBackend {
    public let store: any LiveryStore
    public let ratings: any RatingBook
    public let catalogue: LiveryCatalogue?
    public let boatClass: String
    public let earned: EarnedDesigns
    /// Whether the player's livery is locked: from her fleet's lock until its race closes.
    let isLocked: @Sendable (String) async -> Bool
    let now: @Sendable () -> Date

    /// `catalogue`: the bundled one by default.
    public init(store: any LiveryStore, ratings: any RatingBook, catalogue: LiveryCatalogue?? = nil,
                boatClass: String = RaceFiles.defaults.boatClass.ref.id, isLocked: @escaping @Sendable (String) async -> Bool = { _ in false },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.ratings = ratings
        let catalogue = catalogue ?? OnlineBriefing.catalogue
        self.catalogue = catalogue
        self.boatClass = boatClass
        earned = EarnedDesigns(catalogue: catalogue, boatClass: boatClass)
        self.isLocked = isLocked
        self.now = now
    }

    /// Her stored livery, or her starter livery when she has stored none.
    public func livery(of player: AccountPlayer) async throws -> Livery {
        if let stored = try await store.livery(of: player.teamPlayerID) { return stored }
        return try await StarterLiveries(boatClass: boatClass).livery(of: player)
    }

    /// Stores her livery: refused while it is locked, when the catalogue refuses it, and when the design isn't hers.
    /// Storing the one she has changes nothing, locked or not (a resend after a lost reply). A fleet that locks while
    /// the write is in flight may already have read the old one for its briefing, so the write is undone and refused.
    public func save(_ livery: Livery, for player: AccountPlayer) async throws -> Livery {
        let previous = try await store.livery(of: player.teamPlayerID)
        if previous == livery { return livery }
        guard await !isLocked(player.teamPlayerID) else { throw ProfileError.liveryLocked }
        guard let catalogue else { throw LiveryStorageUnavailable() }
        do {
            try catalogue.validate(livery, boatClass: boatClass)
        } catch {
            throw ProfileError.invalidLivery(LiveryProblem(error))
        }
        guard let design = catalogue.design(livery.design), owns(design, completedRaces: try await completedRaces(player.teamPlayerID)) else {
            throw ProfileError.invalidLivery(.notOwned)
        }
        guard try await store.save(livery, for: player.teamPlayerID, at: now()) else { throw LiveryStorageUnavailable() }
        if await isLocked(player.teamPlayerID) {
            if let previous { _ = try await store.save(previous, for: player.teamPlayerID, at: now()) } else { try await store.delete(of: player.teamPlayerID) }
            throw ProfileError.liveryLocked
        }
        return livery
    }

    /// The livery she races in, read at fleet lock for the briefing: her stored one, raced as `raceable` makes it; nil
    /// when she has stored none, or it can't be read (the briefing gives her starter). When her completed races can't be
    /// read, a design stored is taken as hers: it was hers when she stored it.
    public func raceLivery(of player: AccountPlayer) async -> Livery? {
        let stored: Livery?
        do {
            stored = try await store.livery(of: player.teamPlayerID)
        } catch {
            Self.log("can't read \(player.teamPlayerID)'s livery for the briefing, she races her starter: \(error)")
            return nil
        }
        guard let stored, let catalogue else { return nil }
        let races: Int?
        do {
            races = try await completedRaces(player.teamPlayerID)
        } catch {
            Self.log("can't read \(player.teamPlayerID)'s completed races for the briefing, her stored design is taken as hers: \(error)")
            races = nil
        }
        return Self.raceable(stored, catalogue: catalogue, boatClass: boatClass) { design in races.map { owns(design, completedRaces: $0) } ?? true }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: liveries: \(message)\n".utf8))
    }

    /// Her lobby chip (#152): the deck and sail colours of the livery the profile shows.
    public func chip(of player: AccountPlayer) async -> LiveryChip {
        guard let livery = try? await livery(of: player), let design = catalogue?.design(livery.design) else {
            return await LobbyHub.starterChip(player)
        }
        let fallback = await LobbyHub.starterChip(player)
        return LiveryChip(deck: livery.colour(.deck, in: design) ?? fallback.deck, sail: livery.colour(.sail, in: design) ?? fallback.sail)
    }

    /// Free designs are everyone's; an earned design is hers at its threshold; paid designs are nobody's until
    /// purchases are verified (#399).
    func owns(_ design: LiveryDesign, completedRaces: Int) -> Bool {
        switch design.acquisition {
        case .free: true
        case .earned(let races): completedRaces >= races
        case .paid: false
        }
    }

    private func completedRaces(_ playerID: String) async throws -> Int {
        try await ratings.standing(of: playerID)?.completedRaces ?? 0
    }

    /// `livery` as it may be raced (#21): as it is, when it is valid for `boatClass` and its design is `owned`;
    /// otherwise the same colours on a free starter design of the class, the first in catalogue order with the same
    /// slots, else the first free one, each slot keeping her colour where the swatch may fill it and taking the first
    /// swatch that may otherwise. Never an earned or paid design. Her sail number stays (held to the range).
    public static func raceable(_ livery: Livery, catalogue: LiveryCatalogue, boatClass: String,
                                owned: (LiveryDesign) -> Bool) -> Livery {
        if (try? catalogue.validate(livery, boatClass: boatClass)) != nil, let design = catalogue.design(livery.design), owned(design) {
            return livery
        }
        let free = catalogue.designs(for: boatClass).filter { $0.acquisition.isFree }
        let original = catalogue.design(livery.design)
        guard let design = free.first(where: { $0.slots == original?.slots }) ?? free.first else { return livery }
        let colours = design.slots.map { slot -> SwatchID in
            if let original, let colour = livery.colour(slot, in: original), catalogue.swatch(colour)?.slots.contains(slot) == true {
                return colour
            }
            return catalogue.swatches.first { $0.slots.contains(slot) }?.id ?? SwatchID("white")
        }
        let number = min(max(livery.sailNumber, Livery.sailNumbers.lowerBound), Livery.sailNumbers.upperBound)
        return Livery(design: design.id, colours: colours, sailNumber: number)
    }
}

/// Tells telemetry (#156) when a close earns a player a design (#159, #28): her completed races are read after the
/// close, and a design whose threshold they now equal was earned by it (a close adds at most one). Two closes of hers
/// counted at once could skip a threshold or tell it twice; under the shipped codes they can't, as a player who leaves
/// a race to queue for another retires from it (RET counts nothing, G6).
public struct EarnedUnlocks: Sendable {
    public let ratings: any RatingBook
    public let earned: EarnedDesigns
    public let analytics: AnalyticsIngest?

    public init(ratings: any RatingBook, earned: EarnedDesigns, analytics: AnalyticsIngest?) {
        self.ratings = ratings
        self.earned = earned
        self.analytics = analytics
    }

    /// `players` each completed the race that just closed.
    public func completed(_ players: [String]) async {
        guard let analytics else { return }
        for player in players {
            guard let races = try? await ratings.standing(of: player)?.completedRaces else { continue }
            for design in earned.unlocked(at: races) {
                do {
                    try await analytics.record(.earnedUnlock, about: player,
                                               properties: ["design": .string(design.rawValue), "completed_races": .int(races)])
                } catch {
                    AnalyticsIngest.log("can't record an earned unlock: \(error)")
                }
            }
        }
    }
}

/// A value set once, after what reads it is made (the liveries' lock reads the matchmaker made after them).
final class LateBound<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    init() {}

    var value: Value? { stored.withLock { $0 } }
    func set(_ value: Value) { stored.withLock { $0 = value } }
}
