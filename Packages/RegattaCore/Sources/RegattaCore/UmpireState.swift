/// What the umpire remembers through a race: held by the authoritative race only (`Race.Mode`), never
/// by a prediction, and never sent to clients or carried in a `WorldSnapshot`.
///
/// So far its incident memory (#88): each pair's open incident, one per pair until the boats separate
/// by the rules configuration's `incidents.separation`. The rules tickets move the rest of theirs here:
/// rule 18 records, the escape buffer and protest matching.
public struct UmpireState: Sendable, Equatable {
    /// Each pair's open incident, by id: opened by a contact or a near miss, closed when the pair
    /// separates. Looked up by pair, never iterated (ADR 0002).
    private var openIncidents: [SeatPair: Int] = [:]

    public init() {}

    /// The id of the incident open between `pair`'s boats, if they haven't separated since it opened.
    func openIncident(_ pair: SeatPair) -> Int? { openIncidents[pair] }

    /// Holds incident `id` open for `pair` until they separate.
    mutating func open(_ id: Int, for pair: SeatPair) { openIncidents[pair] = id }

    /// Forgets `pair`'s open incident: they have separated.
    mutating func close(_ pair: SeatPair) { openIncidents[pair] = nil }

    /// Keeps only the open incidents that are still their pair's latest in `incidents`: after an import
    /// (`Race.importSnapshot`) replaces the race's incidents, one the new index doesn't end on can't be open.
    mutating func keepOpenIncidents(in incidents: IncidentIndex) {
        var kept: [SeatPair: Int] = [:]
        for pair in incidents.pairs {
            if let id = openIncidents[pair], incidents.latest(between: pair.low, and: pair.high)?.id == id {
                kept[pair] = id
            }
        }
        openIncidents = kept
    }
}
