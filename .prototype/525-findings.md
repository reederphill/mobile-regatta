# #525 findings: a look-ahead planner for leeward-gate roundings in traffic (research prototype, never merged)

Branch `prototype/525-gate-planner` (worktree `.claude/worktrees/t525`). Code: `RegattaBots/BotVariant.swift` (letters), `BotBrain+GatePlanner.swift` (planner), `BotBrain+Gate.swift` (hook, H1), `BotBrain.swift` / `BotBrain+Conduct.swift` (H2, H3), `BotSuite/PackProbe.swift` (Q1 `PK` lines). Raw results: `.prototype/results/*.{txt,err}`; scripts `.prototype/{run.sh,sum.py,pk.py,split.py,seq.py,fd.py}`; cost test `Tests/RegattaBotsTests/PlannerCostTests.swift`. Nothing in `RegattaCore/Sources/RegattaCore` was touched. With no variant letter the run is byte-identical to clean HEAD (`main-clean-8`, checked after every code change, last time at the end of the session).

Variant letters (`REGATTA_BOT_VARIANT`): `1 2 3` = hand-fix parts, `H` = all three; `P` = planner; `m` = anchored to main's own pick (the version that works); `t` = others at their turn rate; `b` = planner blind to traffic (attribution); `f` = roll-out fidelity attempt (worse, off). **`Pm` is the planner, `PmH` is planner plus hand fixes.** Plain `P` is the first, unanchored planner (parked, see 1).

## 0. Verdict

**Candid first: the bot suite cannot measure the pack problem, so none of the gains below is proof that the owner's playtest pack is fixed.** Packs (>= 3 boats within 20 m at the pick) are 1% of gate roundings at 8 and 16 mixed boats and 4% in an all-National 16-boat fleet (106 of 2550 roundings). In those packs main does not lose more metres than elsewhere (26.8 m extra in a pack against 25.9 m not), and neither fix cuts them (planner: 28.2 m in a pack, 20.3 m not). What the suite shows is dirty air (39-44% of roundings in 16-boat fleets, +18 m when it happens) and a general better pick/approach. I recommend a **pack scenario ticket first** (section 6, ticket 0).

On what the suite does measure (gate mean extra metres, noise gap 1.6 m at 8 boats, 0.7 m at 16):

| answer | call |
|---|---|
| Planner (`Pm`) | **Conditional go**, bots layer only. Gate mean -2.1 to -5.1 m against main in every set (8 boats -2.8 / -2.1, 16 boats -3.0 / -3.5, all-National 16 -5.1, mixed 10 -2.4, all-Club -2.8), overshoots 12 -> 4 at 8 boats, finish shares and tier place gap unchanged. Conditions: it costs 1.6-3.6 ms a call and 3.2 ms (p50) / 4.6 ms (p99) a tick on the host with 6 of 16 boats planning, against a 1 ms p99 target, so it needs a skip gate and a cheaper wake copy first; and it leaves more boats still below the line 15 s after the leg end (110 against 67 in 2550 all-National roundings), not understood. |
| Hand fixes (`H`) | **H1 + H3 go (cheap, no CPU); H2 no-go as written.** H gets about half of the planner's gain (8 boats -1.4 / 0.0, 16 boats -2.7 / -1.9, National 16 -2.3, mixed 10 -1.3). H2 (a boat owing her room is not a keep-clear boat) is the biggest part at 16 boats but adds racing fouls (8 boats 372 against 344) and rule 18.2 calls (club 2 -> 12 and 14 in 160 mixed 10-boat races, `H-10`, `PmH-10`). |
| Both (`PmH`) | **No.** P+H is within the noise of P alone (8 boats 13.8 / 14.0 against 14.8 / 13.9; 16 boats 17.5 / 17.0 against 17.4 / 17.6; National 16 20.2 against 19.8) and has the worst still-below counts (158). |
| Neither | Not the answer: both move the suite by more than its noise. But see the first paragraph. |

Where the planner's gain comes from (variant `b`, planner that sees no boats and no wake): all-National 16 gate mean main 24.9, blind 22.8, planner 19.8, H 22.6. So about 40% of the planner's gain is a better single-boat route (equal to H), 60% is reading traffic. At 8 boats main 17.6, blind 16.7, planner 14.8.

## 1. The regression in the first planner (item 1 of the brief), cause and fix

