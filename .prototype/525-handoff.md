# #525 handoff (agent 2 finished steps 1-4; the deliverable is written)

Worktree `/Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525`, branch `prototype/525-gate-planner`. Brief `.prototype/525-brief.md`; **deliverable `.prototype/525-findings.md` (done)**. Nothing merges, no PR, no GitHub posts.

## Done
1. P's line-crossing regression: cause = the first planner flip-flops on jittery scores and its roll-out does not model what `gateAim`/`navigate` sail (gybe tap interval, mark clearance); fixed by variant `m` (anchor to main's own pick, override only if a candidate beats it by REGATTA_PLAN_ANCHOR=25 m, else main's code runs: bit-identical). `f` (roll-out fidelity) was worse. Residue parked: still-below 110 against 67 (National 16), cause not proven.
2. Pack hunt: `dev-venue@7:sea-breeze@7:12:16` (all-National 16): main wrecks two boats, Pm does not; the population says packs split 8 -> 44 and the packs' metres do not fall; no sustained gap-shot found (it is in the findings).
3. Step (e): main / H / Pm / PmH at 8 (s1-8, s9-16), 16 (s1-4, s5-8), club 8, National 16 x160, mixed 10 x160; Pmb (blind) attribution; Q3 (FD), Q4 (PlannerCostTests, `results/q4.md`), Q5.
4. Step (f): `.prototype/525-findings.md` (verdict: pack scenario first; planner conditional go; H1+H3 go, H2 no-go; both no).

## If anyone continues
- Nothing required. Optional: no overrides inside 30 m / the tap interval in the roll-out for the still-below residue (a 4th variant, outside the time box), a skip gate for cost, per-tier inside-candidate counts.
- The no-letter run is byte-identical to `.prototype/results/main-clean-8.txt` (except the `tick:` line); re-check after any code change: `.prototype/run.sh chk "" --tier-mix mixed --fleet-size 8 --seeds 8`, then diff without `tick:`.
- Gotchas: zsh does not word-split variables (`${=S}`); a foreground Bash call over 120 s needs `timeout: 600000` or it moves to the background (wait with `scripts/heavy.sh true`, which blocks on the lock); `.err` files of GATE_TRACE runs are big (never commit a whole-sweep trace); macOS `sed -i ''`.
