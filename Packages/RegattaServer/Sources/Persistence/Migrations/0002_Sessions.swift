extension Migration {
    /// A signed-in player's sessions: the hash of the session token, never the token. #145 finishes the shape.
    static let sessions = Migration(
        version: 2,
        name: "sessions",
        up: [
            """
            CREATE TABLE sessions (
                id uuid PRIMARY KEY,
                player_id text NOT NULL REFERENCES players (game_center_id) ON DELETE CASCADE,
                token_hash bytea NOT NULL UNIQUE,
                created_at timestamptz NOT NULL DEFAULT now(),
                expires_at timestamptz NOT NULL
            )
            """,
            "CREATE INDEX sessions_player_id ON sessions (player_id)",
        ],
        down: ["DROP TABLE sessions"]
    )
}
