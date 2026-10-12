extension Migration {
    /// Moderation (#153, #17, #26, #34). `moderation_reports`: what players reported (a lobby line, a player for her chat
    /// or her nickname, a human's racing by seat), each with what the admin decided and who decided it. A reported line
    /// is snapshotted into its report: the lobby prunes its lines at 30 days (#28), reports are kept a year.
    /// `moderation_penalties`: chat mutes and bans, racing warnings, suspensions, bans and rating resets, and nickname
    /// overrides. A penalty other than the automatic mute names the admin who gave it: a racing penalty is always
    /// human-reviewed. Neither table references `players`: penalties and reports against a player outlive Delete my
    /// online data for their #28 retention, and still apply if the same Game Center player returns (#160).
    static let moderation = Migration(
        version: 14,
        name: "moderation",
        up: [
            """
            CREATE TABLE moderation_reports (
                id bigserial PRIMARY KEY,
                kind text NOT NULL CHECK (kind IN ('message', 'player', 'race')),
                reporter_id text NOT NULL,
                subject_id text NOT NULL,
                subject_nickname text NOT NULL,
                message_id bigint,
                message_body text,
                message_posted_at timestamptz,
                race_id text,
                seat integer,
                reason text CHECK (reason IN ('unsporting_conduct', 'suspected_cheating')),
                created_at timestamptz NOT NULL,
                due_at timestamptz NOT NULL,
                decision text CHECK (decision IN ('dismissed', 'upheld')),
                decided_at timestamptz,
                decided_by text,
                CHECK (reporter_id <> subject_id),
                CHECK ((kind = 'message') = (message_id IS NOT NULL AND message_body IS NOT NULL)),
                CHECK ((kind = 'race') = (race_id IS NOT NULL AND seat IS NOT NULL AND reason IS NOT NULL)),
                CHECK ((decision IS NULL) = (decided_at IS NULL) AND (decision IS NULL) = (decided_by IS NULL)),
                CHECK (decided_by IS NULL OR decided_by <> '')
            )
            """,
            "CREATE INDEX moderation_reports_queue ON moderation_reports (due_at, id) WHERE decision IS NULL",
            "CREATE INDEX moderation_reports_subject ON moderation_reports (subject_id, created_at)",
            "CREATE INDEX moderation_reports_reporter ON moderation_reports (reporter_id)",
            """
            CREATE TABLE moderation_penalties (
                id bigserial PRIMARY KEY,
                player_id text NOT NULL,
                kind text NOT NULL CHECK (kind IN ('chat_mute', 'chat_ban', 'racing_warning', 'racing_suspension', 'racing_ban',
                    'rating_reset', 'nickname_override')),
                automatic boolean NOT NULL,
                actor_id text,
                report_id bigint REFERENCES moderation_reports (id) ON DELETE SET NULL,
                starts_at timestamptz NOT NULL,
                ends_at timestamptz,
                lifted_at timestamptz,
                lifted_by text,
                CHECK (automatic = (actor_id IS NULL)),
                CHECK (actor_id IS NULL OR actor_id <> ''),
                CHECK (NOT automatic OR kind = 'chat_mute'),
                CHECK ((ends_at IS NOT NULL) = (kind IN ('chat_mute', 'racing_suspension'))),
                CHECK (ends_at IS NULL OR ends_at > starts_at),
                CHECK ((lifted_at IS NULL) = (lifted_by IS NULL))
            )
            """,
            "CREATE INDEX moderation_penalties_player ON moderation_penalties (player_id)",
        ],
        down: [
            "DROP TABLE moderation_penalties",
            "DROP TABLE moderation_reports",
        ]
    )
}
