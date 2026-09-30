// A boat's livery (#21): a design, its colour slots filled from the safe palette, and a sail number. The editor
// only picks a design, fills its slots and sets a number: no uploads, no drawing, no text. Shared by the profile
// (the stored livery), the store (paid designs) and the lobby (the chip beside each line).

/// A livery design: a pattern plus a sail graphic, authored per boat class.
public struct DesignID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A swatch of the safe palette (#21, #29), by its id. Every swatch passes the contrast check against the water.
public struct Swatch: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A livery as the device sends it with each queue join and the server stores per Game Center player (#21).
public struct Livery: Equatable, Sendable {
    /// The boat class the design is authored for (a class data file's id).
    public var boatClass: String
    public var design: DesignID
    /// The design's colour slots, filled in slot order.
    public var colours: [Swatch]
    public var sailNumber: Int

    /// The sail numbers a player may pick: numbers only, no letters or country codes.
    public static let sailNumbers = 1...9999
    /// How many colour slots a design has.
    public static let slotCounts = 2...3

    public init(boatClass: String, design: DesignID, colours: [Swatch], sailNumber: Int) {
        self.boatClass = boatClass
        self.design = design
        self.colours = colours
        self.sailNumber = sailNumber
    }
}

/// The round chip beside each lobby line (#21): the deck colour with a sail-colour ring. The same for free and
/// paid players.
public struct LiveryChip: Equatable, Sendable {
    public var deck: Swatch
    public var sail: Swatch

    public init(deck: Swatch, sail: Swatch) {
        self.deck = deck
        self.sail = sail
    }
}
