extension Migration {
    /// Game Center identity, sessions and the Terms of Use (#145). Players are keyed by the verified teamPlayerID
    /// (the signed field) and carry the gamePlayerID the authenticated client sent, bound 1:1 (unique), and the
    /// last online session time, the retention clock #160 reads (G8). Sessions keep the restrictions Game Center
    /// reported for them (client-asserted until #158's App Attest covers the request) and slide on use. Terms
    /// acceptances record player, version and time; they go with the player (G8).
    static let identity = Migration(
        version: 6,
        name: "identity",
        up: [
            "ALTER TABLE players RENAME COLUMN game_center_id TO team_player_id",
            "ALTER TABLE players RENAME CONSTRAINT players_game_center_id_check TO players_team_player_id_check",
            "ALTER TABLE players ADD COLUMN game_player_id text UNIQUE CHECK (game_player_id <> '')",
            "ALTER TABLE players ADD COLUMN last_session_at timestamptz NOT NULL DEFAULT now()",
            "ALTER TABLE sessions ADD COLUMN underage boolean NOT NULL DEFAULT false",
            "ALTER TABLE sessions ADD COLUMN communication_restricted boolean NOT NULL DEFAULT false",
            "ALTER TABLE sessions ADD COLUMN multiplayer_restricted boolean NOT NULL DEFAULT false",
            """
            CREATE TABLE terms_acceptances (
                player_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                version integer NOT NULL CHECK (version > 0),
                accepted_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (player_id, version)
            )
            """,
        ],
        down: [
            "DROP TABLE terms_acceptances",
            "ALTER TABLE sessions DROP COLUMN multiplayer_restricted",
            "ALTER TABLE sessions DROP COLUMN communication_restricted",
            "ALTER TABLE sessions DROP COLUMN underage",
            "ALTER TABLE players DROP COLUMN last_session_at",
            "ALTER TABLE players DROP COLUMN game_player_id",
            "ALTER TABLE players RENAME CONSTRAINT players_team_player_id_check TO players_game_center_id_check",
            "ALTER TABLE players RENAME COLUMN team_player_id TO game_center_id",
        ]
    )
}
