extension Migration {
    /// The lobby (#152, ADR 0013). `lobby_messages`: every line that was sent, players' and the server's own (a blocked
    /// post is never stored). A player's line carries her as she showed when she posted it (nickname, rating, chip): the
    /// lobby never re-reads an author. A winner's line names its player in `subject_id`, so her deletion takes it too.
    /// A line taken down (#153) keeps its row until the retention prune (#28, #160), marked removed. `lobby_blocks`:
    /// who hides whom, by player. Both go with the player (G8).
    static let lobby = Migration(
        version: 11,
        name: "lobby",
        up: [
            """
            CREATE TABLE lobby_messages (
                id bigserial PRIMARY KEY,
                kind text NOT NULL CHECK (kind IN ('text', 'quick', 'gun', 'winner')),
                author_id text REFERENCES players (team_player_id) ON DELETE CASCADE,
                subject_id text REFERENCES players (team_player_id) ON DELETE CASCADE,
                body text,
                quick text,
                venue text,
                boats integer,
                humans integer,
                winner_name text,
                author_game_player_id text,
                author_nickname text,
                author_rating integer,
                author_provisional boolean,
                author_chip_deck text,
                author_chip_sail text,
                created_at timestamptz NOT NULL,
                removed_at timestamptz,
                removed_reason text
            )
            """,
            "CREATE INDEX lobby_messages_created ON lobby_messages (created_at)",
            "CREATE INDEX lobby_messages_author ON lobby_messages (author_id)",
            """
            CREATE TABLE lobby_blocks (
                blocker_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                blocked_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                created_at timestamptz NOT NULL,
                PRIMARY KEY (blocker_id, blocked_id)
            )
            """,
        ],
        down: [
            "DROP TABLE lobby_blocks",
            "DROP TABLE lobby_messages",
        ]
    )
}
