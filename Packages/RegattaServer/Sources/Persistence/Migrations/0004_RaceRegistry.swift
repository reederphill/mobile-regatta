extension Migration {
    /// The race registry (#30): each race the server starts, running until it closes or is cancelled, and the data
    /// files it names at race start (#32). A file a race names can't be missing from `data_files`.
    static let raceRegistry = Migration(
        version: 4,
        name: "race_registry",
        up: [
            """
            CREATE TABLE races (
                id uuid PRIMARY KEY,
                state text NOT NULL CHECK (state IN ('running', 'closed', 'cancelled')),
                created_at timestamptz NOT NULL DEFAULT now(),
                ended_at timestamptz,
                CHECK ((state = 'running') = (ended_at IS NULL))
            )
            """,
            "CREATE INDEX races_running ON races (id) WHERE state = 'running'",
            """
            CREATE TABLE race_files (
                race_id uuid NOT NULL REFERENCES races (id) ON DELETE CASCADE,
                file_id text NOT NULL,
                file_version integer NOT NULL,
                PRIMARY KEY (race_id, file_id),
                FOREIGN KEY (file_id, file_version) REFERENCES data_files (id, version)
            )
            """,
        ],
        down: [
            "DROP TABLE race_files",
            "DROP TABLE races",
        ]
    )
}
