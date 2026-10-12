extension Migration {
    /// The admin tool's audit (#154, #34): one row per action an admin took through it (a report decided, a penalty
    /// given or lifted, a nickname overridden), who took it and when, and whom it was about. Like the moderation tables
    /// it doesn't reference `players` and is kept a year (#28): the retention prune deletes older rows.
    static let adminActions = Migration(
        version: 16,
        name: "admin_actions",
        up: [
            """
            CREATE TABLE admin_actions (
                id bigserial PRIMARY KEY,
                actor_id text NOT NULL CHECK (actor_id <> ''),
                action text NOT NULL CHECK (action <> ''),
                player_id text,
                report_id bigint,
                penalty_id bigint,
                detail text NOT NULL DEFAULT '',
                at timestamptz NOT NULL
            )
            """,
            "CREATE INDEX admin_actions_at ON admin_actions (at, id)",
            "CREATE INDEX admin_actions_player ON admin_actions (player_id, at) WHERE player_id IS NOT NULL",
        ],
        down: [
            "DROP TABLE admin_actions",
        ]
    )
}
