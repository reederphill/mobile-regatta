extension Migration {
    /// Players, keyed by their Game Center player id (#4, #145).
    static let players = Migration(
        version: 1,
        name: "players",
        up: [
            """
            CREATE TABLE players (
                game_center_id text PRIMARY KEY CHECK (game_center_id <> ''),
                display_name text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now(),
                last_seen_at timestamptz NOT NULL DEFAULT now()
            )
            """,
        ],
        down: ["DROP TABLE players"]
    )
}
