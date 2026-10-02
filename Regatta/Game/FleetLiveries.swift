import RegattaBots
import RegattaCore

/// Each seat's livery for one race (#21, #119), as the results draw it: your own in your seat, a seeded free starter
/// design in every other, and sail numbers made unique for the race (`LiveryCatalogue.raceSailNumbers`).
///
/// Presentation only: liveries never reach the simulation (`Boat.colorIndex` is the sim's), and they stay out of
/// `FleetRoster`, which bot code reads. The same setup gives the same fleet everywhere.
///
/// Until the wire carries liveries (a follow-up to #119), an online race draws the other players as bots are drawn,
/// from their seat's seed; and until My boat stores yours (#136), yours is `yours`.
struct FleetLiveries: Equatable {
    /// Your livery until My boat stores one (#136): one fixed livery, so practice races and render fixtures draw
    /// the same boat every launch. The services fakes' livery: the plain skiff, sky-blue deck, white sail, 207.
    static let yours = Livery(design: DesignID("skiff-plain"), colours: [SwatchID("sky-blue"), SwatchID("white")],
                              sailNumber: 207)

    /// By seat, sail numbers as the fleet shows them.
    let liveries: [Livery]

    init(liveries: [Livery]) {
        self.liveries = liveries
    }

    /// The fleet `setup` seats, you in `mySeat` wearing `mine`.
    init(setup: RaceSetup, mySeat: Int, mine: Livery = FleetLiveries.yours, catalogue: LiveryCatalogue = .bundled) {
        let boatClass = setup.boatClass.id
        let own = Self.livery(mine, for: boatClass, catalogue: catalogue)
        let chosen = setup.seats.indices.map { seat -> Livery in
            if seat == mySeat, let own { return own }
            return catalogue.botLivery(boatClass: boatClass, seed: botSeed(raceSeed: setup.raceSeed, seat: seat))
                ?? Self.yours
        }
        let numbers = LiveryCatalogue.raceSailNumbers(chosen.map(\.sailNumber))
        liveries = zip(chosen, numbers).map { livery, number in
            var livery = livery
            livery.sailNumber = number
            return livery
        }
    }

    /// Seat `seat`'s livery; `yours` for a seat out of range (a driver with no fleet liveries).
    subscript(seat: Int) -> Livery {
        liveries.indices.contains(seat) ? liveries[seat] : Self.yours
    }

    /// `livery` on a boat of `boatClass`: as it is if it's valid for the class, else the class's free design with the
    /// same pattern and as many slots, wearing the same colours, else nil.
    private static func livery(_ livery: Livery, for boatClass: String, catalogue: LiveryCatalogue) -> Livery? {
        if (try? catalogue.validate(livery, boatClass: boatClass)) != nil { return livery }
        guard let design = catalogue.design(livery.design) else { return nil }
        let twin = catalogue.designs(for: boatClass).first {
            $0.acquisition.isFree && $0.pattern == design.pattern && $0.slots == design.slots
        }
        guard let twin else { return nil }
        let swapped = Livery(design: twin.id, colours: livery.colours, sailNumber: livery.sailNumber)
        return (try? catalogue.validate(swapped, boatClass: boatClass)) != nil ? swapped : nil
    }
}
