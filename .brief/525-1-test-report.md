# Test report: #525 step 1 (H1 + H3) at 7c855ff7

## Verdict

PASS on acceptance items 4 to 7, with one finding that is not a gate: below-the-line depth and "still below" rise in every set (see F1).
- Gate extra m falls in all 7 diagnose sets and in the pack scenario. In both pack seed halves the drop is several paired SEs.
- Fouls and calls: no new fouls beyond noise.
- Club gradation: unchanged.
- check.sh: passed at 7c855ff7.

Previous tester: its plan was followed. Its scratch outputs (`scratchpad/525-1/out`: pack, packmixed, pack6, m8, m8n, m16, m16n) were reused after both binaries were verified:
- base: `scratchpad/525-1/base-botsuite` is byte-identical to `t525-0`'s release binary. Its `--scenario pack --json` races equal `t525-0/.brief/525-0-baseline.json` exactly (576/576; only the timings differ).
- branch: `scratchpad/525-1/branch-botsuite` is byte-identical (sha1 5bbdc016) to this worktree's release binary. A release rebuild at 7c855ff7 was a no-op, and the tree is clean apart from `.brief/`.

Raw outputs, the compare scripts and the logs are in `.brief/525-1-results/`.

## Pack scenario (576 races, default; `--tier-mix mixed` 576; `--fleet-size 6` 192)

Each figure is a race mean, base -> branch. The paired SE comes from the per-race differences. The halves are seeds 1-8 and 9-16.

| run | extra m | pack extra m | both marks used | contacts/race | calls/race | deepest m | below s | still below share |
|---|---|---|---|---|---|---|---|---|
| default, all | 32.8 -> 29.8 (-3.0, SE 0.55) | 108.7 -> 100.9 (-7.8, SE 2.3) | 0.70 -> 0.93 | 0.936 -> 0.927 | 0.672 -> 0.661 | 9.34 -> 10.58 (+1.24, SE 0.14) | 11.46 -> 11.81 (+0.36, SE 0.19) | 0.035 -> 0.046 (+0.011, SE 0.004) |
| default, seeds 1-8 | -2.5 | -7.8 | +0.25 | +0.003 | -0.014 | +1.24 | +0.54 | +0.012 |
| default, seeds 9-16 | -3.6 | -7.8 | +0.21 | -0.021 | -0.007 | +1.25 | +0.17 | +0.010 |
| mixed tiers, all | 31.2 -> 29.7 (-1.5, SE 0.51) | 100.9 -> 99.4 (-1.5, SE 1.9) | 0.72 -> 0.93 | 1.384 -> 1.394 | 1.003 -> 0.991 | +0.91 | +0.43 | +0.010 |
| mixed, halves | -1.8 / -1.2 | -1.6 / -1.3 | | -0.035 / +0.056 | -0.031 / +0.007 | | | |
| size 6 | 36.9 -> 33.2 (-3.8) | 143.9 -> 130.3 (-13.6) | 0.81 -> 0.99 | 1.41 -> 1.46 (+0.05, SE 0.05) | 1.00 -> 1.03 | +1.53 | +0.36 | +0.022 |

Group rows on the default sweep give the extra m change:
- by size: 4 -2.1, 5 -3.2, 6 -3.8
- by offset: -6 -3.8, 0 -0.4 (flat), +6 -4.8
- by gybes: same -2.5, mixed -3.5
- by current: with -3.4, without -2.7

Every group row moves the same way. Offset 0 is the one flat row: the pack is centred and already split both marks 87% of the time on base.

Calls by rule per race on the default sweep:
- rule 10: 0.236 -> 0.227
- rule 11: 0.071 -> 0.069
- rule 12: 0.003 -> 0.009 (2 -> 5 calls)
- rule 13: 0.064 -> 0.057
- rule 16.1: 0.089 -> 0.095
- rule 18.2: 0.007 -> 0.010 (4 -> 6 calls)

Touches per race: 0.050 -> 0.038.

## Diagnose sweeps (live, laps 2), gate rows, base -> branch

The noise gap is the base's gate mean on seeds 1-8 against seeds 9-16 (16 boats: 1-4 against 5-8).

