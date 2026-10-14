# Test report 2: #525 step 1 after fix round 2, HEAD 7814c4b0

## Verdict

**PASS. No regressions.** The fix round 2 (`gateSetUp`, by-the-lee aim, guard A removed) closes round 1's F1. Deepest, deepest p90 and below-the-line return to base in every set. The gate gain mostly holds.

- **Gate mean:** falls against base in all 7 diagnose sets (-0.7 to -4.8 m) and in the pack.
- **Deepest, deepest p90 and below s:** back to base within about 1 m, against round 1's +2 to +5 m (p90 +8 to +19 m).
- **Still below:**
  - Pooled over the 7 sets: 138 on base, 131 on HEAD, 324 on round 1.
  - It is at or under base in 5 sets. In 2 sets it is above base, both 8-boat sets with Club boats; see W1.
- **Fouls and calls:** inside noise in every set.
  - Round 2 adds no rule 11 or 12. Pooled from r1 to HEAD: rule 11 1906 -> 1908, rule 12 228 -> 229.
  - Rule 18.2 drifts up across both rounds (22 -> 30 -> 38, pooled z +2.3 against base); see W2.
- **Club gradation:** unchanged.
- **Finishers:** round 1's F2 is gone. Pooled finishers are +26 against base.
- **Pack extra metres:**
  - default -6.1 m (z -2.2)
  - size 6 -12.3 m (z -2.6)
  - mixed tiers flat (+0.4, z +0.2); see W3
- **check.sh:** all passed at 7814c4b0, exit 0. That includes `skiffEightBotsAreBitIdentical` with the re-pinned 0x1983f405f32e8e8f.

## Setup

- **Merge:** origin/main is 25238c7a, already an ancestor of HEAD, so there was nothing to merge.
- **Base:** main 6fc061d2. `git diff 041d0c17..6fc061d2 -- Packages` is empty.
- **Base binary:** round 1's `scratchpad/525-1/base-botsuite`, re-verified three ways:
  - `--scenario pack` reproduces round 1's pack-base.json: 576/576 races identical.
  - Re-running m8 and nat16 reproduces round 1's base JSONs: 80/80 and 160/160 races, with identical breaches and identical rounding rows.
- **HEAD binary:**
  - The release `regatta-botsuite` in `.build/check/RegattaCore`. The rebuild at 7814c4b0 was a relink only, no extra build.
  - sha1 81c293dd. It is copied to `scratchpad/525-1r2/head-botsuite`.
- **Round 1 numbers ("r1", 7c855ff7):** round 1's `-branch` outputs, read again with the same scripts.
- **Consistency check:** HEAD's m8 row equals the fixer's v4 row exactly: 15.0 / 7.6 / 8.6 / 11.2 / 11.
- **Disk:** 5.2 GB free throughout.
- **Outputs:** in `.brief/525-1-results-2/`:
  - `out/` holds the HEAD outputs.
  - The scripts are `gaterows.py`, `threeway.py`, `paired_kept.py` and `run.sh`. Round 1's `packcmp.py` and `sweepcmp.py` were reused.
  - Each script's `.out` file is saved beside it.
  - `check.log` is the check.sh log.
  - `still-below/` holds the per-race runs.

## Diagnose sweeps (live, laps 2): gate row, base / r1 / HEAD

The gate row is "all" tiers; club8 uses its club row and nat16 its national row.

