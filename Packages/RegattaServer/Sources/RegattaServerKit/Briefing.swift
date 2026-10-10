import Crypto
import Foundation
import RegattaCore
import RegattaProtocol
import RegattaServices

// The 15 s briefing's data (#147, #130), built at fleet lock and sent with each human's hand-off: the public setup, the
// tide state, the fleet with its liveries and ratings, her seat and the server's timings. Never the wind seed (ADR 0001).

/// A player's stored livery (#21), nil if she has none: the profile store's, once the server has one.
public typealias LiverySource = @Sendable (AccountPlayer) async -> Livery?

enum OnlineBriefing {
    /// Until ratings exist (#151), every human's.
    static let provisionalRating = 1500
    static let catalogue: LiveryCatalogue? = try? LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1).content

    /// One payload per human, in seat order. `stored` is each human's own livery, if she has one; the rest get a starter
    /// livery (stable per player), the bots a drawn one (from the race seed). Sail numbers are the fleet's (#21: a shared
    /// number shows another for this race).
    static func payloads(_ fleet: LockedFleet, stored: [Livery?], settings: QueueSettings) -> [BriefingPayload] {
        let setup = fleet.setup
        let boatClass = setup.boatClass.id
        var liveries = setup.seats.indices.map { seat -> Livery in
            if seat < fleet.humans.count {
                if let own = stored.indices.contains(seat) ? stored[seat] : nil { return own }
                return catalogue?.newPlayerLivery(boatClass: boatClass, seed: stableSeed(fleet.humans[seat].teamPlayerID)) ?? fallback(seat)
            }
            return catalogue?.botLivery(boatClass: boatClass, seed: setup.raceSeed.value &+ UInt64(seat)) ?? fallback(seat)
        }
        for (seat, number) in LiveryCatalogue.raceSailNumbers(liveries.map(\.sailNumber)).enumerated() { liveries[seat].sailNumber = number }
        let names = fleet.humans.map(\.alias)
        let seats = setup.seats.indices.map { seat in
            BriefingSeat(name: LockedFleet.seatName(seat, humans: names), isBot: setup.seats[seat] == .bot, livery: liveries[seat],
                         rating: setup.seats[seat] == .bot ? nil : provisionalRating)
        }
        return fleet.humans.indices.map { seat in
            BriefingPayload(setup: setup, tide: .none, fleet: seats, yourSeat: seat,
                            briefingSeconds: settings.briefingTicks / Race.tickRate,
                            gunInSeconds: setup.startSequenceTicks / Race.tickRate)
        }
    }

    /// A seed from the player's id that every process agrees on (Swift's `Hasher` is seeded per process).
    static func stableSeed(_ id: String) -> UInt64 {
        SHA256.hash(data: Data(id.utf8)).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Only if the bundled catalogue had no free design for the class: a plain livery.
    private static func fallback(_ seat: Int) -> Livery {
        Livery(design: DesignID("plain"), colours: [], sailNumber: seat + 1)
    }
}
