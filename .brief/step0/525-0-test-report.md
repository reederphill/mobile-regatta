# Test report: #525 step 0 (pack scenario) at 041d0c17

Verdict: PASS. No regressions, no failures to rerun.

origin/main (dea7e5c8) did not move; it is the merge base, nothing merged.
Diff: Command.swift +77, PackScenario.swift +623, PackScenarioTests.swift +291, validation.md +1; zero deletions, no core/bots/existing-harness files.

## (a) scripts/check.sh (recorded, foreground-started, finished in background, one run)
`check.sh: all passed`, 14m41s wall. Builds RegattaCore/Protocol/Client/Services/Server/app tests PASS; test RegattaCore PASS (355 s), 994 tests.
`scripts/check.sh --status --rev 041d0c17`: all passed (tree 3815da42..., record 2577b3d3....tests). All 14 PackScenarioTests are in the record (list below), plus the existing BotSuite tests.
Log: .brief/525-0-check.log. Downstream package tests are CI's (not --all; no snapshot/wire change).

PackScenarioTests passed: aBoatIsInAPackWithTwoOthersWithin20Metres, aSailedRunExitsZero, anImpossibleBunchThrows, badUsageExitsTwo, boatsAreBunchedAboveTheGate(size:), columnsPoolTheBoatsAndRaces, currentIsInTheWithRacesAlone, entryIsWithin80MetresAndAboveTheGate, offsetsLieOverTheirMarks, reportHasTheColumnsAndOneRowPerGroup, sameOptionsSailTheSameRaces, theBunchIsSeeded, theBunchRoundsTheGate, withoutAScenarioNothingChanges.

## (b) Byte-identical without --scenario
Release regatta-botsuite built at origin/main (detached worktree in scratchpad, own scratch path, deleted afterwards; disk 8.1 GB free) and at HEAD.
Args: `--profile-mix live --tier-mix national --fleet-size 5 --seeds 2 --laps 2 --json <f>` plain, and the same with `--diagnose`.
- Plain: JSON identical after dropping every `timings` key; text output identical but the `tick:` line (wall-clock).
- --diagnose: same, identical.
- Both builds exit 1 (gate: FAIL, the same on main), same text.
- `--help`: 0 lines removed, 9 added (the --scenario and --pack-* flags); exit 0 both.
Reproduce: build both, then `regatta-botsuite --profile-mix live --tier-mix national --fleet-size 5 --seeds 2 --laps 2 [--diagnose] --json out.json`, strip `timings` (python: recursive drop of key), diff.

## Extra spot checks (HEAD release binary)
- Exit 2: `--scenario nope`; `--scenario pack` with `--matrix x.json`, `--thresholds x`, `--profile-mix live`, `--laps 2`, `--diagnose`; `--pack-current with` without `--scenario`.
- `--scenario pack --seeds 1 --jobs 1` vs `--jobs 4`: exit 0, text identical, JSON identical minus timings, 0 capped. JSON keys: above, races, rows, scenario.

## (c) Baseline sweep (main's bots), release
`scripts/heavy.sh regatta-botsuite --scenario pack --json .brief/525-0-baseline.json > .brief/525-0-baseline.txt`
Exit 0, wall 35.8 s (real; 140 s user; default jobs), 576 races, 2880 boats, 0 capped.
Headline (all): pack held 0.84; both marks used 0.70; boats on the less-used mark 1.09 a race; gate done 1.00; extra m mean 33.5 / median 19.8 / p90 88.4; extra s mean 22.2; pack extra m 108.5 a race; contacts 0.94, touches 0.05, calls 0.67 a race (10: 0.24, 11: 0.07, 13: 0.06, 16.1: 0.09, 21.2: 0.18); below the line mean 11.5 s / p90 20.5 s; deepest 9.4 m mean / p90 17.4; overshoot 0.06; still below 0.04; dirty air 5.51 s a boat.
Groups: with current 0.80 held, extra m 32.6; without 0.88, 34.3. Size 4 / 5 / 6: held 0.69 / 0.90 / 0.93, both marks 0.55 / 0.73 / 0.81, extra m 27.5 / 34.1 / 36.9, calls 0.31 / 0.70 / 1.00 a race. Offset -6 / 0 / 6: both marks 0.64 / 0.87 / 0.58. Gybes same / mixed: calls 0.50 / 0.84, rule 10 0.08 / 0.39.

## Findings (none blocking)
1. Pack held at entry is 0.84 over 576 races (the implementer's 1-seed smoke said 0.97); size 4 holds only 0.69. The placement guarantees a pack at placement, not at entry; the 100 m of sailing disperses small bunches. Worth saying in the PR body so size 4 is read as a weaker test of packs. Not a defect against the acceptance (4: report the share).
2. `boats on the less-used mark` is a mean count a race (1.09 overall), so it reads as a count, not a share; the column header could say so. Cosmetic.
3. Plain runs exit 1 on gate FAIL on main too (placeholder thresholds), unrelated.
Nothing run: bot matrix, golden/Linux, RegattaBots digests, UI tests, check.sh --all (reasons in the plan).
