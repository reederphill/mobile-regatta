extension Migration {
    /// Fair-play flags (#155, #26): what the nightly scan over race logs found suspicious about a player (a high rule-call
    /// rate, protests from many players, inputs identical across races, drops just before the close), waiting in the
    /// admin queue like a report. A flag is only ever looked at: an admin decides it, and any penalty is hers to give
    /// separately. `race_ids` are the races it was found in. Like the moderation tables it doesn't reference `players`,
    /// and like the race logs it is read from it is kept a year (#28): the retention prune deletes older rows.
    static let fairPlayFlags = Migration(
        version: 17,
        name: "fair_play_flags",
        up: [
            """
            CREATE TABLE fair_play_flags (
                id bigserial PRIMARY KEY,
                kind text NOT NULL CHECK (kind IN ('rule_calls', 'protests', 'identical_inputs', 'late_drops')),
                player_id text NOT NULL,
                value double precision NOT NULL,
                threshold double precision NOT NULL,
                race_ids text[] NOT NULL,
                detail text NOT NULL,
                created_at timestamptz NOT NULL,
                due_at timestamptz NOT NULL,
                decision text CHECK (decision IN ('dismissed', 'upheld')),
                decided_at timestamptz,
                decided_by text,
                CHECK ((decision IS NULL) = (decided_at IS NULL) AND (decision IS NULL) = (decided_by IS NULL)),
                CHECK (decided_by IS NULL OR decided_by <> '')
            )
            """,
            "CREATE INDEX fair_play_flags_queue ON fair_play_flags (due_at, id) WHERE decision IS NULL",
            "CREATE INDEX fair_play_flags_player ON fair_play_flags (player_id, kind, created_at)",
        ],
        down: [
            "DROP TABLE fair_play_flags",
        ]
    )
}