| set | gate mean m | deepest m | deepest p90 m | below s | still below | overshoot | entry-to-end m |
|---|---|---|---|---|---|---|---|
| 8 mixed s1-8 | 17.6 / 15.7 / **15.0** | 8.3 / 11.0 / **8.6** | 10.9 / 23.4 / **11.2** | 7.7 / 8.8 / **7.6** | 6 (0.9%) / 19 (3.0%) / **11 (1.7%)** | 12 / 5 / 4 | 19.9 / 17.8 / 17.8 |
| 8 mixed s9-16 | 16.0 / 14.9 / **15.3** | 8.1 / 9.9 / **8.4** | 10.3 / 19.6 / **11.1** | 7.4 / 8.5 / **7.9** | 7 (1.1%) / 14 (2.2%) / **8 (1.3%)** | 8 / 9 / 9 | 18.3 / 17.1 / 17.8 |
| 16 mixed s1-4 | 20.4 / 17.6 / **17.5** | 8.5 / 12.7 / **9.4** | 12.9 / 28.7 / **16.5** | 8.6 / 10.8 / **9.0** | 14 (2.2%) / 34 (5.3%) / **12 (1.9%)** | 19 / 12 / 11 | 23.1 / 19.7 / 20.5 |
| 16 mixed s5-8 | 21.1 / 20.6 / **17.8** | 8.7 / 11.0 / **8.7** | 14.9 / 22.1 / **13.5** | 9.3 / 10.7 / **9.0** | 17 (2.7%) / 29 (4.6%) / **12 (1.9%)** | 14 / 22 / 10 | 23.8 / 22.9 / 21.0 |
| all-Club 8 | 15.2 / 13.3 / **13.0** | 8.0 / 9.5 / **8.2** | 10.3 / 18.1 / **10.4** | 7.9 / 8.7 / **7.6** | 4 (0.6%) / 18 (2.8%) / **11 (1.7%)** | 7 / 4 / 4 | 18.6 / 16.5 / 16.5 |
| mixed 10 | 18.0 / 16.7 / **16.6** | 8.6 / 10.9 / **8.6** | 12.9 / 23.6 / **12.5** | 8.3 / 9.5 / **8.4** | 23 (1.4%) / 51 (3.2%) / **23 (1.4%)** | 37 / 24 / 27 | 20.5 / 19.0 / 19.3 |
| all-National 16 | 24.9 / 20.0 / **20.1** | 9.4 / 14.6 / **10.3** | 17.0 / 36.3 / **19.6** | 9.7 / 11.8 / **9.9** | 67 (2.6%) / 159 (6.2%) / **54 (2.1%)** | 109 / 78 / 88 | 25.9 / 21.0 / 22.5 |

Gain against noise (the noise gap is 1.6 m with 8 boats and 0.7 m with 16):
- 8 boats: -2.6 and -0.7 m.
- 16 boats: -2.9 and -3.3 m.
- all-National 16: -4.8 m over 160 races.
- all-Club 8: -2.2 m.
- mixed 10: -1.4 m.

