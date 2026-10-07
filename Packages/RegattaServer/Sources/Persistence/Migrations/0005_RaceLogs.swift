extension Migration {
    /// Each race's log, as the bytes the race host wrote (ADR 0009: bytea, in the same database as its registry
    /// row). Written once.
    static let raceLogs = Migration(
        version: 5,
        name: "race_logs",
        up: [
            """
            CREATE TABLE race_logs (
                race_id uuid PRIMARY KEY REFERENCES races (id),
                log bytea NOT NULL,
                stored_at timestamptz NOT NULL DEFAULT now()
            )
            """,
        ],
        down: ["DROP TABLE race_logs"]
    )
}
