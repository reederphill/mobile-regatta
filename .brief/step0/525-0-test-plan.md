# Test plan: #525 step 0 (pack scenario, harness only)

Rev under test: 041d0c17 (origin/main = dea7e5c8 = merge base; fetched, did not move, nothing to merge).
Diff: Command.swift (+77, insertions only), new PackScenario.swift, new PackScenarioTests.swift, docs/agents/validation.md (+1). No deletions in existing files.

## What could break
1. Plain (no --scenario) runs change: parser/usage edits, `run` branching. Also --diagnose runs.
2. Existing suites broken by option struct growth (BotSuiteCommandTests, usage text expectations).
3. The new scenario: nondeterminism, bad placement, wrong report shape, bad-usage exit codes.
4. Build breakage across packages (check.sh compiles what is reached).

## Checks
- (a) scripts/check.sh once on final code (foreground, 600 s timeout): compiles everything reached, runs BotSuiteTests incl. PackScenarioTests and the existing command tests. Recorded with `check.sh --status --rev HEAD`.
- (b) Byte-identical: release regatta-botsuite at origin/main and HEAD; `--profile-mix live --tier-mix national --fleet-size 5 --seeds 2 --laps 2 --json` plain and with `--diagnose`; diff with timing fields (`timings`, `races[].timings`, tick: lines) stripped. Plus `--help` diff (expected: only new flags).
- (c) Baseline sweep: default `--scenario pack` (576 races), release, timed, table + JSON saved to .brief/525-0-baseline.{txt,json}. Sanity: exit 0, 0 capped?, pack held share high, rows per group present.
- Extra cheap spot checks: bad-usage exit codes by hand (`--scenario nope`, pack + --matrix etc.), `--jobs 1` vs `--jobs 4` JSON equality on a 1-seed run.
- Failures: rerun once, then compare against main (main has no --scenario, so only plain-run failures are comparable).

## Deliberately skipped
- Bot matrix, bot-matrix.sh, golden/Linux run, RegattaBots digests, UI tests, render references: no core/bot/harness source changed (verified by git diff --stat).
- check.sh --all (downstream packages): no WorldSnapshot/wire change.
- Postgres tests: unrelated.
- Pace probe: no per-tick sim work added.
