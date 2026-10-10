extension Migration {
    /// Queue restrictions (#147, ADR 0009). Each briefing leave (a post-lock, pre-gun leave) is a row, pruned past the
    /// rolling window when read; a player's cooldown end, online racing suspension (#153 writes it) and failed App
    /// Attest flag (#158 writes it) are columns on `players`. They survive a restart and a new session, and go with
    /// the player (G8).
    static let restrictions = Migration(
        version: 8,
        name: "restrictions",
        up: [
            """
            CREATE TABLE briefing_leaves (
                player_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                left_at timestamptz NOT NULL,
                race_id uuid
            )
            """,
            "CREATE INDEX briefing_leaves_player_left ON briefing_leaves (player_id, left_at)",
            "ALTER TABLE players ADD COLUMN cooldown_until timestamptz",
            "ALTER TABLE players ADD COLUMN racing_suspended_until timestamptz",
            "ALTER TABLE players ADD COLUMN racing_suspended_permanent boolean NOT NULL DEFAULT false",
            "ALTER TABLE players ADD COLUMN attestation_failed boolean NOT NULL DEFAULT false",
        ],
        down: [
            "ALTER TABLE players DROP COLUMN attestation_failed",
            "ALTER TABLE players DROP COLUMN racing_suspended_permanent",
            "ALTER TABLE players DROP COLUMN racing_suspended_until",
            "ALTER TABLE players DROP COLUMN cooldown_until",
            "DROP TABLE briefing_leaves",
        ]
    )
}