| set | races | gate mean m | entry-to-end m | p90 | over | below s | deepest m | still below |
|---|---|---|---|---|---|---|---|---|
| 8 mixed s1-8 | 80 | 17.6 -> 15.7 (-1.9) | 19.9 -> 17.8 | 32.5 -> 31.0 | 12 -> 5 | 7.7 -> 8.8 | 8.3 -> 11.0 | 6 -> 19 |
| 8 mixed s9-16 | 80 | 16.0 -> 14.9 (-1.1) | 18.3 -> 17.1 | 28.4 -> 28.1 | 8 -> 9 | 7.4 -> 8.5 | 8.1 -> 9.9 | 7 -> 14 |
| 16 mixed s1-4 | 40 | 20.4 -> 17.6 (-2.8) | 23.1 -> 19.7 | 36.9 -> 33.3 | 19 -> 12 | 8.6 -> 10.8 | 8.5 -> 12.7 | 14 -> 34 |
| 16 mixed s5-8 | 40 | 21.1 -> 20.6 (-0.5) | 23.8 -> 22.9 | 43.2 -> 44.6 | 14 -> 22 | 9.3 -> 10.7 | 8.7 -> 11.0 | 17 -> 29 |
| all-Club 8 s1-8 | 80 | 15.2 -> 13.3 (-1.9) | 18.6 -> 16.5 | 28.3 -> 26.1 | 7 -> 4 | 7.9 -> 8.7 | 8.0 -> 9.5 | 4 -> 18 |
| mixed 10 s1-16 | 160 | 18.0 -> 16.7 (-1.3) | 20.5 -> 19.0 | 35.2 -> 31.2 | 37 -> 24 | 8.3 -> 9.5 | 8.6 -> 10.9 | 23 -> 51 |
| all-National 16 s1-16 | 160 | 24.9 -> 20.0 (-4.9) | 25.9 -> 21.0 | 40.7 -> 33.1 | 109 -> 78 | 9.7 -> 11.8 | 9.4 -> 14.6 | 67 -> 159 |

- Noise gap: 1.6 m with 8 boats (17.6 against 16.0) and 0.7 m with 16 (20.4 against 21.1). Both match the brief.
- 8 boats: -1.9 and -1.1 m. One set is beyond the gap and one is inside it; both are on the same seeds, paired.
- 16 boats: -2.8 and -0.5 m. That was ambiguous, so all-National 16 was run: -4.9 m on 160 races, beyond any noise. The base reproduces the prototype's main reference of 24.9 exactly.
- Base gate means match the brief's prototype references: 17.6 / 20.4 / Club 15.2 / National-16 24.9 / mixed-10 18.0.
- mix10 and nat16 exit 1 on both trees with the same pre-existing breaches, so there is no regression and no rerun was needed. The runs are deterministic.
  - mix10 breach: club finish share 0.60/0.61 < 0.75.
  - nat16 breaches: navigation finish share, 13 missed-penalty DSQs, encounters to fouls 0.041, and one centred-rudder 16.1 call.

## Fouls and calls (acceptance 5)

Racing fouls are the suite's "racing fouls/encounters" summed over tiers, base -> branch:
- 8 mixed s1-8: 344 -> 364 (+6%)
- 8 mixed s9-16: 354 -> 336 (-5%)
- 16 mixed s1-4: 686 -> 728 (+6%). This is the prototype's warning.
- 16 mixed s5-8: 832 -> 848 (+2%)
- all-Club 8: 600 -> 608
- mixed 10: 1250 -> 1266
- all-National 16: 1612 -> 1560 (-3%)

Paired per-race totals of calls (`paired.txt`, z = diff / paired SE): m8 +10 (z +1.0), m8n -9 (-1.0), m16 +21 (+1.2), m16n +8 (+0.4), club8 +4 (+0.2), mix10 +8 (+0.4), nat16 -26 (-1.0). Every set is inside ±1.2 SE and the signs are mixed.

The 16-mixed +6% does not replicate (+2% on s5-8, -3% on the 160-race National set). Not a finding.

Calls by rule, summed over the 7 diagnose sets, base -> branch:
- 10, 11, 13, 16.1: flat within a few calls a set.
- 12: flat.
- 18.2: 22 -> 30. By set: m8 0->1, m8n 1->0, m16 2->5, m16n 2->5, club8 4->5, mix10 5->8, nat16 8->6. The pooled z is about +1.4, so it is inside noise but leans up; see F3.

Mark touches/boat: within ±0.03 everywhere. Contacts: within 1.6 paired SE in every set.

## Club gradation (acceptance 4; mixed-10, 160 races)

| | base | branch |
|---|---|---|
| mean place C / R / N (by skill) | 6.1 / 4.5 / 3.0 | 6.1 / 4.5 / 3.1 |
| finish share C / R / N | 0.603 / 0.879 / 0.961 | 0.610 / 0.870 / 0.961 |
| club calls (as offender) | 847 | 852 |
| club rule 18.2 | 2 | 3 |

The gradation is unchanged: every finish share is within 0.01. Club calls are flat. Rule 18.2 does not rise beyond counting noise.

all-Club 8:
- Gate gain -1.9 m. Not a breach.
- Finish share 0.887 -> 0.878, inside the ±0.012 / 0.03 rule.
- Calls 722 -> 726.

So the fallback of gating on `gybesOutOfShadow` / `seeksClearAir` is not needed.

## Pick changes

There is no suite output for this, and a trace needs code, so it was not measured. The impl note's trace stands: 17/128 roundings changed pick at 12 s, against 8/128 on main.

