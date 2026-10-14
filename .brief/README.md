<!-- machine-generated: for agents, not human readers -->
# #525 steps 0–1: research and working notes (paused 2026-10-14 by the owner)

Not for merge: drop `.brief/` from any PR built from this branch.

- `step0/`: step 0 (pack scenario, merged as #526): brief, implementation note, test plan/report, baseline table (`525-0-baseline.txt`), check log.
- `525-1-brief.md`, `525-1-impl-note.md`: step 1 (hand fixes H1 + H3).
- `525-1-test-plan.md`, `525-1-test-report.md` (+ `525-1-results/`): first test; finding F1 (deeper below the line).
- `525-1-fix1-note.md` (+ `525-1-fix1/`): round 1, F1 localised to the boat part of the traffic term (switch to the far mark); guard A no effect.
- `525-1-fix2-note.md` (+ `525-1-fix2/`): round 2, `gateSetUp` + by-the-lee aim (commit 7814c4b0).
- `525-1-test-report-2.md` (+ `525-1-results-2/`): re-test after round 2, pass on means; the 11 still-below roundings. Its near/far proxy rows are swapped (fix3 note).
- `525-1-fix3-note.md` (+ `525-1-fix3/`, `tails.sh`, `TmpGateTrace.swift.keep`): round 3, deep-tail table, modes A–D, sailed far-mark test (commit 2e5d4d55, known issue).
- `525-1-fix4-note.md` (+ `525-1-fix4/`, `v3.patch`): round 4, v3 (applied as the WIP commit after this one); two single-boat misses.

Raw `--json` outputs over 1 MB (27 files, ~70 MB) are not committed. Regenerate them with the commands in the test reports and `tails.sh`. To measure tails, copy `TmpGateTrace.swift.keep` into `Packages/RegattaCore/Tests/BotSuiteTests/TmpGateTrace.swift` and run `525-1-fix3/tails.sh`.
