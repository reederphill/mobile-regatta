# Ratings are Glicko-2, a fleet race scored as weighted pairs

A player's rating is Glickman's Glicko-2 as published (rating, deviation, volatility; Illinois iteration for the volatility), with three changes: every game carries a weight, the deviation grows by the time since the player's last rated race, and the results are clamped. One rated race is one update for every participant at once. Built in [#151](https://github.com/reederphill/mobile-regatta/issues/151) on what [#16](https://github.com/reederphill/mobile-regatta/issues/16), [#19](https://github.com/reederphill/mobile-regatta/issues/19) and [#30](https://github.com/reederphill/mobile-regatta/issues/30) settled (rated means at least 2 humans at the gun; bots never move ratings; RET counts; no seasons; everyone starts at 1500). The code is the pure `Ratings` target in `Packages/RegattaServer` (`Glicko2`, `FleetRating`, `RatingConfig`).

## The algorithm

- **Start:** 1500, deviation 350, volatility 0.06. τ = 0.5. Deviation clamped to 50…350, volatility to 0.01…0.1, rating to 100…4000.
- **A race as pairs.** The participants are the humans at the gun. Each plays every other once: a win if her stored place is better, a draw if it is equal (DSQs share a place, OCSs share one, and at a normal close RETs share one), a loss if worse. At an all-gone close each RET has her own place, the latest leaver best, so the order they left in decides. Bots are never participants, whatever their place.
- **Weight.** Every game of a race with m opponents weighs w = m^-0.5 (`RatingConfig.weightExponent`, server config `RATING_WEIGHT_EXPONENT`): v⁻¹ = Σ w·g²·E(1−E) and Δ = v·Σ w·g·(s−E). A duel is w = 1, exactly Glickman's game. The m pairs of one finishing order are not m independent games: beating the boat in 5th and the boat in 6th is mostly one piece of evidence. Unweighted, a first race of 4 new players moves the winner +300 and one of 16 gives each player 15 full games; with 1/√m the winner of 4 moves +229 and of 16 +331, against +162 for a duel. A big fleet is worth a little more than a duel (owner, 2026-10-10), never many times more.
- **One race, one update, at once.** Each participant is updated against the others as they stood before the race.
- **Time.** t = (close time − her last rated race) / 1 day, clamped to 0…365; 1 for her first race. An opponent's deviation, as her rivals see it, is grown to the close time: √(φ² + t·σ²). Her own pre-update deviation is Glickman's φ* = √(φ² + t·σ′²). So t = 1 is exactly the published step, races back to back add no deviation, and time away makes the next results count for more.
- **Provisional.** A player is provisional until a rated race first leaves her deviation at or under 90, then established for good (`ratings.established`): about 16 duels, 12 races of 3 humans, 10 of 4 or 7 of a full fleet against established opponents. Time away grows her deviation again but never brings the badge back (owner, 2026-10-10): about 40 days away would otherwise re-badge a veteran and take her off the leaderboard. Only an admin's reset makes her provisional again.
- **Shown:** the rating rounded to a whole number; a change is the difference of the two rounded numbers. The winner of a race never loses rating (she scores 1 against everyone and is expected to score less).

Worked vectors (`RatingsTests`; from an independent throwaway implementation): Glickman's example 1500/200/0.06 against 1400/30 won, 1550/100 lost, 1700/300 lost gives 1464.05 / 151.52 / 0.05999. Two new players, a duel: 1662.21 and 1337.79, deviation 290.23. Four new players in order: 1728.67, 1576.22, 1423.78, 1271.33, deviation 261.83. Four at 1500/80 placed 1, 2, 3, 3: 1528.90, 1509.63, 1480.73, 1480.73. 1700/60 beats 1500/80: 1705.00 / 60.26 and 1491.35 / 79.17. 1700/60, 1500/80, 1300/100 finishing in reverse: 1676.57, 1500.70, 1362.78. No games, volatility 0.06: deviation 80 becomes 90.21 after 16 days, 60 becomes 89.75 after 41.

## Where it runs

Inside the transaction that closes the race (`RaceResultStore.close`, ADR 0009), after the players' rows are locked in ascending order: a race is closed and rated at once or not at all, and once (only a `running` race closes). The rating step runs in a savepoint. If it fails, the race still closes, `race_results.rating_state` is `failed`, nobody's rating moves and nobody is pushed a rating change; there is no re-rating in 1.0. The Game Center leaderboard mirrors the rounded rating of established players afterwards, outside the transaction (`LeaderboardMirror`).

## Considered options

- **A flat count of rated races for the provisional badge:** rejected. A duel and a 16-boat race say different amounts; the deviation already measures it.
- **Provisional again after time away:** rejected (owner). The deviation still grows, so a returning player's number moves faster, without the badge.
- **Every pair a full game (weight 1):** rejected: a first race of 16 would move a player about 9 times the information of a duel.
- **Every race worth one duel (weight 1/m):** rejected (owner): a big fleet says more than a duel.
- **Rating periods (a nightly batch), as Glickman describes:** rejected. Players expect the change at the close, and a batch would need its own job, lock and failure story. The elapsed-time term stands in for the period.
- **Elo, or TrueSkill-style ranking of the whole order:** Elo has no deviation, so no provisional badge and no faster movement for new or returning players; a full-order model is more than the owner's decisions need and has no published reference to test against.
- **Rating after the close, in a job:** rejected. A crash between the two would leave a closed race unrated, and a retry would need its own idempotency. In the closing transaction "closed" implies "rated once".

## Consequences

- Leaving a rated race after the gun is a retirement: the player was at the gun, so she is rated, behind everyone still racing. A seat given away before the gun is a bot's and unrated, and a player who isn't back by the gun sails unrated.
- With one human and bots a race is unrated, so early on many races change nobody's rating.
- The weight exponent is the tuning knob (#157's calibration reads `rating_history`). Changing it changes future races only.
- `rating_history` keeps every change with place and opponents, and `race_bots` each bot's given rating: enough for the bots' shadow ratings (#177) without re-reading logs. Bots must never write `ratings`.
- The leaderboard must be "most recent score" (#55): ratings fall as well as rise.
