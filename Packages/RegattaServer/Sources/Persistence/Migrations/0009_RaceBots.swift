extension Migration {
    /// A closed race's bots (#149, ADR 0009): each seat a bot sailed for itself, the rating it was given (the fleet's
    /// median human rating, give or take 150), the skill and handling it sailed at and the version of the rating map
    /// that turned one into the other. `fill`: the seat was a bot's from fleet lock; `takeover`: its player gave it
    /// up before the gun, at `taken_tick`. Written once in the transaction that closes the race; a cancelled race
    /// has none. A dropped player's covered boat is never here: that seat stays hers. For the shadow ratings (#177);
    /// the only reader on a player's path is "the last race", which leaves out a seat she gave up.
    static let raceBots = Migration(
        version: 9,
        name: "race_bots",
        up: [
            """
            CREATE TABLE race_bots (
                race_id uuid NOT NULL REFERENCES races (id) ON DELETE CASCADE,
                seat integer NOT NULL CHECK (seat >= 0),
                source text NOT NULL CHECK (source IN ('fill', 'takeover')),
                rating integer NOT NULL,
                skill double precision NOT NULL,
                handling double precision NOT NULL,
                map_version integer NOT NULL,
                taken_tick integer,
                PRIMARY KEY (race_id, seat)
            )
            """,
        ],
        down: [
            "DROP TABLE race_bots",
        ]
    )
}
