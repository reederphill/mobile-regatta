import RegattaCore

/// Thin shim over the per-seat input API (#59) until the practice driver owns input and
/// `myBoatIndex` (#61). A practice race puts you in seat 0.
extension Race {
    var playerIndex: Int { 0 }
    var player: Boat { boats[playerIndex] }

    /// Rudder from the touch controls, −1…1, held from the next tick. Any real input cancels an auto-tack.
    func setPlayerRudder(_ value: Double) {
        apply(BoatInput(rudder: value), seat: playerIndex, atTick: tick + 1)
    }

    /// Mirror the heading across the wind: a tack when upwind, a gybe when downwind.
    func playerTackOrGybe() {
        tap(.tackGybe, seat: playerIndex, atTick: tick + 1)
    }
}

extension Boat {
    /// The only human seat in a practice race is yours.
    var displayName: String { isPlayer ? "You" : name }
}

/// A practice race as the app starts it: the setup, the wind seed the device holds (ADR 0001),
/// and which seats the built-in bot brain sails.
struct RaceConfig {
    var setup: RaceSetup
    var windSeed: WindSeed
    /// A bot sails your boat too (`-demo`).
    var autopilotPlayer = false

    var botBrainSeats: [Int] {
        setup.seats.indices.filter { setup.seats[$0] == .bot || (autopilotPlayer && $0 == 0) }
    }
}
