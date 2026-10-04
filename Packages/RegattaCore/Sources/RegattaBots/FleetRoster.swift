import RegattaCore

/// Who is in each seat, for display: kept outside the simulation, which only knows seats (#60).
/// A bot always shows as a bot (#19): the app draws the bot glyph beside its sailing name, and the
/// name comes from the bot's seed, never from a player's handle.
public struct FleetRoster: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let seat: Int
        public let isBot: Bool
        /// A bot's sailing name; nil for a player, whose handle comes from their account.
        public let sailingName: String?
        /// A practice rival (#235, `Rivals`): a bot whose skill is set from the player's recent practice results. The
        /// app shows the word "Rival" beside her name; she still shows as a bot. Never online.
        public var isRival = false
    }

    /// Sailing names: seabirds, never offered as handles. Enough for a full fleet of bots.
    public static let sailingNames = [
        "Gannet", "Petrel", "Skua", "Fulmar", "Tern", "Osprey", "Curlew", "Kittiwake",
        "Shearwater", "Puffin", "Cormorant", "Albatross", "Plover", "Heron", "Merlin", "Dunlin",
        "Guillemot", "Razorbill", "Shag", "Sanderling", "Whimbrel", "Godwit", "Avocet", "Oystercatcher",
    ]

    public let entries: [Entry]

    /// A bot for each bot seat of `setup`. Each bot's name is picked by its seed; a name already
    /// taken by a lower seat moves on to the next free one, so names in a fleet never repeat. The bot seats among
    /// `rivals` are practice rivals (#235, `Rivals.seats`); online and server paths never pass any.
    public init(setup: RaceSetup, rivals: Set<Int> = []) {
        let names = FleetRoster.sailingNames
        var taken = Array(repeating: false, count: names.count)
        entries = setup.seats.indices.map { seat in
            guard setup.seats[seat] == .bot else { return Entry(seat: seat, isBot: false, sailingName: nil) }
            var index = Int(botSeed(raceSeed: setup.raceSeed, seat: seat) % UInt64(names.count))
            while taken[index] { index = (index + 1) % names.count }
            taken[index] = true
            return Entry(seat: seat, isBot: true, sailingName: names[index], isRival: rivals.contains(seat))
        }
    }

    public subscript(seat: Int) -> Entry { entries[seat] }

    /// The seats of the practice rivals (#235), empty online.
    public var rivals: Set<Int> { Set(entries.filter(\.isRival).map(\.seat)) }
}
