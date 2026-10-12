extension Migration {
    /// Analytics (#156, #28). `analytics_events`: the raw events, kept 90 days from receipt. A device's event carries
    /// its install id and sequence (unique together: a resend is recorded once) and never a player; a server event
    /// carries the player it is about (the Game Center teamPlayerID, gone with her) or none. `day` (days since the
    /// epoch, UTC) and `segment` are fixed at ingest; `rolled_up` marks a row already counted in the aggregates.
    /// `analytics_daily` and `analytics_daily_properties`: what is kept after the purge, per day, source, event name
    /// and segment: how many events and distinct actors (installs or players), and per property its count, and for a
    /// number its sum, sum of squares, least and greatest. No install id or player id is kept in them.
    static let analytics = Migration(
        version: 12,
        name: "analytics",
        up: [
            """
            CREATE TABLE analytics_events (
                id bigserial PRIMARY KEY,
                source text NOT NULL CHECK (source IN ('device', 'server')),
                install_id text,
                sequence bigint,
                player_id text REFERENCES players (team_player_id) ON DELETE CASCADE,
                name text NOT NULL,
                day integer NOT NULL,
                segment text NOT NULL,
                occurred_at timestamptz NOT NULL,
                received_at timestamptz NOT NULL,
                properties jsonb NOT NULL,
                rolled_up boolean NOT NULL DEFAULT false,
                UNIQUE (install_id, sequence),
                CHECK ((source = 'device') = (install_id IS NOT NULL AND sequence IS NOT NULL AND player_id IS NULL))
            )
            """,
            "CREATE INDEX analytics_events_pending ON analytics_events (id) WHERE NOT rolled_up",
            "CREATE INDEX analytics_events_received ON analytics_events (received_at)",
            "CREATE INDEX analytics_events_actor_day ON analytics_events (day, name, segment) WHERE rolled_up",
            "CREATE INDEX analytics_events_player ON analytics_events (player_id) WHERE player_id IS NOT NULL",
            """
            CREATE TABLE analytics_daily (
                day integer NOT NULL,
                source text NOT NULL,
                name text NOT NULL,
                segment text NOT NULL,
                events bigint NOT NULL,
                actors bigint NOT NULL,
                PRIMARY KEY (day, source, name, segment)
            )
            """,
            """
            CREATE TABLE analytics_daily_properties (
                day integer NOT NULL,
                source text NOT NULL,
                name text NOT NULL,
                segment text NOT NULL,
                key text NOT NULL,
                kind text NOT NULL CHECK (kind IN ('number', 'category')),
                value text NOT NULL,
                count bigint NOT NULL,
                sum double precision,
                sum_squares double precision,
                min double precision,
                max double precision,
                PRIMARY KEY (day, source, name, segment, key, kind, value)
            )
            """,
        ],
        down: [
            "DROP TABLE analytics_daily_properties",
            "DROP TABLE analytics_daily",
            "DROP TABLE analytics_events",
        ]
    )
}