Symptom (8 boats, `P3-8`, unanchored `P`): gate mean better than main (16.3 against 17.6) but overshoots 14 against 12, time below the line 9.5 s against 7.7, still below 25 against 6, deepest 11.7 m against 8.3, p90 below 26.9 s against 11.

Trace (`REGATTA_ONLY=saltings-reach@1:gusty-offshore@7:2:8 REGATTA_GATE_TRACE=1`, seats 7 and 0; `.prototype/seq.py` lists a seat's chosen candidates): the worst rows (up to 258 m extra, 122 s) are boats that hit or overshoot a mark on a pick that main would not have made. Two causes:

1. **The pick flip-flops.** The candidate scores jump by 30-100 m from one decision to the next (a boat crossing the predicted track adds or removes up to the 80 m keep-clear penalty), so the held choice is beaten by the 25 m mark-change margin every second or two: seat 4 of that race changed its choice 7 times in 6 s, seat 7 went R, L, R, L. Each flip turns the boat 40 degrees and the 3 s tap interval stops the gybe from completing, so she ends up on the wrong gybe next to a mark (seat 7: right of the line, gybe refused/slow, speed 8 -> 3.9 m/s at the left mark, 258 m extra).
2. **The roll-out is not what `gateAim` sails.** It gybes the moment the point is on the other gybe (no `tapInterval`, no mark/boat clearance refusing the gybe, no `avoidMarks`), and it models "no gybe" as the groove while `gateAim` sails straight at the point. So `Llayline`-style candidates look reachable and are not.

Variants tried (box: 3 variants / 45 min):
- `f` (roll-out sails straight / taps as `gateAim` does): **worse** (8 boats: overshoots 31, still below 26). Off.
- `m` (anchor to main): the planner computes main's own pick (`picksLeftGateMark` with its hysteresis and main's mode) as the reference candidate, and hands back to main's code, bit for bit, unless another candidate beats it by `REGATTA_PLAN_ANCHOR` = 25 m (a held override stays while it beats main by half of that). Brief's design choice 5. **Fixes it**: `Pm-8` gate 14.8, e2e 17.2 m, overshoots 4 (main 12), below the line 8.0 s (main 7.7, noise 7.4), deepest 9.5 m (8.3 / 8.1). Still below 10 (main 6 / 7, noise 6-11).
- Anchor 12 / 40 m (slider, `Pm-a12-8`, `Pm-a40-8`): 12 m gives gate 14.5 but still below 35; 40 m gives gate 16.7 and still below 7. So the gain and the still-below defect move together: the planner's overrides are where the boats get hurt.
Parked residue: still below 10-16 against 6-7 at 8 boats, 110 against 67 in 160 National races. Probable cause (not proven): a late override leaves the boat on the wrong gybe next to a mark (`PA` trace: `canTap` false for 3 s after a tap, `markClear` false inside the mark's clearance), which the roll-out does not model. First thing to try in the build ticket: no overrides inside ~30 m of the line, and give the roll-out the tap interval.

Cause of "worse unless anchored", in one line: an unanchored roll-out planner scores every candidate, main's included, with its own model error, so it differs from main in almost every rounding, mostly for no reason.

## 2. Q1 baseline on main (`results/q1.md`)

| fleet | roundings | in a pack (>=3 within 20 m) | a boat within 20 m | packs on one mark | entitled (a notice named her) | passed outside while entitled (>= 1 hull / any) | dirty-air s a rounding (shadow < 0.85, inside 80 m) | share dirty | extra m: dirty / not | gate mean extra |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 mixed, seeds 1-8 | 635 | 4 (1%) | 11% | 3 of 3 | 61% | 3 (1%) / 8 | 1.01 | 27% | 30.6 / 15.9 | 17.6 |
| 16 mixed, seeds 1-4 | 638 | 7 (1%) | 20% | 4 of 6 | 70% | 5 (1%) / 20 | 1.84 | 39% | 33.4 / 16.6 | 20.4 |
| all-Club 8 | 636 | 5 (1%) | 10% | 3 of 3 | 64% | 6 (1%) / 9 | 1.05 | 22% | 31.9 / 14.9 | 15.2 |
| all-National 16, seeds 1-16 (`main-nat-16x`) | 2550 | 106 (4%) | 24% | 71 of 79 packs (90%) | 66% | 28 (2%) / 63 | 2.18 | 44% | 36.2 / 17.7 | 24.9 |

Current (saltings-reach) against none: packs 0-1 of 127-128 roundings, dirty air 0.70-1.38 s against 1.09-2.06 s a rounding; the venue split is in `q1.md` and is too small to read (a few packs a venue). Packs are 1% of roundings at 8 and 16 mixed boats, 4% at 16 National; Q1 (iv): a pack costs no more metres than a non-pack rounding on main (26.8 / 25.9 in the National set), dirty air costs +15 to +19 m. In the National 16 set the first leeward gate has 79 packs in 160 races, 90% of them on one mark.

Noise (main, no variant): 8 boats seeds 1-8 gate mean 17.6, seeds 9-16 16.0 (gap 1.6; e2e 19.9 / 18.3); 16 boats seeds 1-4 20.4, seeds 5-8 21.1 (gap 0.7). Overshoots 12 / 8, still below 6 / 7, below the line 7.7 / 7.4 s. **A move inside those gaps is not a finding.**

## 3. Q2: sweeps against main and against H

Gate roundings, `scripts`: `.prototype/run.sh <name> <letters> --tier-mix .. --fleet-size .. --seeds ..`. "Gate" = mean extra metres a rounding (approach from 80 m, the rounding, 15 s after); "e2e" = entry to the leg's end; over = overshoots (>= 3 s below the line); below = mean seconds below the line; deep = deepest m; still = boats still below 15 s after the leg end; tiers C/R/N. Rows from `.prototype/sum.py`.

| set | variant | n | gate | p90 | e2e m / s | over | below s | deep m | still | gate by tier C/R/N | finish C/R/N |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 8 mixed s1-8 | main | 635 | 17.6 | 32.5 | 19.9 / 6.7 | 12 | 7.7 | 8.3 | 6 | 17.7/17.2/17.9 | .710/.947/.994 |
| | H | 634 | 16.2 | 30.3 | 19.0 / 6.4 | 7 | 7.5 | 8.4 | 5 | 16.3/15.9/16.4 | .690/.916/.994 |
| | P (unanchored) | 635 | 16.3 | 28.2 | 18.5 / 6.2 | 14 | 9.5 | 11.7 | 25 | 15.4/17.3/16.6 | .710/.953/.994 |
| | **Pm** | 635 | **14.8** | 26.9 | 17.2 / 6.0 | 4 | 8.0 | 9.5 | 10 | 14.8/14.0/15.7 | .728/.942/.988 |
| | Pmt | 635 | 14.5 | 26.7 | 16.4 / 5.9 | 6 | 8.2 | 9.8 | 15 | 13.7/14.9/15.3 | .734/.942/.975 |
| | PmH | 635 | 13.8 | 25.5 | 15.5 / 5.4 | 3 | 8.4 | 10.8 | 15 | 13.8/13.6/14.0 | .721/.932/.994 |
| | Pmb (blind) | 635 | 16.7 | 29.1 | 19.0 / 6.7 | 8 | 7.8 | 9.1 | 8 | 18.4/15.6/14.9 | .710/.942/.994 |
| 8 mixed s9-16 (noise set) | main | 639 | 16.0 | 28.4 | 18.3 / 6.2 | 8 | 7.4 | 8.1 | 7 | 16.1/18.1/13.2 | .713/.911/.987 |
| | H | 639 | 16.0 | 28.1 | 19.2 / 6.8 | 9 | 7.9 | 8.4 | 11 | 15.1/18.4/15.0 | .684/.889/.980 |
| | Pm | 639 | 13.9 | 25.4 | 15.7 / 5.6 | 6 | 8.0 | 9.6 | 16 | 13.1/15.7/13.3 | .668/.911/.987 |
| | PmH | 639 | 14.0 | 26.2 | 16.0 / 5.8 | 6 | 8.4 | 10.1 | 15 | 14.1/14.8/12.8 | .668/.894/1.000 |
| 16 mixed s1-4 | main | 638 | 20.4 | 36.9 | 23.1 / 8.1 | 19 | 8.6 | 8.5 | 14 | 20.0/20.1/21.5 | .427/.809/.906 |
| | H | 638 | 17.7 | 31.4 | 20.7 / 7.9 | 13 | 9.0 | 9.5 | 16 | 16.4/18.2/19.3 | .446/.805/.931 |
| | Pm | 638 | 17.4 | 29.6 | 19.6 / 7.7 | 10 | 9.1 | 10.3 | 16 | 17.7/16.8/17.7 | .408/.795/.875 |
| | PmH | 637 | 17.5 | 31.7 | 19.6 / 8.2 | 13 | 9.7 | 11.5 | 24 | 19.1/15.2/17.8 | .469/.823/.906 |
| 16 mixed s5-8 (noise) | main | 636 | 21.1 | 43.2 | 23.8 / 10.1 | 14 | 9.3 | 8.7 | 17 | 21.5/18.4/22.5 | .334/.771/.876 |
| | H | 637 | 19.2 | 37.8 | 22.2 / 9.8 | 12 | 9.0 | 8.9 | 20 | 21.3/17.0/17.6 | .345/.693/.881 |
| | Pm | 636 | 17.6 | 29.5 | 19.7 / 8.3 | 14 | 9.4 | 10.2 | 22 | 17.0/18.8/17.7 | .362/.779/.881 |
| | PmH | 637 | 17.0 | 32.3 | 18.8 / 8.6 | 11 | 9.7 | 10.6 | 21 | 18.0/15.2/16.8 | .328/.771/.890 |
| all-Club 8 s1-8 | main | 636 | 15.2 | 28.3 | 18.6 / 6.9 | 7 | 7.9 | 8.0 | 4 | 15.2 | .887 |
| | H | 636 | 13.7 | 26.6 | 17.3 / 6.8 | 6 | 7.9 | 8.4 | 8 | 13.7 | .867 |
| | Pm | 636 | 12.4 | 23.7 | 15.5 / 5.8 | 6 | 8.1 | 9.1 | 21 | 12.4 | .873 |
| | PmH | 636 | 11.3 | 22.6 | 14.6 / 6.1 | 2 | 8.1 | 9.4 | 19 | 11.3 | .878 |
| all-National 16 s1-16 (160 races) | main | 2550 | 24.9 | 40.7 | 25.9 / 8.0 | 109 | 9.7 | 9.4 | 67 | N 24.9 | .851 |
| | H | 2549 | 22.6 | 35.1 | 24.6 / 8.2 | 96 | 10.7 | 11.2 | 69 | N 22.6 | .855 |
| | Pm | 2548 | 19.8 | 31.5 | 20.6 / 6.5 | 65 | 10.2 | 12.3 | 110 | N 19.8 | .856 |
| | PmH | 2549 | 20.2 | 32.9 | 20.5 / 6.8 | 76 | 11.2 | 13.8 | 158 | N 20.2 | .856 |
| | Pmb (blind) | 2550 | 22.8 | 35.4 | 23.7 / 7.2 | 108 | 10.4 | 11.3 | 98 | N 22.8 | .851 |
| 10 mixed s1-16 (Q5 set) | main | 1595 | 18.0 | 35.2 | 20.5 / 7.5 | 37 | 8.3 | 8.6 | 23 | 18.9/17.8/16.4 | .603/.879/.961 |
| | H | 1592 | 16.7 | 32.0 | 19.3 / 7.3 | 20 | 8.2 | 8.9 | 23 | 17.4/16.3/16.0 | .583/.879/.951 |
| | Pm | 1595 | 15.6 | 27.9 | 17.6 / 6.6 | 25 | 8.5 | 9.8 | 32 | 15.8/14.9/16.3 | .594/.887/.951 |
| | PmH | 1594 | 14.7 | 27.8 | 16.5 / 6.2 | 18 | 8.7 | 10.6 | 43 | 15.9/12.9/14.5 | .571/.879/.966 |

Reading, always against the noise gap (1.6 m at 8 boats, 0.7 m at 16):
- Planner gain on the gate mean: 8 boats 2.8 / 2.1, 16 boats 3.0 / 3.5, Club 2.8, National 16 5.1, mixed 10 2.4. Every one is outside the noise. H gains: 1.4 / 0.0, 2.7 / 1.9, 1.5, 2.3, 1.3: half of the planner's, and 0.0 on the 8-boat noise set. So H gets about half, not most, of Q2's gain: the planner is not ruled out by the brief's test, but it is not far ahead either (1.3 m at 8 boats, 2.8 m at National 16).
- p90 and the share of roundings >= 30 m (11.8% -> 7.2% at 8 boats, 17.5% -> 11.2% National 16) fall most, i.e. it removes bad roundings.
- The cost: boats still below the line 15 s after the leg end rise (see 1); time below the line and deepest depth rise slightly (8.0 / 9.5 m against 7.7 / 8.3 m at 8 boats, still inside the s9 noise on seeds 9-16 for time, not for depth).
- Racing fouls and calls: no planner effect: 8 boats 336 (main 344); calls as offender by rule (10 / 11 / 12 / 13 / 16.1 / 17) flat in every set (`Pm-8`: 159 / 172 / 20 / 22 / 36 / 0 against 171 / 169 / 21 / 21 / 35 / 1; mixed 10: 496 / 419 / 83 / 65 / 76 / 2 against 490 / 434 / 82 / 73 / 80 / 1). H2 adds fouls and rule 18.2 (above). Rule 18 appears in the call lists as 18.2: main 2 / 3 / 0 (C/R/N), H 12 / 7 / 2, PmH 14 / 4 / 3, Pm 4 / 2 / 0 (mixed 10). Rule 31 (`t31`): 0-14 touches, no pattern (Pmb-nat-16 14 against 8 on main, a mark-avoidance sign worth watching).
- Mark touches per boat (marks/boat): 0.08-0.12 in every set, no change.
- Current (saltings-reach) against none: not split out for the sweeps (one venue of ten, 127 roundings, a few packs): `q1.md` has the baseline split and it is too small to read; a one-venue matrix file would be needed.
- Cautious suite: not run (`BotTierSuiteTests` is one lap, no gate; the planner only runs on the gate leg). The cautious (dropped-player) bot shares `BotBrain`, so a planner on by default would run for her too: not measured.

### Pack and entitlement measures with the planner (`pk.py`, `split.py`)
All-National 16 (160 races, 79 first-gate packs in main):
| | packs (>= 3 within 20 m) | packs using one mark | passed outside while entitled (>= 1 hull / any) | dirty air s a rounding | share dirty | dirty m | extra m: pack / not | extra m: dirty / not |
|---|---|---|---|---|---|---|---|---|
| main | 106 (4%) | 90% | 28 / 63 | 2.18 | 0.44 | 3.4 | 26.8 / 25.9 | 36.2 / 17.7 |
| H | 100 | 30% | 49 / 100 | 1.95 | 0.41 | 2.9 | 27.3 / n/a | n/a / 17.7 |
| Pm | 96 | 49% | 30 / 65 | 1.79 | 0.39 | 2.9 | 28.2 / 20.3 | 28.9 / 15.3 |
| PmH | 97 | 43% | 19 / 79 | 1.77 | 0.39 | 2.8 | 25.2 / 20.3 | 28.5 / 15.4 |
| Pmb | 90 | 60% | 31 / 57 | 1.95 | 0.42 | 3.2 | 26.3 / 23.7 | 34.3 / 16.2 |
8 boats: dirty air s a rounding 1.01 -> H 0.89, Pm 0.89, PmH 0.85; 16 boats 1.84 -> 1.66 / 1.67 / 1.70; Club 1.05 -> 0.86 / 0.76 / 0.89. Gap-shooting is not visible in the "passed outside while entitled" count: it does not fall with the planner (28 -> 30) and rises with H (49), the opposite of what H2 should do: **the suite does not show a gap shot as a gain**.

**Item 2: one race where P splits a pack and main doesn't.** Same first-gate state up to the pick in both runs (every variant is identical until a boat is within 80 m of the first gate), so the pack is the same pack. Of 79 first-gate packs in the 160 National races, main puts the members on both marks in 8; `Pm` in 44 (H and PmH: 55). Example (picked because it is large, not typical): `dev-venue@7:sea-breeze@7:12:16` (REGATTA_ONLY, all-National, 16 boats), seats 2, 8, 10 (+6, 9) within 13-40 m of each other at the pick. Main: seat 8 takes the right mark, seat 2 the left, they meet at the gate, both overshoot (251 m and 228 m extra, 95 s and 76 s from entry to the leg's end, 82 s and 77 s below the line). `Pm`: seat 8 changes to the left mark (`Rgybe-now-out` at 189 s, back to `L...` within a second, the final pick L), nobody is hurt: seat 8 8.1 m, seat 2 2.8 m, seat 10 1.7 m extra, 14-22 s entry to end. Fleet gate mean in that race 17.5 (main 57.9). The gap candidate ("inside") was chosen at times (`Rgybe-now-in` at 191 s for seat 2, `Lno-gybe-in` for seat 9 from 193 s) but flickers on and off from decision to decision (seat 9: 19 changes in 12 s): **I did not find a race where a sustained gap-shot is the reason**; the gain comes from the mark choice. Across the 79 packs the sum of members' entry-to-end extra metres is not lower with the planner (mean 79 m main, 86 m `Pm`; in the 44 packs it splits 92 / 92). So splitting a pack is something it does a lot and does not, on average, pay for in this suite. The inside candidate is chosen in 4% of planner decisions (4481 of 109,184; 24% of the 19,061 overrides) in 40 all-National 16-boat races. Trace of this race: `show2-Pm.err` (`PT` lines: every candidate's score and the choice).

