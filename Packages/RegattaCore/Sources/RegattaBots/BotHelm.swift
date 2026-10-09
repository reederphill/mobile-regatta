import RegattaCore

/// A bot's own hand on the helm (#434, ADR 0011), for a class whose autohelm doesn't hold a centred rudder
/// (`BoatClass.AutohelmTuning.holdsWhenCentred` false). Her brain sails by centring the rudder on her aim and leaving
/// the autohelm to hold it (`BotBrain`, ADR 0007); with no autohelm to hold it, a centred rudder would sail her
/// straight on through every shift. So the helm keeps the angle the class's autohelm would have taken on the tick she
/// centred (`Autohelm.engage`: her angle, or the groove within a snap of it) and turns it into a held rudder each
/// decision with the autohelm's own rudder law (`Autohelm.rudder`): she sails the same track either way, close to it
/// rather than bit for bit, since she steers ten times a second where the autohelm steers every tick.
///
/// Her brain reads the angle it holds as her autohelm's (`view(_:)`), so it decides exactly as it does with the
/// autohelm on. A rudder her brain holds off centre is hers, and lets the angle go. The tack/gybe tap is still the
/// race's autohelm's: hands off while it sails her, and once it hands her back she holds the groove it sailed her to,
/// as the autohelm on would. For a class whose autohelm holds a centred rudder she does nothing: every input passes.
/// Sees only her seat's view (#98), like the brain.
struct BotHelm: Sendable, Equatable {
    /// What she holds by hand: the autohelm the class's would be, engaged when her brain last centred the rudder; nil
    /// while her brain holds the rudder or she has never centred it.
    private(set) var held: Autohelm?

    /// `view` as her brain should read it: her own autohelm's reading the angle she holds by hand, while the race's
    /// autohelm doesn't have her.
    func view(_ view: SeatView) -> SeatView {
        guard !view.boatClass.steering.autohelm.holdsWhenCentred, view.own.autohelm == nil, let held else { return view }
        return view.holdingOwnHelm(held.reading(tws: view.own.polarWindSpeed, grooveTWS: view.own.grooveWindSpeed,
                                                boatClass: view.boatClass))
    }

    /// The held input she sends for `input`, her brain's decision on `view`, the seat's view as the race shows it, with
    /// the tack/gybe tap if `tapping`: then the rudder stays as her brain left it, centred, for the race's autohelm to
    /// sail the tap (a rudder held off centre would cancel it).
    mutating func input(_ input: BoatInput, _ view: SeatView, tapping: Bool = false) -> BoatInput {
        let boatClass = view.boatClass
        guard !boatClass.steering.autohelm.holdsWhenCentred, !tapping else {
            held = nil
            return input
        }
        // Her brain steers: the rudder is hers, and the angle she held goes.
        guard abs(input.rudderValue) <= Autohelm.deadBand else {
            held = nil
            return input
        }
        let own = view.own
        if let tapping = own.autohelm {
            // The race's autohelm is sailing her tap, or settling her on the new groove: hands off. When it lets go she
            // holds what it held.
            held = Autohelm(target: tapping.target)
            return input
        }
        let angle = own.boomSide.sailingAngle(relativeWind: own.relativeWind)
        let helm = held ?? Autohelm.engage(sailingAngle: angle, tws: own.grooveWindSpeed, boatClass: boatClass).autohelm
        held = helm
        let rudder = helm.rudder(sailingAngle: angle, boomSide: own.boomSide, tws: own.polarWindSpeed,
                                 grooveTWS: own.grooveWindSpeed, boatClass: boatClass)
        return BoatInput(rudder: rudder, ease: input.ease)
    }
}
