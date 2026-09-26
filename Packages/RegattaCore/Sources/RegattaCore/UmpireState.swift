/// What the umpire remembers through a race: held by the authoritative race only (`Race.Mode`), never
/// by a prediction, and never sent to clients.
///
/// Empty for now. The rules tickets move their memory here: rule 18 records, incident memory, the
/// last-point-of-certainty timers, the escape buffer and protest matching.
public struct UmpireState: Sendable, Equatable {
    public init() {}
}