## 4. Q3: roll-out fidelity (`fd.py`, `Pm-8fd`, `Pmt-8fd`)
Position error of the chosen candidate's stored track against the boat's actual position (m, mean / p90; the others' prediction error enters only through the wake and avoidance; the boat sails main's `navigate` code, not the roll-out helm, so this error includes the gap between the two):
| | @4 s | @8 s | @12 s (n small: only 15 s horizons, 189 samples) |
|---|---|---|---|
| all, constant-velocity others (`Pm`) | 4.4 / 9.3 | 9.8 / 19.8 | 13.3 / 29.1 |
| all, turn-rate others (`Pmt`) | 4.4 / 9.2 | 9.8 / 19.7 | 13.3 / 27.6 |
| Club / Regional / National (`Pm`) | 4.6 / 4.4 / 4.1 | 10.4 / 9.3 / 9.4 | - / 12.8 / 13.4 |
| light (< 6 m/s) / mid (6-9) / fresh (>= 9) (`Pm`) | 3.6 / 4.8 / 6.0 | 7.6 / 10.7 / 13.5 | 11.0 / 15.2 / 20.8 |
Turn-rate others (`t`) change nothing worth building (gate mean 14.5 against 14.8, inside the noise; error identical). The error is 10 m at 8 s and 13 m at 12 s (a boat is 4-5 m long): about half a boat length a second of drift, growing with wind. That is enough to rank "left or right" and not enough to thread a 1-hull gap, which is consistent with the gap candidate flickering. A 15 s horizon at National is mostly model error beyond 8 s. It also says the horizon lever (8 -> 15 s) buys little: past 8-10 s the roll-out is guessing.