There is an indirect, measurable pick effect in the pack scenario. The share of races where the pack used both gate marks rose from 0.70 to 0.93 (default) and from 0.72 to 0.93 (mixed tiers), at z of about +12. H1's traffic term splits the pack. I found no sign of the lag hurting: entry-to-end m and p90 fall in 6 of 7 sets.

## Findings

- **F1 (consistent, not an acceptance gate): rounding deeper below the line.**
  - What moves: deepest m below the gate line rises by +1.5 to +5.2 m in all 7 diagnose sets and in the pack (+1.24 m, z +9). "Still below" (below the line 15 s after the leg's end) roughly doubles everywhere. Examples: 8 mixed 0.9% -> 3.0%, 16 mixed 2.2% -> 5.3%, all-National 16 2.6% -> 6.2%, all-Club 0.6% -> 2.8%, pack 3.5% -> 4.6%. Below-the-line seconds rise by +1 to +2 s.
  - Cost: entry-to-end m and the gate mean still fall, so the deeper exits do not cost metres on the suite's measure.
  - What the test plan said: below-the-line and still-below "should not rise". They rise beyond noise in every set.
  - Cause: not attributed between H1's traffic, H1's shadow gybe and H3. The tester cannot split them without a code edit. The likely source is a pick of the farther or other mark, or a gybe close past a boat that owes room, that swings her wider below the line on the exit.
  - Ask: the orchestrator decides whether to accept it or have the fixer isolate it. Isolate by setting each term to 0 in turn and reading the `deepest m` and `still below` columns on the 8-mixed set.
- **F2 (watch, inside noise): finishers.**
  - By set: m8 -11 (z -1.3), m8n -13 (z -2.3), m16 -17 (-1.7), m16n -15 (-1.3), club8 -6 (-0.7), mix10 +1 (+0.1), nat16 -2 (-0.1).
  - Pooled: -63 boats, about -1.1%, z about -1.9.
  - Only the mixed 8/16 sets lean down. The 160-race sets (mix10, nat16) are flat, and mix10's gradation is unchanged.
  - Not a finding by itself; the orchestrator's bot matrix will show it if it is real.
- **F3 (watch, inside noise): rule 18.2.**
  - Diagnose sets: 22 -> 30.
  - Pack: 4 -> 6 (default) and 15 -> 20 (mixed).
  - Small counts. H3 counts 18.3 notices as the brief accepts (open choice 3). Revisit if the matrix shows it.
- **Cost:** wall time per sweep is +2% to +15% on the branch. These are noisy single runs and the wake reads in `gateTrafficMetres` are new per-tick work. BotBenchmarkTests was not run (optional).

## Not run

- Bot matrix: the orchestrator runs it.
- Golden / Linux and the RegattaBots digest rows: CI.
- UI tests: CI.
- `check.sh --all`: no snapshot or wire change.
- BotBenchmarkTests: optional, skipped.

## Repro

```
S=<scratchpad>/525-1   # base-botsuite, branch-botsuite, run.sh, matrix-s9-16.json, matrix-s5-8.json (copies in .brief/525-1-results)
bash $S/run.sh <base|branch> pack      --scenario pack
bash $S/run.sh <base|branch> packmixed --scenario pack --tier-mix mixed
bash $S/run.sh <base|branch> pack6     --scenario pack --fleet-size 6
bash $S/run.sh <base|branch> m8    --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 8 --seeds 8
bash $S/run.sh <base|branch> m8n   --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 8 --matrix $S/matrix-s9-16.json
bash $S/run.sh <base|branch> m16   --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 16 --seeds 4
bash $S/run.sh <base|branch> m16n  --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 16 --matrix $S/matrix-s5-8.json
bash $S/run.sh <base|branch> club8 --profile-mix live --laps 2 --diagnose --tier-mix club --fleet-size 8 --seeds 8
bash $S/run.sh <base|branch> mix10 --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 10 --seeds 16
bash $S/run.sh <base|branch> nat16 --profile-mix live --laps 2 --diagnose --tier-mix national --fleet-size 16 --seeds 16
python3 packcmp.py $S pack            # paired, halves, group rows
python3 sweepcmp.py $S m8 m8n m16 m16n club8 mix10 nat16
python3 paired.py $S m8 m8n m16 m16n club8 mix10 nat16
```
(`run.sh` wraps `scripts/heavy.sh <bin> ... --json`.)

## check.sh

`scripts/check.sh` at 7c855ff7 (the tree is clean apart from `.brief/`): **all passed**, exit 0. The log is `.brief/525-1-results/check.log`.
- Builds: RegattaCore, Protocol, Client, Services, Server and the app tests.
- RegattaCore test: 1000 tests in 150 suites, 381 s. That includes the re-pinned `skiffEightBotsAreBitIdentical` digest and the new BotGateTests and BotMarkRoomTapTests.
- One known issue was recorded, and it predates this branch: #477 `nationalFleetsStartCleanAndOnTime`, on-time 0.458. It sits behind an intermittent `withKnownIssue`, and the branch does not touch that file.
