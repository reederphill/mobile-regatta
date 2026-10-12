extension Migration {
    /// Delete my online data (#160, #28). `data_deletions`: one row per player deleted, at her request or after 730 days
    /// without an online session (G8), and nothing that names her: the deletion's audit. Until the leaderboard has
    /// blocked her scores it holds her `game_player_id` (Game Center's only handle on them); once blocked, that is
    /// cleared and the count kept.
    ///
    /// Blocks of a player are the blockers' (#17): `lobby_blocks.blocked_id` stops referencing `players`, so deleting her
    /// row no longer deletes them, and a player who deletes her data and comes back is still hidden from whoever
    /// blocked her. The blocks she made still go with her.
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
            "CREATE INDEX data_deletions_pending ON data_deletions (block_failures, id) WHERE game_player_id IS NOT NULL",
            "ALTER TABLE lobby_blocks DROP CONSTRAINT lobby_blocks_blocked_id_fkey",
        ],
        down: [
            "DELETE FROM lobby_blocks b WHERE NOT EXISTS (SELECT 1 FROM players p WHERE p.team_player_id = b.blocked_id)",
            """
            ALTER TABLE lobby_blocks ADD CONSTRAINT lobby_blocks_blocked_id_fkey
                FOREIGN KEY (blocked_id) REFERENCES players (team_player_id) ON DELETE CASCADE
            """,
            "DROP TABLE data_deletions",
        ]
    )
}
