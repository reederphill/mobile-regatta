# #525 step 1 fix round 2 (F1: far-mark approach and rounding)

origin/main had not moved; nothing merged. Guard A (round 1, 9274d572) is removed, along with its test `trafficDoesNotFlipHerPickCloseIn`. It measured as no effect, and this fix does not need it.

## Verdict: fixed. Deepest, gate gain and pack are all met; still below on 8-mixed s1-8 is 1.7%, above the ~1.2% bar

## Cause (traced per second, pack JSON pairing, worst switched boats)
I wrote a temporary trace test in BotSuiteTests. It was deleted and not committed. It sailed `PackScenario.placedRace` cells and logged the boat's position, angle, speed, tack, stage, pick and plan each second. On 7c855ff7/9274d572 the worst switched boats went 48 to 62 m deep. They did it like this:
- **Main cause: crossing the line on the gybe that doesn't round her mark.** She is on the other gybe, the else branch of `gateAim`. She sails straight for her point (`navigate`, then "straight on" inside 30 m) and crosses the line inside the mark on that gybe, heading inward, at 3 to 6 m/s.
  - Below the line (stage 1), `waypoint` is 9 m below and 10 m outside the mark, so she must gybe there.
  - In the pack that gybe is refused (`canTap`/`tapIsClear`, with boats at the mark). `refusedTurnAim` then holds a reach or her groove on the wrong gybe. She gybes 20 to 40 m deep and beats back.
  - Seen in cells (5,5,-6,mixed) s3, (8,4,-6,same) s3 and (4,5,+6,same) s1, all with current, national.
  - On main the cost (`gateMarkGybeMetres` 35) rarely picks that path. H1's traffic picks it often.
- **Second cause: a point a few degrees by the lee.** `gateMaxAngle` caps the straight aim. Inside `gateLee` the aim took the mirror angle on her own tack (174° for a point 6° by the lee), which sailed her away from the point and outside it. Then `!onOwn` gybed her onto the wrong gybe a few metres above the line. Seen in cell (12,4,-6,mixed,no current) s0.
- She also crossed outside her mark once and circled back in recovery. That was cell (13,6,0) s2, on a boat interaction, and was not addressed.

## Variants (8-mixed `--diagnose` seeds 1-8, gate row, all tiers)
| variant | gate mean m | below s | deepest m | deepest p90 | still below |
|---|---|---|---|---|---|
| base (tester) | 17.6 | 7.7 | 8.3 | 10.9 | 6 (0.9%) |
| branch 7c855ff7 / round 1 A | 15.7 | 8.8 | 11.0 | 21.9-23.4 | 19 (3.0%) |
| v1: set-up point 20 m up the rounding groove; gybe when her point bears on the rounding side | 14.5 | 7.5 | 8.6 | 11.6 | 11 (1.7%) |
| v2: v1, set-up distance shrinking with her height | 14.6 | 7.4 | 8.5 | 11.4 | 11 (1.7%) |
| v3: v2 + by-the-lee aim at `gateMaxAngle` | 14.8 | 7.5 | 8.4 | 11.2 | 10 (1.6%) |
| **v4 (committed): v3, but with a fixed reach at 100° when below the set-up point, not the shrinking one** | **15.0** | 7.6 | **8.6** | **11.2** | **11 (1.7%)** |

- v2's shrinking set-up point chased her down to the line in a unit scene. v4 replaces it with a fixed reach that keeps her height. On the suite all four variants are within counting noise of each other.
- v4 noise set (s9-16, `matrix-s9-16.json`):
  - base 16.0 / 8.1 / 10.3 / 7 (1.1%)
  - branch 14.9 / 9.9 / 19.6 / 14 (2.2%)
  - **v4 15.3 / 8.4 / 11.1 / 8 (1.3%)** (gate mean / deepest / p90 / still below)
- Pooled over 16 seeds:
  - still below: base 13 (1.0%), branch 33 (2.6%), v4 19 (1.5%)
  - gate mean gain: base 16.8 to v4 15.15 (-1.65 m); on s1-8, -2.6 m

## Pack scenario, default (576 races), "all" row, base -> v4 (branch in brackets)
- extra m mean: 33.5 -> **30.5** (30.3)
- pack extra m: 108.5 -> **102.2** (100.6)
- both marks used: 0.70 -> 0.89 (0.93)
- deepest m mean: 9.4 -> **8.7** (10.6)
- deepest m p90: 17.4 -> **15.7** (22.4)
- below s mean: 11.5 -> 11.0 (11.9)
- still below: 0.04 -> 0.03 (0.05)
- contacts/race: 0.94 -> 0.94
- calls/race: 0.67 -> 0.66
- touches/race: 0.05 -> 0.03

