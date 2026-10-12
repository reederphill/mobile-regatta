extension Migration {
    /// Seat liveries (#159, #21). `player_liveries`: the livery a player stored, one per player, keyed to her Game
    /// Center teamPlayerID so it follows her across devices; gone with her (G8). A player with none has a starter
    /// livery the server derives from her id, never stored.
    static let liveries = Migration(
        version: 13,
        name: "liveries",
        up: [
            """
            CREATE TABLE player_liveries (
                player_id text PRIMARY KEY REFERENCES players (team_player_id) ON DELETE CASCADE,
                design text NOT NULL,
                colours text[] NOT NULL,
                sail_number integer NOT NULL CHECK (sail_number BETWEEN 1 AND 9999),
                updated_at timestamptz NOT NULL
            )
            """,
        ],
        down: [
            "DROP TABLE player_liveries",
        ]
    )
}