## 5. Q4 cost (`results/q4.md`, `PlannerCostTests`)
Host Mac, -O, a 16-bot race frozen when 5-6 of 16 boats are inside the 80 m pick range:
| config | planner call p50 / p99 ms | whole tick (the deciding third) p50 / p99 ms |
|---|---|---|
| main (no planner) | - | 0.07 / 0.10 |
| Pm, tiers on, dt 0.2 s | 1.60 / 2.67 | 3.17 / 4.64 |
| Pm, tiers on, dt 0.1 s | 1.44 / 2.55 | 2.54 / 3.08 |
| Pm, everyone 12 cand x 15 s, dt 0.2 s | 3.08 / 3.70 | 1.41 / 7.20 |
| Pm, everyone 12 cand x 15 s, dt 0.1 s | 3.57 / 4.39 | 1.61 / 8.63 |
The planner costs 1.3-3.6 ms a call, almost independent of the time step (so a fixed cost dominates, probably `planContext` copying and extending the wake ribbons for every call; not profiled). That is three times the "1 ms p99 a tick" guide on the host, and the device is slower. Plan every 3rd decision divides the mean by 3, not the worst tick (boats' phases are staggered). Levers not built: skip the planner when no boat is within ~40 m and no ribbon is near (then it can only differ from main by model noise; at 8 boats 89% of roundings have no boat within 20 m), build the extended wake once a tick, cut the horizon to 8-10 s (Q3 says nothing is lost).

## 6. Q5: tiers (mixed 10, 160 races; `main-10`, `H-10`, `Pm-10`, `PmH-10`)
| | gate by tier C/R/N | finish C/R/N | mean place C/R/N | club calls 10/11/12/13/16.1/18.2 |
|---|---|---|---|---|
| main | 18.9 / 17.8 / 16.4 | .603 / .879 / .961 | 6.0 / 4.4 / 3.0 | 332 / 280 / 62 / 24 / 35 / 2 |
| H | 17.4 / 16.3 / 16.0 | .583 / .879 / .951 | 6.1 / 4.5 / 2.9 | 327 / 288 / 55 / 25 / 31 / 12 |
| Pm | 15.8 / 14.9 / 16.3 | .594 / .887 / .951 | 5.9 / 4.5 / 3.0 | 333 / 272 / 59 / 23 / 31 / 4 |
| PmH | 15.9 / 12.9 / 14.5 | .571 / .879 / .966 | 6.1 / 4.5 / 3.0 | 334 / 278 / 52 / 23 / 31 / 14 |
The place gap holds: Club 6.0 / Regional 4.5 / National 3.0 in every variant, finish shares within 0.03. Club still looks like Club in the sense the brief names (calls as offender flat). But the tier lever does not open a gap: Club's gate mean improves as much as Regional's (-3.1 and -2.9 against -0.1 for National in this mixed fleet), because the overrides that matter are not horizon-limited (Q3: the roll-out is guesswork past 8 s), and National improves in the all-National 16 fleet (-5.1) where traffic is. So "Club shoots fewer gaps" is not what the lever does; it is not measured directly (no per-tier inside-candidate count: the `PT` trace has no skill). A tier difference that survives would need noise or a delay on the planner's input (a Club boat sees the boats 1-2 s late), not just horizon and candidate count: open question 5.

## 7. Build tickets (bots layer only; no core, class, app or default-switch layer exists for this)

The planner reads public API only (`view.wake`, `TurbulenceRibbons`, `BoatDynamics.advance`, `Autohelm`, `ShadowCone` via `view.wake.factor`); no `RegattaCore` change was needed. It changes bot behaviour, so it moves the RegattaBots goldens (digest rows from the CI Linux log) and the bot matrix; UI references only if a render fixture shows a gate rounding with bots (check at the time). Order, per `orchestration.md` (core+class -> bots -> app -> default switch) it collapses to:
0. **Pack scenario (suite/harness, no sim change).** A `--scenario pack` mode that places 4-6 boats in a bunch 100 m above the gate (several offsets, with and without current), seeded, and measures: marks used, extra metres per boat, contacts, calls, time below the line. This is the measurement the suite lacks (packs are 1-4% of roundings; the owner's playtest pack is a placed one). Moves nothing in goldens. **Do this first.** It decides whether H or P is worth shipping against the real complaint.
1. **Hand fixes H1 + H3 (bots, small).** `gateTrafficMetres` in `gateOption` and the one shadow gybe on the rounding gybe (H1, `BotBrain+Gate.swift`), 0.6-hull tap clearance against a boat that owes her room (H3, `BotBrain+Conduct.swift`). Moves: RegattaBots goldens, bot matrix; gate mean -0.5 to -2.7 m. Drop H2 (fouls and rule 18.2) or redo it after ticket 0.
2. **Planner `Pm` (bots).** `BotBrain+GatePlanner.swift` with the anchor, the `gateAim` hook, `gatePlan.gapLeg` in `ruleKeepClear`/`tapIsClear`, tier lever as a pure function of skill (`BotSkill`, like `keepClearLookahead(skill:)`). First defect to remove: the still-below residue (no overrides inside ~30 m, tap interval in the roll-out). First cost to remove: skip gate and wake copy (target < 1.5 ms p99 a tick for 16 boats). Time-boxed ~45 min / 3 variants for each. Moves: RegattaBots goldens, bot matrix, the Bench's tick budget (`BotBenchmarkTests` and the planner cost test promoted from prototype).
3. **Default switch (bots, small).** The variant letters go away; `Pm` on for all tiers or by skill; goldens/rows re-taken from CI.

## 8. Open questions for the owner (recommended answer first)

1. Build the pack scenario (ticket 0) before choosing between H and the planner? **Yes.** The suite shows 1-4% packs and no pack gain; the playtest pack is not in it.
2. Is a collision-avoidance term in a candidate score "orderly"? The planner prices only contact (80 m for a boat she keeps clear of, half that for a hull-length miss of any other), as a penalty turn would, and a candidate never wins by "staying away" (the dirty-air weight is 3 m a second; it's a slider). **Recommend: allow; it is what a sailor weighs, and it's internal.**
3. Is a planner that costs the CPU of 2-3 ms a decision acceptable on the device (16 boats, up to 6 planning at once)? **Recommend: only after the skip gate (plan only with a boat within ~40 m or ribbons near her path), and measure on the device (#172's way).**
4. Keep H2 (a boat owing her room is not a keep-clear boat)? **No as written**: it adds fouls and 18.2 calls and does not reduce entitled-pass-outside counts (28 -> 49 in the National set). Revisit with the pack scenario.
5. Should Club use a different mechanism than horizon/candidate count (a delayed view of the others, or planner off in Club)? **Recommend: planner on at Regional and National only at first; Club keeps main's pick (the all-Club gain of -2.8 m is not worth a Club boat that sails like a Regional one).** The tier gap in place holds either way.
6. Is "gap shot" (inside candidate) wanted at all? It flickers and the suite doesn't show it paying. **Recommend: drop the inside candidates from the first build; keep mark choice + gybe timing.**

## 9. Owner's commands (bot-suite runs on this Mac, one at a time, via `scripts/heavy.sh`)

Build once:
`scripts/heavy.sh swift build -c release --product regatta-botsuite --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore`
A sweep (writes `.prototype/results/<name>.{txt,err}`, prints the summary row; `.err` has the `PK` lines):
`.prototype/run.sh <name> <letters> --tier-mix <mixed|club|national> --fleet-size <8|10|16> --seeds <n>` with `REGATTA_SEED_START=9` for the noise set. The sets used here:
- 8 mixed: `--tier-mix mixed --fleet-size 8 --seeds 8` (about 35 s); noise `REGATTA_SEED_START=9`
- 16 mixed: `--tier-mix mixed --fleet-size 16 --seeds 4` (about 1 min); noise `REGATTA_SEED_START=5`
- all-Club 8: `--tier-mix club --fleet-size 8 --seeds 8`
- all-National 16 (the pack source, 160 races, about 3-4 min each): `--tier-mix national --fleet-size 16 --seeds 16`
- Q5, mixed 10, 160 races (about 2-4 min): `--tier-mix mixed --fleet-size 10 --seeds 16`
Variants to give: `""` (main), `H`, `Pm`, `PmH`, `Pmb`; `REGATTA_PLAN_ANCHOR=<m>`, `REGATTA_PLAN_DT`, `REGATTA_PLAN_NOTIERS=1` are sliders. Packs: `python3 .prototype/pk.py <name>...`, splits `python3 .prototype/split.py main-nat-16x Pm-nat-16`, one race: `REGATTA_ONLY=<venue>:<conditions>:<seed>:<fleet> REGATTA_GATE_TRACE=1 .prototype/run.sh trace Pm --tier-mix national --fleet-size 16 --seeds <seed>` then `python3 .prototype/seq.py trace`.
Cost: `REGATTA_BOT_VARIANT=Pm scripts/heavy.sh swift test --filter PlannerCostTests --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore -Xswiftc -O`.
The real bot matrix, once the ticket exists (not run here): `scripts/bot-matrix.sh --profile-mix live --tier-mix national --tier-mix mixed --seeds 16` (and `--diagnose` for the rounding tables). The golden/RegattaBots rows come from the CI Linux log only.
App check, 12-boat race to the first gate with the planner on (not built here): `SIMCTL_CHILD_REGATTA_BOT_VARIANT=Pm xcrun simctl launch --terminate-running-process <device> <bundle id> -demo -seed <n> -startSeconds 10 -timescale 4` (the exact flags are in `validation.md`, Local preview).

## 10. What this does not show
- The suite has no pack scenario: the first-gate packs in 16-boat National races (79 in 160 races) are the richest source and are mostly three boats in a bunch with a clear lane, not the owner's playtest pack (not reproduced).
- One race tells the pack story (section 3); the population says splitting does not lower the pack's metres. The planner's gain is mostly spread over non-pack roundings (route and dirty air).
- Still-below worsens with the planner (cause not proven). The cautious bot, rule 31 at marks and the device cost are not measured. Current (saltings-reach) is not split out in the Q2 tables.
- Everything here is on release host builds of the suite; no CI, no `check.sh`, no goldens, no matrix, no app build were run.
