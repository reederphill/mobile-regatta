import RegattaBots
import RegattaCore

/// Each seat's livery for one race (#21, #119), as the results draw it: your own in your seat, a seeded free starter
/// design in every other, and sail numbers made unique for the race (`LiveryCatalogue.raceSailNumbers`).
///
/// Presentation only: liveries never reach the simulation (`Boat.colorIndex` is the sim's), and they stay out of
/// `FleetRoster`, which bot code reads. The same setup gives the same fleet everywhere.
///
/// An online race wears its briefing's fleet (#163): the server's liveries, locked at fleet lock, which the app keeps
/// with the race's id (`RaceFleet`), since the race start doesn't carry them. Without them (a race whose briefing this
/// device never had, a Debug instant race) it draws the other players as bots are drawn, from their seat's seed, and
/// your own as `yours`. Practice races and briefings wear the livery My boat stores (`AppModel.myLivery`, #136);
/// render fixtures keep `yours`.
struct FleetLiveries: Equatable {
    /// The fixed livery render fixtures, UI tests' first launch and online races draw as yours, so they draw the same
    /// boat every launch; My boat stores your own (#136). The services fakes' livery: the plain skiff, sky-blue deck,
    /// white sail, 207.
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

    /// An online race's fleet (#163): `briefing`'s liveries seat for seat when it has one for every seat `setup`
    /// seats, else the seeded fleet with you in `mySeat`.
    init(briefing: [Livery]?, setup: RaceSetup, mySeat: Int) {
        if let briefing, briefing.count == setup.seats.count {
            self.init(liveries: briefing)
        } else {
            self.init(setup: setup, mySeat: mySeat)
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
