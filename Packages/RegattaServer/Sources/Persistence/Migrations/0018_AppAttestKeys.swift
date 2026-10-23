extension Migration {
    /// App Attest keys (#158, ADR 0014): each attested key's public key, its last assertion counter, the environment
    /// its AAGUID named and Apple's receipt (kept, not checked). A key is the install's, not the player's: there is no
    /// player column, so Delete my online data (#160) has nothing here to erase. Keys unused for 730 days are purged by
    /// the retention job. `counter` only rises: an assertion's `UPDATE … WHERE counter < $new` is the replay check.
    static let appAttestKeys = Migration(
        version: 18,
        name: "app_attest_keys",
        up: [
            """
            CREATE TABLE app_attest_keys (
                key_id bytea PRIMARY KEY CHECK (length(key_id) = 32),
                public_key bytea NOT NULL,
                counter bigint NOT NULL CHECK (counter >= 0 AND counter <= 4294967295),
                environment text NOT NULL CHECK (environment IN ('development', 'production')),
                receipt bytea,
                created_at timestamptz NOT NULL,
                last_used_at timestamptz NOT NULL
            )
            """,
            "CREATE INDEX app_attest_keys_last_used ON app_attest_keys (last_used_at)",
        ],
        down: [
            "DROP TABLE app_attest_keys",
        ]
    )
}