Against round 1, HEAD keeps the gain on 6 of the 7 sets; 8-mixed s9-16 is the exception (-0.7 against r1's -1.1, inside noise). On 16-mixed s5-8 it gains more than round 1 did (-3.3 against -0.5). Overshoot is at or below base in every set except 8-mixed s9-16 (8 -> 9).

The deepest p90 on HEAD is near base. It is above base by more than 1 m in two sets: 16-mixed s1-4 (12.9 -> 16.5) and all-National 16 (17.0 -> 19.6). In both, the mean deepest is +0.9 m and still below is under base.

## Fouls and calls, base / r1 / HEAD

Racing fouls are the suite's "racing x/y" encounters ending in fouls, summed over the tiers. The calls are all calls. z is the paired per-race z, HEAD against base.

| set | finishers (H-b, z) | racing fouls | calls (z) | contacts (z) | rule 10 | rule 11 | rule 12 | rule 18.2 |
|---|---|---|---|---|---|---|---|---|
| m8 | 545 / 534 / 544 (-1, -0.1) | 344 / 364 / 362 | 495 / 505 / 504 (+0.8) | 642 / 649 / 659 (+1.0) | 171 / 166 / 168 | 169 / 176 / 176 | 21 / 22 / 21 | 0 / 1 / 1 |
| m8n | 533 / 520 / 528 (-5, -0.7) | 354 / 336 / 360 | 477 / 468 / 480 (+0.3) | 708 / 698 / 701 (-0.4) | 164 / 162 / 167 | 188 / 191 / 186 | 20 / 17 / 17 | 1 / 0 / 1 |
| m16 | 434 / 417 / 436 (+2, +0.2) | 686 / 728 / 728 | 631 / 652 / 652 (+1.3) | 824 / 842 / 829 (+0.3) | 256 / 261 / 253 | 171 / 178 / 186 | 27 / 31 / 29 | 2 / 5 / 5 |
| m16n | 389 / 374 / 400 (+11, +0.9) | 832 / 848 / 818 | 779 / 787 / 772 (-0.4) | 1048 / 1052 / 1045 (-0.1) | 322 / 313 / 301 | 241 / 250 / 251 | 22 / 20 / 24 | 2 / 5 / 6 |
| club8 | 568 / 562 / 563 (-5, -0.6) | 600 / 608 / 610 | 722 / 726 / 727 (+0.3) | 1048 / 1048 / 1044 (-0.2) | 285 / 290 / 282 | 242 / 244 / 250 | 42 / 41 / 39 | 4 / 5 / 5 |
| mix10 | 1241 / 1242 / 1247 (+6, +0.4) | 1250 / 1266 / 1202 | 1355 / 1363 / 1331 (-1.2) | 1857 / 1882 / 1824 (-1.3) | 490 / 498 / 474 | 434 / 441 / 439 | 82 / 74 / 75 | 5 / 8 / 9 |
| nat16 | 2179 / 2177 / 2197 (+18, +0.9) | 1612 / 1560 / 1544 | 1462 / 1436 / 1428 (-1.3) | 1857 / 1803 / 1803 (-1.5) | 475 / 469 / 470 | 419 / 426 / 420 | 22 / 23 / 24 | 8 / 6 / 11 |

Pooled over the 7 sets, paired per race:

| rule | base -> r1 (z) | r1 -> HEAD (z) | base -> HEAD (z) |
|---|---|---|---|
| 10 | 2163 -> 2159 (-0.1) | 2159 -> 2115 (-1.6) | -48 (-1.6) |
| 11 | 1864 -> 1906 (+1.9) | 1906 -> 1908 (+0.1) | +44, +2.4% (+2.1) |
| 12 | 236 -> 228 (-1.0) | 228 -> 229 (+0.1) | -7 (-0.8) |
| 18.2 | 22 -> 30 (+1.4) | 30 -> 38 (+1.2) | +16 (+2.3) |

Rule 18.2 by offender tier:

| tier | base | r1 | HEAD |
|---|---|---|---|
| Club | 10 | 17 | 18 |
| Regional | 4 | 5 | 6 |
| National | 8 | 8 | 14 |

- **Calls and contacts:** inside ±1.5 paired SE in every set, with mixed signs.
- **Racing fouls:** none rise beyond round 1's spread. 16-mixed s1-4 is +6% on both r1 and HEAD, but 16-mixed s5-8 is -2% and nat16 -4%.
- **Rule 11 and 12, the owner's worry about the reach across:** round 2 adds nothing (r1 -> HEAD +2 and +1 pooled). The pooled rule 11 rise against base (+2.4%) is round 1's, and round 1 reported it as flat per set.
- **Rule 18.2:** see W2.
- **Breaches:** all pre-existing on base, which was re-run for m8 and nat16 and is deterministic:
  - Every set: `club: finish share < 0.75`. club8 passes on all three trees.
  - nat16, also on base: finish share 0.858 (base 0.851), encounters to fouls 0.041, one centred-rudder 16.1 call, and missed-penalty DSQs 13 -> 16 (the same breach as base, 13 on base). No new breach.
- **Tick time:** the m16 HEAD run logged a tick max of 84.6 ms against a budget of 5 ms; base logged 8.7 ms. It is a single wall-clock spike under load and not a gate breach. Its p99 was 0.67 ms.

## Club gradation (mixed 10, 160 races)

| | base | r1 | HEAD |
|---|---|---|---|
| mean place C / R / N (by skill) | 6.1 / 4.5 / 3.0 | 6.1 / 4.5 / 3.1 | 6.2 / 4.5 / 3.0 |
| finish share C / R / N | 0.603 / 0.879 / 0.961 | 0.610 / 0.870 / 0.961 | 0.608 / 0.877 / 0.968 |
| club calls by club boats (as offender) | 847 | 852 | 831 |

All-Club 8: finish share 0.887 / 0.878 / 0.880, and calls 722 / 726 / 727. Unchanged.

## Finishers (round 1's F2)

HEAD minus base by set, with the paired z: m8 -1 (-0.1), m8n -5 (-0.7), m16 +2, m16n +11, club8 -5 (-0.6), mix10 +6, nat16 +18. The pooled total is **+26**; round 1's was -63. F2 is closed.

## Pack scenario: base / r1 / HEAD, "all" row

| run | extra m | pack extra m | both marks | deepest m | deepest p90 | below s | still below |
|---|---|---|---|---|---|---|---|
| default (576) | 33.5 / 30.3 / **30.5** | 108.5 / 100.6 / **102.3** | 0.70 / 0.93 / 0.89 | 9.36 / 10.61 / **8.74** | 17.4 / 22.4 / **15.7** | 11.5 / 11.9 / **11.1** | 0.04 / 0.05 / **0.03** |
| mixed tiers (576) | 31.8 / 30.2 / **30.1** | 100.8 / 99.1 / **100.9** | 0.72 / 0.93 / 0.92 | 8.91 / 9.85 / **8.47** | 16.2 / 19.3 / **14.5** | 11.3 / 11.7 / **11.3** | 0.04 / 0.05 / **0.04** |
| size 6 (192) | 37.0 / 33.2 / **33.2** | 143.1 / 129.7 / **131.5** | 0.81 / 0.99 / 0.98 | 9.26 / 10.79 / **8.73** | 17.4 / 22.6 / **16.0** | 11.9 / 12.2 / **11.3** | 0.04 / 0.06 / **0.04** |

Paired per race, HEAD minus base, with the seed halves (`packcmp-*.out`):

| run | extra m | pack extra m | deepest m | still below |
|---|---|---|---|---|
| default | -3.0 (z -4.4; halves -2.0 / -3.9) | -6.1 (z -2.2; halves -4.5 / -7.6) | -0.61 (z -5.2) | -0.007 (z -2.0) |
| mixed tiers | -1.5 (z -2.4) | +0.4 (z +0.2; halves +2.9 / -2.0) | -0.39 (z -3.3) | -0.002 |
| size 6 | -3.8 (z -3.6) | -12.3 (z -2.6) | -0.54 (z -2.8) | -0.004 |

## Owner additions

### 1. The 11 still-below roundings on 8-mixed seeds 1-8 (base 6)

**What the suite gives:** `--diagnose` writes only pooled gate rows, in both the text and the JSON (`diagnose.roundings` holds aggregates; `races[].seats[]` has no rounding fields). It gives no seat, no mark, no near or far, no per-boat deepest, and no leg-entry gybe.

**How they were found:** each race was re-run alone, one matrix per (venue, conditions, seed). The per-race counts sum to the sweep's exactly: 11 on HEAD and 6 on base. The tier comes from the race's per-tier gate row, where exactly one tier has the still-below boat.

"Tier deepest" is the p90 deepest column of that tier's gate row in that race. With 2 to 5 roundings it is the tier's deepest rounding, so very likely hers.

| # | venue | conditions | seed | tier | tier deepest m | on base? |
|---|---|---|---|---|---|---|
| 1 | dev-venue@7 | light-and-patchy@7 | 1 | regional | 17.2 | new |
| 2 | dev-venue@7 | light-and-patchy@7 | 2 | club | 17.7 | new |
| 3 | fellmere@1 | light-and-patchy@7 | 1 | club | 17.9 | new |
| 4 | fellmere@1 | light-and-patchy@7 | 5 | club | 11.6 (base 13.9) | also on base |
| 5 | hollin-bay@1 | classic-oscillating@7 | 8 | national | 19.6 (base 19.6) | also on base |
| 6 | hollin-bay@1 | sea-breeze@7 | 4 | club | 29.3 | new |
| 7 | saltings-reach@1 | classic-oscillating@7 | 3 | club | 18.4 | new |
| 8 | saltings-reach@1 | gusty-offshore@7 | 3 | regional | 56.3 | new |
| 9 | saltings-reach@1 | gusty-offshore@7 | 4 | club | 57.8 | new |
| 10 | saltings-reach@1 | gusty-offshore@7 | 5 | national | 43.6 (base 43.6) | also on base |
| 11 | saltings-reach@1 | gusty-offshore@7 | 8 | national | 80.0 | new |

Base's 3 that HEAD no longer has:
- dev-venue gusty-offshore s8, national, 45.1 m
- fellmere gusty-offshore s2, club, 15.7 m
- saltings-reach gusty-offshore s1, regional, 9.2 m

So there are 8 new and 3 gone. 6 of the 11 are Club, against 2 of 6 on base. Four are in saltings-reach gusty-offshore, the venue with current; three of those (#8, #9, #11) are deep, at 56, 58 and 80 m.

**Missing, for a tracer:** seat, the mark she rounded, near or far, her own deepest, and the leg-entry gybe. Each race above is one cell (`--profile-mix live --laps 2 --tier-mix mixed --fleet-size 8`, matrix in `still-below/cells.py`) and is deterministic, so a per-second trace can sail it directly. Start with #11, #9 and #8.

### 2. Pack: rule 18.2, contacts and calls a race, base / r1 / HEAD

Paired z is HEAD against base.

| run | contacts/race | calls/race | 18.2 calls (per race) | 11 calls | 12 calls | 10/race |
|---|---|---|---|---|---|---|
| default | 0.936 / 0.927 / 0.939 (z +0.1) | 0.672 / 0.661 / 0.661 (z -0.5) | 4 / 6 / **2** (0.007 / 0.010 / 0.003) | 41 / 40 / 42 | 2 / 5 / 2 | 0.236 / 0.227 / 0.229 |
| size 6 | 1.411 / 1.458 / **1.516** (z +1.7) | 1.000 / 1.026 / **1.057** (z +1.3) | 3 / 5 / **2** | 17 / 15 / 18 | 0 / 2 / 0 | 0.328 / 0.333 / 0.359 (z +1.1) |
| mixed tiers | 1.384 / 1.394 / 1.373 (z -0.2) | 1.003 / 0.991 / 0.990 (z -0.5) | 15 / 20 / 19 | 92 / 94 / 89 | 10 / 13 / 12 | 0.413 / 0.396 / 0.382 |

- In the pack, rule 18.2 is down on HEAD in the default and size-6 runs, and flat against r1 in mixed tiers.
- The set-up gybe above the line does not show up as mark-room calls in the pack.
- Size 6 leans up on contacts (+7%) and calls (+6%), mostly rule 10. Both are inside 2 paired SE, and r1 already leaned the same way (contacts +0.05). Watch it in the matrix (W4).

### 3. Near-mark and far-mark roundings (the by-the-lee change is global)

**Missing:** neither the pack JSON nor `--diagnose` records her approach gybe, so "near relative to her approach gybe" cannot be split directly. The diagnose sweeps have no per-boat rounding data at all.

**Proxy:** I used two pack proxies on per-boat records, with the same boats compared on both trees:
- (a) **Near:** in races with the pack at offset ±6, the mark under the pack.
  - Empirically, offset -6 rounds mark 0 about 80% of the time on base, and +6 rounds mark 1 about 80%.
  - The `PackLayout.offset` doc comment says the reverse ("+6 ... the gate's left mark", and left is mark 0). The data was used. Possibly a doc-comment slip; no code was edited.
- (b) The boat rounds the same mark on base and on HEAD, so the comparison is per boat.

Boats that rounded the same mark on base and HEAD, base -> HEAD on the same boats:

| run | subset | n | extra m | deepest m (paired diff, SE) | deepest p90 | still below | overshoot |
|---|---|---|---|---|---|---|---|
| default | near (mark under the pack) | 1183 | 27.4 -> 24.7 | 9.52 -> 8.97 (-0.55, 0.16) | 17.4 -> 16.3 | 50 -> 48 | 39 -> 19 |
| default | far | 286 | 41.0 -> 33.1 | 7.75 -> 7.62 (-0.13, 0.28) | 9.8 -> 10.6 | 2 -> 2 | 29 -> 27 |
| default | offset 0 | 752 | 29.9 -> 27.2 | 8.55 -> 8.01 (-0.54, 0.17) | 15.4 -> 13.0 | 27 -> 19 | 22 -> 16 |
| size 6 | near | 433 | 31.8 -> 27.9 | 9.58 -> 8.92 (-0.66, 0.29) | 18.8 -> 16.3 | 22 -> 22 | 15 -> 6 |
| size 6 | far | 133 | 42.8 -> 36.9 | 7.62 -> 7.79 (+0.17, 0.43) | 9.8 -> 12.3 | 1 -> 1 | 16 -> 14 |
| mixed tiers | near | 1121 | 26.2 -> 24.1 | 9.19 -> 8.73 (-0.47, 0.13) | 16.6 -> 15.2 | 56 -> 57 | 27 -> 10 |
| mixed tiers | far | 335 | 31.8 -> 27.5 | 7.90 -> 7.92 (+0.02, 0.26) | 12.6 -> 13.1 | 8 -> 11 | 17 -> 17 |

**Near-mark roundings did move, but better, not worse:**
- deepest -0.5 to -0.7 m (z about -3.4)
- extra -2 to -4 m
- still below flat
- overshoot roughly halved: 39 -> 19, 15 -> 6, 27 -> 10

Round 1 had near-mark overshoot 46 -> 37 and deepest -0.46 on the same proxy, so part of this predates round 2. The extra drop since then is likely the by-the-lee aim, but that is not attributed: it needs a toggle.

Far-mark roundings by boats that kept their mark are flat. The diagnose sweeps' overshoot column agrees: it is at or below base in 6 of 7 sets.

So #518's inset tuning is not undone in the measured direction. If the owner wants "unchanged" rather than "no worse", the overshoot drop is the thing to look at.

Boats the traffic sends to the other mark (switched from base), HEAD against r1:

| run | n (r1 / HEAD) | deepest r1 -> HEAD | still below r1 -> HEAD |
|---|---|---|---|
| default | 616 / 652 | 16.45 -> 9.66 | 61 -> 15 |
| size 6 | 281 / 299 | 16.15 -> 9.52 | 32 -> 11 |
| mixed tiers | 681 / 675 | 12.94 -> 8.71 | 58 -> 20 |

That is round 2's fix working where it was aimed. The switched boats pay more extra: 43.4 m against 36.7 m on r1.

## Watch items (not regressions)

- **W1: still below in 8-boat sets with Club boats.**
  - all-Club 8: 4 -> 11 (0.6% -> 1.7%).
  - 8-mixed s1-8: 6 -> 11; its Club rows go 2 -> 6.
  - Pooled over the three 8-boat sets, Club still below goes 9 -> 22 (Poisson z about 2.3).
  - The 16-boat and 10-boat sets are at or under base, and the pack is under base.
  - Cause unknown; the list in owner addition 1 has the cells to trace.
- **W2: rule 18.2 pooled 22 -> 30 -> 38** (z +2.3 against base, +1.2 against r1).
  - Mostly National: 8 -> 8 -> 14.
  - The counts are small, and the pack is flat or down.
  - The orchestrator's bot matrix will show whether it is real.
- **W3: the pack extra m gain in mixed tiers is gone.**
  - 100.8 -> 100.9 (z +0.2). r1 had -1.5 (z -0.8), so it was already inside noise.
  - The default and size-6 runs keep most of the gain.
- **W4: pack size 6 contacts and calls lean up.**
  - Contacts +0.10 a race (z +1.7), calls +0.06 (z +1.3), mostly rule 10.
  - Inside noise.

## check.sh

`scripts/check.sh` at 7814c4b0 (the tree is clean apart from `.brief/`; check.sh tree 3d31536c): **all passed, exit 0**. The log is `.brief/525-1-results-2/check.log`.
- Builds: Core, Protocol, Client, Services, Server and the app tests.
- RegattaCore: 1002 tests in 150 suites, 335 s.
- `skiffEightBotsAreBitIdentical` passed. It expects 0x1983f405f32e8e8f, at BotHandTackTests.swift:46.
- One known issue, which predates this branch: #477 `nationalFleetsStartCleanAndOnTime`, on-time 0.458.

## Not run

- Bot matrix: the orchestrator runs it.
- Golden/Linux: CI.
- UI tests: CI.
- BotBenchmarkTests: optional, skipped.
