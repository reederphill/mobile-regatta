# Test plan: #525 step 1 (H1 + H3) at 7c855ff7

Merge: origin/main = dea7e5c8 and origin/build/525-0-pack-scenario = 041d0c17 did not move; PR #526 still open. Nothing to merge.
Base = 041d0c17 (step 0 tip; bots code = main's). Base binary: the release binary already built in .claude/worktrees/t525-0 at 041d0c17, copied to the scratchpad (no extra build, saves ~1 GB). It is verified as the base by reproducing 525-0-baseline.json (races identical minus timings) before use.
Branch binary: release regatta-botsuite built here (scratch .build/check/RegattaCore).
Disk: 7.6 GB free at start; keep above 4 GB.

## What could break
- H1 traffic: pick flip-flops (impl note: 17/128 roundings changed pick vs 8 on main), lag keeping a mark dear; Club gradation; more fouls at the gate (more boats choosing the same side / gybing into traffic).
- H1 shadow gybe: extra gybes, worse approach, 16-boat fouls.
- H3: 0.6 tap clearance, more contacts / rule 18.2/ 18.3 / 10 / 11 calls, mark-room fouls.
- Benefit: gate extra m should fall; pack extra m, below-the-line, still below should not rise.

## Runs (one heavy job at a time, all via scripts/heavy.sh, foreground, timeout 600000)
Order: build branch; verify base binary; then
(a) pack scenario, base vs branch: default; --tier-mix mixed; --fleet-size 6 (JSON each; noise = split races by seed 1-8 vs 9-16 and per-race-pair spread; plus group rows)
(b) --diagnose sweeps base vs branch (live, laps 2): 8 mixed seeds 8; 16 mixed seeds 4; all-Club 8 seeds 8; mixed-10 seeds 16. Noise: matrix copies with seeds [9..16] (8 boats) and [5..8] (16 boats), run on base and branch; noise gap = |main(seeds1-8) - main(seeds 9-16)| per brief's convention (and branch-vs-base on the second set as replication).
    Also all-National 16 (seeds 16) only if time allows and the 16-mixed result is ambiguous.
(c) from the same --diagnose outputs: fouls and calls by rule (16-boat), Club gradation (mixed-10 mean place C/R/N, finish shares), pick-change count (not a suite output: read from the impl note's method / `gate` rows; if no tool in the suite, state that and use a short test-side trace only if it needs no code edits; otherwise report not measured and rely on the impl-note trace + pack gate rows).
(d) scripts/check.sh once on the final code (recorded gate; skiff digest re-pin passes inside it).
Not run: bot matrix (orchestrator), Golden/Linux (CI), UI tests (CI), check.sh --all (no snapshot/wire change).
Optional: BotBenchmarkTests filtered once, branch vs base, if time/disk allow (cost of the new traffic wake reads).

## Judgement rules
- Noise: 8-boat gate mean 1.6 m, 16-boat 0.7 m (brief); pack: seed halves. A move inside noise is not a finding.
- Failure => rerun once, check on base. Regression only if the change causes it.
- "No new fouls" and "Club gradation unchanged" judged against noise (seed-half spread and the replication sets).
