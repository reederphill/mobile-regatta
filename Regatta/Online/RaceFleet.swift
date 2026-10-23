import Foundation
import RegattaCore
import RegattaServices

/// One online race's seat liveries as its briefing showed them (#163, T1): the server's, locked at fleet lock, by seat,
/// with the fleet's sail numbers. Nothing after the briefing carries them (the race start and the reports have none), so
/// the app keeps them with the race's id, and the race's results and Home's Last race wear them.
struct RaceFleet: Codable, Equatable {
    var raceID: String
    var liveries: [Livery]
    /// Home has kept a practice race since this hand-off (#163, T4): the server naming this race no longer outranks
    /// Home's Last race at the session's open.
    var superseded = false

    init(raceID: RaceID, liveries: [Livery]) {
        self.raceID = raceID.rawValue
        self.liveries = liveries
    }

    private enum CodingKeys: CodingKey { case raceID, liveries, superseded }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raceID = try container.decode(String.self, forKey: .raceID)
        liveries = try container.decode([Livery].self, forKey: .liveries)
        superseded = try container.decodeIfPresent(Bool.self, forKey: .superseded) ?? false
    }

    /// The fleet `briefing` shows for `raceID`.
    init(raceID: RaceID, briefing: BriefingPayload) {
        self.init(raceID: raceID, liveries: briefing.fleet.map(\.livery))
    }

    /// The liveries, if this is `raceID`'s fleet.
    func liveries(of raceID: RaceID) -> [Livery]? { raceID.rawValue == self.raceID ? liveries : nil }
}

/// The last hand-off's race and its fleet (#163), as JSON in the practice defaults, so UI tests, which empty those at
/// launch, start with none. A cold launch or a rejoin of that race wears its liveries again, and the session-open
/// fetch knows this device was handed that race (`AppModel.adoptsLastRace`).
struct LastHandOffStore {
    let defaults: UserDefaults
    static let key = "lastHandOff"

    func load() -> RaceFleet? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RaceFleet.self, from: data)
    }

    func save(_ fleet: RaceFleet) {
        guard let data = try? JSONEncoder().encode(fleet) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
