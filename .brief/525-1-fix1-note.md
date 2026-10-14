# #525 step 1 fix round 1 (F1: deeper gate roundings)

Merged origin/main first (b6437494; only the orchestration log came in, no conflict).

## Verdict: not converged. Committed the owner's fallback guard, which is neutral on F1.

## Cause (localised)
8-mixed `--diagnose` seeds 1-8 (`--profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 8 --seeds 8`), gate row, all tiers.
Temporary env toggles in one build, since removed.

| variant | gate mean m | below s | deepest m | deepest p90 | still below |
|---|---|---|---|---|---|
| base (tester) | 17.6 | 7.7 | 8.3 | 10.9 | 6 (0.9%) |
| branch 7c855ff7 | 15.7 | 8.8 | 11.0 | 23.4 | 19 (3.0%) |
| traffic term off | 17.7 | 7.6 | 8.3 | 10.2 | 5 (0.8%) |
| shadow gybe off | 15.7 | 8.8 | 11.0 | 22.8 | 20 (3.1%) |
| H3 off | 15.7 | 8.8 | 11.1 | 22.8 | 19 (3.0%) |
| traffic: boat term 0 (wake term kept) | 17.7 | 7.6 | 8.3 | 10.3 | 4 (0.6%) |
| traffic: wake term 0 (boat term kept) | 15.8 | 8.8 | 11.0 | 22.8 | 19 (3.0%) |

- The shadow gybe and H3 are neutral. The traffic term's boat part is the whole of F1, and also the whole of the gate gain.
- Pack scenario, the tester's base and branch JSONs, paired per boat:
  - Boats that keep the same mark as on base: deepest 9.1 -> 8.9 and 9.3 -> 9.1; still below 44 -> 39 and 40 -> 39 (no change).
  - Boats the traffic sends to the other mark (616 of 2873): deepest 10.2 -> 15.3 (left) and 9.7 -> 17.7 (right); still below 12 -> 35 and 9 -> 26.
  - So it is the mark switch itself, not when it happens. The owner's late-flip hypothesis does not fit:
    - Freezing the traffic inside 30 or 50 m of the held mark is neutral (rows below).
    - A full pick freeze inside 30 m makes F1 slightly worse.
  - Gybes within 30 m of the line were not counted; no suite output has it.

## Fix variants (time box used: ~45 min, 3 variants)
| variant | gate mean | below s | deepest | p90 | still below |
|---|---|---|---|---|---|
| A traffic frozen inside 30 m of the held mark (= committed) | 15.7 | 8.8 | 11.0 | 21.9 | 19 (3.0%) |
| A' same, 50 m | 15.2 | 8.8 | 11.0 | 21.7 | 21 (3.3%) |
| B pick frozen outright inside `gateStraightRange` | 14.8 | 9.1 | 11.5 | 23.8 | 22 (3.5%) |
| C traffic may not move her pick to a mark she must gybe for | 18.3 | 7.7 | 8.2 | 10.2 | 4 (0.6%) |

- C removes F1 and removes the gain with it (18.3 against base 17.6). The gain *is* the switch to the mark across, on the other gybe, and that switch is what carries her deep.
- A real fix has to make the switched boat's approach or rounding of the far mark clean. That is the other-gybe approach in `gateAim`'s else branch, the layline to the far mark close to the line, and/or the exit off it. It is a rounding change, not a pick change. Not attempted in this round.

## What changed (committed)
- `BotBrain+Gate.swift` `gateAim`: inside `gateStraightRange` of the mark she holds, she prices the traffic she last priced (`gateTraffic` is not updated), so traffic cannot flip the pick there. Cost-driven repicks are as on main.
  - No new constant: it reuses `gateStraightRange`.
  - Variant A, not B: B (freeze the pick outright) changes main's own repick inside 30 m and measured worse. A is "traffic can't flip it there" literally.
- `BotGateTests.trafficDoesNotFlipHerPickCloseIn`: she holds a mark within 30 m on the costs; a boat parked on her line makes it dearer than the other by more than `gateRepickMetres`; the pick holds. It was red without the guard and is green with it.
- The skiff long digest did not move: `BotHandTackTests` passes unchanged.

## Tests run
`swift test -Xswiftc -O --filter "BotGateTests|BotMarkRoomTapTests|BotHandTackTests"`: 32 tests, all pass. The new test failed first.

## Tester must re-test
- F1 stands; it is unchanged by this commit. The orchestrator decides between three options:
  - accept F1;
  - ship C (no gain);
  - a round 2 on the far-mark approach and rounding.
- If this commit is kept: rerun the 8-mixed set (expect the row A numbers above) and the pack scenario. Expect it within noise of 7c855ff7.
- Raw outputs: `.brief/525-1-fix1/m8-*.txt`.
