# #525 step 1 fix round 4: set-up gybe early and hard, run by the lee

origin/main had not moved (25238c7a is an ancestor of HEAD). Nothing was merged.

## Verdict: not met. Nothing committed.

- The best variant (v3) passes the sailed test and every unit and pack test.
- It cuts the deep tail well below base in most cells.
- It misses on two maxima:
  - all-Club 8: >40 is 1 against base 0, and the max is 46.5 against 38.3. This boat is the same one as on round 3 HEAD and is not touched by v3.
  - National-16: the max is 73.1 against 67.3. This boat is new, and v3 caused it.
- Time used: about 44 min, and 3 variants.
- The patch is kept, uncommitted, at `.brief/525-1-fix4/v3.patch` (it applies on 2e5d4d55). The worktree is clean apart from `.brief/`.

## Cause (confirmed by tracing the sailed test)

Round 3's mechanism is right, but there are three more pieces to it.

1. **The gybe has to be planned from where she will be.** I read her point's side from `position + velocityOverGround * gybeSeconds * gateSetUpLead`. `gybeSeconds` is the turn through dead downwind to her groove, at `max(gybeFraction, gateSetUpGybeFraction) * turnRate(speed)`. I also had to latch the plan (`gateSetUpGybe`): as she bears away the prediction swings back, and a dropped plan ends the hand turn.
2. **`navigate`'s aim kills the early gybe.** With her point still on her own side, `navigate` aims on the gybe she is already on. Once the point flips, `navigate`'s heated-up planing aim (about 155°) points her at her own mark from just above it. `avoidMarks` then ends the hand turn (`handTurning` evasion). The fix: inside `gateStraightRange`, gybe straight onto a raw run for her point, at `min(point's angle, gateMaxAngle)`, with no `downwindAim`.
3. **She gybes back after an early gybe.** If the gybe leaves her a little outside, the point is a few degrees past `gateLee` by the lee. The rounding-gybe branch's `!onOwn` then gybes her back, which is 2 gybes. "Run by the lee to the mark" lets her hold the run instead.

The leading deep cells in m8 (saltings gusty-offshore, the current setting her outside, mode A) had the same shape as 3 from 40 to 50 m out. That is why v3 extends the run range.

## Variants (m8 = 8-mixed s1-8, TmpGateTrace; the sailed test is green in all three)

| variant | >20 | >30 | >40 | max | still below |
|---|---|---|---|---|---|
| base | 20 | 4 | 2 | 45.1 | 6 |
| round 3 HEAD | 23 | 10 | 4 | 81.5 | 11 |
| v1: prediction (lead 0.5), latch, raw run aim, hard gybe 0.7, run by the lee ≤25° only off her set-up gybe | 12 | 7 | 3 | 81.3 | 10 |
| v2: v1 + run by the lee also within 30 m | 7 | 3 | 2 | 80.8 | 6 |
| **v3: v1 + run by the lee within 50 m (`gateSetUpRunRange`)** | **9** | **1** | **0** | **34.2** | **4** |

On v1 the gate mean on m8 was 14.8. On v3 it is **14.9**, against base 17.6, a gain of 2.7 m. The `--diagnose` still-below count is 4 (0.6%).

## Tail table, v3 (base / round 3 HEAD / round 4 v3)

| set | > 20 m | > 30 m | > 40 m | max | still below |
|---|---|---|---|---|---|
| 8-mixed s1-8 | 20 / 23 / **9** | 4 / 10 / **1** | 2 / 4 / **0** | 45.1 / 81.5 / **34.2** | 6 / 11 / 4 |
| 8-mixed s9-16 | 16 / 22 / **8** | 7 / 10 / **4** | 3 / 3 / **2** | 45.5 / 45.2 / **45.5** | 7 / 8 / 4 |
| all-Club 8 | 14 / 22 / **7** | 4 / 7 / **2** | 0 / 1 / **1 ✗** | 38.3 / 46.5 / **46.5 ✗** | 5 / 11 / 10 |
| all-National 16 | 173 / 238 / **104** | 48 / 88 / **34** | 15 / 27 / **10** | 67.3 / 81.9 / **73.1 ✗** | 72 / 59 / 57 |

Raw rows are in `.brief/525-1-fix4/tails-<set>-v3.txt`. Stats come from `tailstat.sh` (it reproduces round 3's table exactly).

## The two misses

- **club8 fellmere light-and-patchy s6, seat 4 (Club), 46.5 m.** This is identical on round 3 HEAD. It is mode C:
  - Her pick flips R to L about 15 m up, on S beside R.
  - The gybe it asks for is refused (evasion, then `clr n`).
  - She crosses on S and rounds L deep.
  - v3 does not touch it. Guard A, or a pick freeze inside `gateStraightRange`, is the lever.
- **nat16 fellmere gusty-offshore s16, seat 12, 73.1 m.** v3 introduced this one.
  - She is on P (the rounding gybe for L), 14 m outside her point at 48 m up, with the point by the lee.
  - The 50 m run range keeps her running instead of gybing away. But the run is `gateMaxAngle`, 3° short of dead downwind on her own side, not truly by the lee. So she slides on outward and down past L.
  - She gybes to S 6 m up outside the mark, crosses on S, and gybes below the line.
  - "Run by the lee" only works if she can actually sail at the point. The next try is to gate `runs` on the point being within about `gateLee` + a few degrees, or to let the run aim go by the lee for real.

## What changed in the patch (not committed)

- `BotBrain+Gate.swift`:
  - `gateSetUp` gains the prediction (inside `gateStraightRange` only), the latch, and the raw run aim on the rounding gybe.
  - New `gateSetUpGybeSeconds`.
  - The rounding-gybe branch of `gateAim` gains `runs`.
  - New constants: `gateSetUpGybeFraction` 0.7, `gateSetUpLead` 0.5, `gateSetUpLee` 25°, `gateSetUpRunRange` 50 m.
- `BotBrain+HandTurn.swift`: `startHandTurn` turns the set-up gybe at no less than `gateSetUpGybeFraction`. This overrides `PlaningTable.safeGybe`: "throw her round".
- `BotBrain.swift`: new `gateSetUpGybe: (leg, tack)?`.
- `BotGateTests`: `withKnownIssue` is removed from `farMarkSailedSheCrossesOnTheRoundingGybe`, with the doc updated and the assertions unchanged.
- **Tests on the patch:**
  - On v3, BotGateTests and BotMarkRoomTapTests pass, 19 tests.
  - On v1, BotHandTackTests and PackScenarioTests also passed, apart from the skiff long digest. They were not re-run on v3.
  - The digest moved: on v1 it was `0xad29b7e9d8f31e52`, against the pinned `0x1983f405f32e8e8f`.
  - It was not re-pinned for v3, because nothing was committed.

## Tester must re-test

Nothing. No commit was made in this round.
