import Foundation
import PostgresNIO
import RegattaCore

/// Players' stored liveries in Postgres (#159, migration 0013): one per player, replaced whole.
public struct PlayerLiveryStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    /// The livery the player stored, or nil.
    public func livery(of playerID: String) async throws -> Livery? {
        let rows = try await database.client.query("""
            SELECT design, colours, sail_number FROM player_liveries WHERE player_id = \(playerID)
            """, logger: database.logger)
        for try await (design, colours, number) in rows.decode((String, [String], Int32).self) {
            return Livery(design: DesignID(design), colours: colours.map(SwatchID.init), sailNumber: Int(number))
        }
        return nil
    }

    /// Stores `livery` as the player's, replacing what she had. False when the player isn't stored.
    @discardableResult
    public func save(_ livery: Livery, for playerID: String, at time: Date) async throws -> Bool {
        let rows = try await database.client.query("""
            INSERT INTO player_liveries (player_id, design, colours, sail_number, updated_at)
            SELECT team_player_id, \(livery.design.rawValue), \(livery.colours.map(\.rawValue)), \(Int32(livery.sailNumber)), \(time)
            FROM players WHERE team_player_id = \(playerID)
            ON CONFLICT (player_id) DO UPDATE SET design = EXCLUDED.design, colours = EXCLUDED.colours,
                sail_number = EXCLUDED.sail_number, updated_at = EXCLUDED.updated_at
            RETURNING player_id
            """, logger: database.logger)
        for try await _ in rows.decode(String.self) { return true }
        return false
    }

    /// Forgets the player's livery.
    public func delete(of playerID: String) async throws {
        try await database.client.query("DELETE FROM player_liveries WHERE player_id = \(playerID)", logger: database.logger)
    }
}
