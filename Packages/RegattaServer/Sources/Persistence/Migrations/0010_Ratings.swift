extension Migration {
    /// Ratings (#151, ADR 0012). `ratings`: a player's Glicko-2 numbers once a rated race has moved them; no row is
    /// a new player (1500 / 350 / 0.06, provisional), and reads never insert one. `established` is the end of the
    /// provisional badge, kept for good. `mirrored_rating` is the rounded rating last sent to the Game Center
    /// leaderboard and `mirror_failures` the failed tries since the rating last changed (`LeaderboardMirror`).
    /// `rating_history`: one row per player per rated race, written in the transaction that closes the race, with the
    /// numbers before and after, her place and how many opponents she was rated against; `reset` rows are an admin's
    /// (no race). Enough for calibration (#157) and the bots' shadow ratings (#177) without the logs.
    /// `player_stats`: completed online races and wins (#25), counted at every close, rated or not.
    /// `race_results.rating_state`: `none` (unrated), `applied`, `skipped` (fewer than 2 participants still had an
    /// account) or `failed` (the close committed without its ratings: an ops query finds these).
    /// Everything of a player's goes with her (G8).
    static let ratings = Migration(
        version: 10,
        name: "ratings",
        up: [
            """
            CREATE TABLE ratings (
                player_id text PRIMARY KEY REFERENCES players (team_player_id) ON DELETE CASCADE,
                rating double precision NOT NULL CHECK (rating >= 100 AND rating <= 4000),
                deviation double precision NOT NULL CHECK (deviation >= 50 AND deviation <= 350),
                volatility double precision NOT NULL CHECK (volatility >= 0.01 AND volatility <= 0.1),
                rated_races integer NOT NULL DEFAULT 0 CHECK (rated_races >= 0),
                established boolean NOT NULL DEFAULT false,
                last_rated_at timestamptz,
                mirrored_rating integer,
                mirror_failures integer NOT NULL DEFAULT 0 CHECK (mirror_failures >= 0),
                updated_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            """
            CREATE TABLE rating_history (
                id bigserial PRIMARY KEY,
                player_id text NOT NULL REFERENCES players (team_player_id) ON DELETE CASCADE,
                race_id uuid REFERENCES races (id) ON DELETE CASCADE,
                kind text NOT NULL CHECK (kind IN ('race', 'reset')),
                at timestamptz NOT NULL,
                before_rating double precision NOT NULL,
                before_deviation double precision NOT NULL,
                before_volatility double precision NOT NULL,
                before_established boolean NOT NULL,
                after_rating double precision NOT NULL,
                after_deviation double precision NOT NULL,
                after_volatility double precision NOT NULL,
                after_established boolean NOT NULL,
                place integer,
                opponents integer,
                note text,
                CHECK ((kind = 'race') = (race_id IS NOT NULL))
            )
            """,
            "CREATE UNIQUE INDEX rating_history_race_player ON rating_history (race_id, player_id) WHERE kind = 'race'",
            "CREATE INDEX rating_history_player_at ON rating_history (player_id, at)",
            """
            CREATE TABLE player_stats (
                player_id text PRIMARY KEY REFERENCES players (team_player_id) ON DELETE CASCADE,
                completed_races integer NOT NULL DEFAULT 0 CHECK (completed_races >= 0),
                wins integer NOT NULL DEFAULT 0 CHECK (wins >= 0),
                updated_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            """
            ALTER TABLE race_results ADD COLUMN rating_state text NOT NULL DEFAULT 'none'
                CHECK (rating_state IN ('none', 'applied', 'skipped', 'failed'))
            """,
        ],
        down: [
            "ALTER TABLE race_results DROP COLUMN rating_state",
            "DROP TABLE player_stats",
            "DROP TABLE rating_history",
            "DROP TABLE ratings",
        ]
    )
}