Paired with base per boat (`pair.py`):
- boats that keep their mark: deepest 9.0 -> 8.5, still below 79 -> 69
- boats switched to the other mark (652): deepest 10.7 -> 9.7, still below 26 -> 15 (on 7c855ff7 it was 10.2 -> 15.3 / 9.7 -> 17.7 and 21 -> 61)

## What changed (`BotBrain+Gate.swift`)
- New `gateSetUp`, called first in `gateAim`'s other-gybe branch. "Gybe above the mark, not at it":
  - Once her point bears on the rounding gybe's side, she plans that gybe (`navigate` to the point). Far out (30 m or more) that is only while the point is no more than `gateDeepest` deeper than her groove, so `farDeep` never gybes her back.
  - Before that, she sails on her own gybe across above her point. She aims for the set-up point `gateSetUpMetres` (20) up the rounding gybe's groove from her point while it is at least `gateSetUpDrop` (3 m) below her. Lower than that, she reaches at `gateSetUpReach` (100°).
  - Within `gateSetUpLow` (5 m) of her point's height it returns nil, and she does it the old way (straight on, gybe round the mark).
- Straight-for-her-point aim: when the point is by the lee (on the other side of dead downwind, inside `gateLee`), she sails `gateMaxAngle`, not the mirror angle.
- Guard A removed.
- New constants, all `static let`, set by hand: `gateSetUpMetres` 20, `gateSetUpDrop` 3, `gateSetUpReach` 100°, `gateSetUpLow` 5. Header and doc comments updated.

## Tests
- New `BotGateTests.farMarkSheGybesAboveTheLineNotAtTheMark`, a decision test with a boat stopped above the other mark's point to hold the pick:
  - On the other gybe, 28 m out and 10 or 25 m up, she aims more than 10° higher than her point and keeps her gybe. **Red** with `gateSetUp` disabled.
  - Inside the rounding groove, 10 m up, she aims on the rounding gybe. This part is green on the old code too.
- New `BotGateTests.herPointByTheLeeSheRunsNotMirrors`: point 6° by the lee, 20 m off, she asks `gateMaxAngle`. **Red** without the by-the-lee change (asked 174°).
- Changed `gybeRoundTheMarkCostsMoreThanTheReachAcross`: the "held" pose moved from 6 to 2 m above the line, below `gateSetUpLow`, so it still pins the old gybe-round-the-mark path low down. At 6 m she now sets up above the line.
- A sailed version of the far-mark test, a skiff on the plane, didn't converge:
  - Without a boat holding the pick, the costs (rightly) repick the reach across to the other mark.
  - With the pick held, the gybe she plans at 5 m above the line is slow by hand at 6 m/s, and `navigate`'s reach branch resets `plannedTack`, so she still crosses on the wrong gybe.
  - Not pursued. The pack and suite numbers carry the sailed evidence.
- `swift test -Xswiftc -O --filter "BotGateTests|BotMarkRoomTapTests|BotHandTackTests"`: 33 tests, all pass.
- Digest: `BotHandTackTests.skiffEightBotsAreBitIdentical` long digest moved and was **re-pinned**, 0xf802fb1dd21dc2b9 -> 0x1983f405f32e8e8f, with the comment extended. The short digest (seed 459) is unchanged.

## Tester must re-test
- Everything from the round 1 report on v4: all 7 diagnose sets, pack default, `--tier-mix mixed`, `--fleet-size 6`, fouls/calls by rule, Club gradation, benchmark.
  - The gate rows' deepest / p90 / still below should be near base.
  - The gate mean should hold most of the branch's gain.
- Watch:
  1. still below on 8-mixed s1-8: 11 against 6. The pooled 16 seeds read 1.5% against 1.0%, and the pack's still below is under base. Read it across the 16-boat and National sets before calling it.
  2. The set-up reach could add rule 11/12 contacts: she reaches across above her point, through boats running down to the other mark. Pack calls/contacts are flat, but read the 16-boat sets.
  3. Club gradation: the change is for every tier.
- Fallback C (round 1 note) is still available if the orchestrator reads still below as not converged. It gives up the gain.
- Raw outputs: `.brief/525-1-fix2/` (m8-v1..v4, m8n-v3/v4, pack-v1/v3/v4 .txt, the traces on 9274d572 (trace1) and v1 (trace2/3), pair.py, packsum.py). The pack JSONs stay in the scratchpad `525-1f2/`, which a reboot wipes.
