extension Migration {
    /// Race results (#148, ADR 0009). A closed race records its digest, the simulation version and the server's
    /// toolchain (`ServerConfig.serverBuild`) beside its log; its results (rows, roster, served turns) and its incident
    /// index as canonical JSON bytes, written once in the transaction that closes it. A cancelled race has none. Each
    /// race's players and their seats, for "the last race" (#24: the newest closed race a player sat in); they go with
    /// the player (G8).
    static let raceResults = Migration(
        version: 7,
        name: "race_results",
        up: [
            "ALTER TABLE races ADD COLUMN digest bigint",
            "ALTER TABLE races ADD COLUMN sim_version text",
            "ALTER TABLE races ADD COLUMN toolchain text",
            """
            CREATE TABLE race_players (
                race_id uuid NOT NULL REFERENCES races (id) ON DELETE CASCADE,
                player_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                seat integer NOT NULL CHECK (seat >= 0),
                PRIMARY KEY (race_id, seat),
                UNIQUE (race_id, player_id)
            )
            """,
            // lastRace scans a player's races.
            "CREATE INDEX race_players_player ON race_players (player_id)",
            """
            CREATE TABLE race_results (
                race_id uuid PRIMARY KEY REFERENCES races (id) ON DELETE CASCADE,
                results bytea NOT NULL,
                incidents bytea NOT NULL,
                rated boolean NOT NULL,
                stored_at timestamptz NOT NULL DEFAULT now()
            )
            """,
        ],
        down: [
            "DROP TABLE race_results",
            "DROP TABLE race_players",
            "ALTER TABLE races DROP COLUMN toolchain",
            "ALTER TABLE races DROP COLUMN sim_version",
            "ALTER TABLE races DROP COLUMN digest",
        ]
    )
}
