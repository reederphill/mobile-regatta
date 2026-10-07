extension Migration {
    /// Every released version of every data file (#32, ADR 0004): one row per id and version, with the content's
    /// hash. Files are immutable, so a row is never updated or deleted: a trigger refuses both, which keeps every
    /// version a race log may name.
    static let dataFiles = Migration(
        version: 3,
        name: "data_files",
        up: [
            """
            CREATE TABLE data_files (
                id text NOT NULL CHECK (id <> ''),
                version integer NOT NULL CHECK (version > 0),
                hash bytea NOT NULL CHECK (length(hash) = 32),
                content bytea NOT NULL,
                stored_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (id, version)
            )
            """,
            """
            CREATE FUNCTION data_files_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                RAISE EXCEPTION 'data files are immutable: % @ % stays as stored', OLD.id, OLD.version;
            END
            $$
            """,
            """
            CREATE TRIGGER data_files_immutable BEFORE UPDATE OR DELETE ON data_files
                FOR EACH ROW EXECUTE FUNCTION data_files_immutable()
            """,
        ],
        down: [
            "DROP TABLE data_files",
            "DROP FUNCTION data_files_immutable()",
        ]
    )
}
