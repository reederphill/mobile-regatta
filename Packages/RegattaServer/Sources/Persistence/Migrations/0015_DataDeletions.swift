extension Migration {
    /// Delete my online data (#160, #28). `data_deletions`: one row per player deleted, at her request or after 730 days
    /// without an online session (G8), and nothing that names her: the deletion's audit. Until the leaderboard has
    /// blocked her scores it holds her `game_player_id` (Game Center's only handle on them); once blocked, that is
    /// cleared and the count kept.
    static let dataDeletions = Migration(
        version: 15,
        name: "data_deletions",
        up: [
            """
            CREATE TABLE data_deletions (
                id bigserial PRIMARY KEY,
                reason text NOT NULL CHECK (reason IN ('request', 'inactive')),
                deleted_at timestamptz NOT NULL,
                game_player_id text CHECK (game_player_id <> ''),
                scores_blocked integer CHECK (scores_blocked >= 0),
                scores_blocked_at timestamptz,
                block_failures integer NOT NULL DEFAULT 0 CHECK (block_failures >= 0),
                CHECK ((scores_blocked IS NULL) = (scores_blocked_at IS NULL)),
                CHECK (scores_blocked IS NULL OR game_player_id IS NULL)
            )
            """,
            "CREATE INDEX data_deletions_pending ON data_deletions (id) WHERE game_player_id IS NOT NULL",
        ],
        down: [
            "DROP TABLE data_deletions",
        ]
    )
}
