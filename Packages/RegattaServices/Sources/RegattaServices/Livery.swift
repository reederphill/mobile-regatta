import RegattaCore

// The lobby's livery chip (#21). The livery itself, its designs and the safe palette are RegattaCore's (#118):
// `Livery`, `DesignID`, `SwatchID`, `LiveryCatalogue`.

/// The round chip beside each lobby line (#21): the deck colour with a sail-colour ring. The same for free and
/// paid players.
public struct LiveryChip: Equatable, Sendable {
    public var deck: SwatchID
    public var sail: SwatchID

    public init(deck: SwatchID, sail: SwatchID) {
        self.deck = deck
        self.sail = sail
    }
}
