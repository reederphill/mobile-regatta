<!-- machine-generated: for agents, not human readers -->

Research ticket (owner, 2026-10-14). Two parts, the second gated on the first. Output is a findings write-up with a measured prototype and a go / no-go on the rework; **nothing from this ticket merges**. Probe and prototype code live on a prototype branch; an accepted design becomes its own build ticket, reimplemented from main. Builds on #464 (the rounding probe), #525 (the gate planner research) and the owner's playtests of 2026-10-14.

## Why

The owner's playtest (12 boats, National fleet, 5 starts): bots run into boats ahead of them, and into the player, from clear astern with easy evasions available; they foul other boats to stay below the line; about five penalties before every gun; "both too cautious and not good at being cautious". None of this is one bug. It is the conduct gate, which has been red since the day it existed.

**The Bot suite workflow has failed on all 49 runs on main since it was added on 2026-10-05 as the ship blocker (#105).** Every bot PR since was validated as "no regression against main" (`scripts/bot-matrix.sh`), a relative bar under an absolute one that main does not meet. The live job's gate on main at 6fc061d2 (run 49), reproduced locally to the digit with `regatta-botsuite --profile-mix live --tier-mix national --diagnose` (160 races, 1320 boats):

| Gate (live, all-National) | Main | Threshold |
|---|---|---|
| start: on time (within 3 s of the gun, 10 boats) | 0.47 | ≥ 0.60 |
| navigation: finish share | 0.916 | ≥ 0.98 |
| navigation: DSQ for a missed penalty | 2 | 0 |
| conduct: encounters ending in a foul | 0.045 | ≤ 0.020 |

The fouls row is the subject of this ticket. Its history (live job, gate lines): 0.055 on 2026-10-05 (run 1), 0.052 on 10-09, 0.050 on 10-10, 0.044 on 10-10 (hand tacks), 0.043 on 10-11, 0.042 on 10-12, 0.045 on 10-14. Flat within noise across 49 runs and roughly a dozen conduct PRs (rule 17 #346, rule 21 #337, misjudging #103, hold-course #228, the penalty circle #517, the cautious bot's clearances #104, hand penalty turns #28/#29 of the suite's history). Conduct constants "set by hand on 80 races" now number in the dozens (`BotBrain+Conduct.swift`, `BotBrain+Start.swift`, `BotBrain+Cautious.swift`: 65 `static let`s between them).

**It is not hand steering or hand tacking.** Same brains, same 32 races of 12 National bots on current main, only the class swapped (`--boat-class`):

| | skiff@6 autohelm | skiff@7 hand steer, tap tack | skiff@9 hand tack (default) |
|---|---|---|---|
| fouls per encounter | 0.052 | 0.054 | 0.043 |
| pre-start calls per boat | 0.28 | 0.30 | 0.23 |
| pre-start penalty episodes per race (12 boats) | 2.8 | 3.3 | 2.7 |
| on time | 0.70 | 0.66 | 0.48 |
| a pre-start penalty makes her late by | 16 s | 16 s | 26 s |

Hand turns made penalties expensive (recovery to 90 % speed 18.6 s against 8–10 s) and the start late; they did not add fouls. The fouls are conduct, on every class, and the leading pre-start calls are rule 11 (windward) then rule 10 (port), then 13, 15, 16.1. In the CI live run 53 of 265 pre-start calls were 21.2 on a boat already turning a penalty; 105 of 111 National non-finishers were on the last leg and 76 had been called at least once: the finish-share row is mostly penalty cascades too.

**Why more rules will not move it.** The conduct code is rules on top of one evaluator, and the evaluator's limits are structural (`BotBrain+Conduct.swift`; `keepClear`, `ruleKeepClear`, `isAboutToHit`, `closestApproach` in `BotBrain.swift`):

1. **Straight lines.** `isAboutToHit` projects every boat within 30 m at today's velocity for `keepClearLookahead` seconds (4.5 s default, by skill) and asks whether the closest approach is under 1.3 hull lengths. A boat luffing at the line, slowing, turning a penalty or about to tack is a boat sailing straight on. (`turnsTowardsKeepClearBoat` and `tapIsClear` do the same.)
2. **Heading only, own tack only.** `clearingHeading` scans 5° steps away from the desired course on her own tack for one that passes every boat at 1.3 × 1.2 lengths over the lookahead. Slowing down, tacking away, gybing away and a hard bear-away behind are not candidates. Easing exists only before the start (`Evasion.dropsAstern`).
3. **First boat wins.** `ruleKeepClear` returns on the first boat in seat order that trips the test. Two threats are never weighed together, so in a pack the heading that clears one boat is into another.
4. **No memory.** Nothing is remembered between decisions except the one-sided "already turned" hysteresis in `clearingHeading`. A boat astern luffs 5°, is clear for 4.5 s, turns back toward her course, and repeats: the slow run into a boat ahead the owner sees.
5. **The line beats the rules by design.** Before the start a starboard boat whose luff would cross the line early (`crossesEarly`) falls back to `startKeepClear`, or sails on. That is fouling to avoid OCS, as written.
6. **A refused turn has no plan B.** `tapIsClear` refuses a tack or gybe while any boat would pass within 1.3 lengths of the straight-line turn over 3–6 s; `sail` then holds her own tack's groove. Over-cautious, and not good at being cautious, in one place.

Each of the owner's complaints lands on one of these six. A seventh rule is still evaluated by the same straight-line, single-threat, heading-only test.

## Part A: classify main's fouls (first; two days)

Before any rework, the data must say which of the six limits the fouls actually come from. The #464 probe (`regatta-roundprobe`, prototype branch `claude/practical-bohr-htjq9q`, ported to main in `/home/user/main-wt`'s `probe-main` on the owner's machine; `BotProbeTrace`) already records every decision's branch, evasion, keep-clear rule and refused-tap reason. Extend it to fouls.

For every call as offender in the CI live matrix (`--profile-mix live --tier-mix national`, 160 races, ~370 racing fouls and ~265 pre-start calls) record:

- **Rule and phase**: 10 / 11 / 12 / 13 / 15 / 16.1 / 18.2 / 21.2 / 31; pre-start, first beat, later legs, last leg (the diagnose's `PenaltyPhase`).
- **Geometry** at the call and 3 s before: relative bearing and range of the other boat, both headings and speeds against the wind, whether either was turning, tacking, taking a penalty, stopped (< 30 % polar) or luffing at the line; distance to the line, to a mark, to a third boat within 2 lengths.
- **What the brain did** for the 5 s before the call, per decision: `evasion` branch (none / keep-clear rule / mark / edge / hold-course), the heading it chose against the desired one, whether `isAboutToHit` fired and at what lookahead, whether a tap was wanted and refused and why (`cantTapWhy`), whether the encounter was misjudged (`misjudges`).
- **The manoeuvre that would have avoided it**: re-run the 5 s from the saved snapshot (`exportSnapshot` / `importSnapshot`, as the pack scenario does) with the offender steered by each of a fixed set: hold; luff 10°, 20°, 40°; bear away 10°, 20°, 40°; ease to half speed; tack; gybe; the other boats on their recorded tracks. Record which, if any, keep the escape simulation from calling it (the umpire's `EscapeSimulation` is fine here: this is the probe, not the bot). A foul none of them avoids is "committed 5 s out": re-run from 10 s.

Deliver the classification as a table: rule × phase × dominant geometry, with the share of fouls in each cell, and for each cell the share avoided by (a) a heading change on her own tack within what `clearingHeading` can already produce, (b) a manoeuvre the evaluator cannot produce (slow, tack, gybe, a bear-away past the step scan), (c) weighing a second boat, (d) nothing within 5 s. Separately: how many were cascades (a call on a boat already turning, or within 15 s of her last call), and how many pre-start fouls were the line-over-rules fallback (limit 5).

**Decision rule.** If (b) + (c) hold most of the fouls, or (d) does at 5 s but not at 10 s, go to Part B. If (a) holds most of them, the evaluator's output is right and its inputs are wrong (ranges, lookahead, the straight-line prediction): fix those as targeted build tickets instead, and Part B does not start. If one or two rule × geometry cells hold more than half the fouls on their own, those two cells get build tickets first whatever the rest says.

## Part B: an evaluator rework, prototyped (gated on A; three days)

Not a new brain, not new rules, not a learned helm. Replace what the keep-clear code sits on. Where today `evasion` asks "is a straight-line collision coming, and which 5° heading step on my tack clears it", the prototype asks "of a handful of manoeuvres, which keeps me clear of everything I owe room to, at least cost to my course, and did I already commit to one".

- **Trigger**: the cheap test as today (any boat within `keepClearRange` whose straight-line approach, or whose turning circle if she is turning, comes inside 2 lengths over the lookahead), so the roll-out runs on a minority of ticks. Racing and pre-start, every tier, the cautious bot included.
- **Candidates**, fixed, 9 to 11: hold; luff 10° / 20° / 40°; bear away 10° / 20° / 40°; ease to half speed holding course; tack; gybe. Before the start, also "the line": a candidate is dropped if it crosses the line early within `luffLineSeconds`, unless every candidate does, in which case the line loses and she keeps clear (the owner's ruling: a foul is worse than an OCS; confirm in grilling).
- **Roll-out**: each candidate sailed `horizon` seconds ahead (5 s Club to 8 s National) with the real dynamics from the seat view, as the cautious bot already does for a tap (`tapTrack`: `BoatDynamics.State` stepped by `Autohelm.tackOrGybe`) and the hand turn does for a penalty sweep (`turnSweep`). Other boats: on their current velocity, with the turn rate the cautious bot estimates (`tapApproach`), **and with their obligation**: a boat that must keep clear of her is rolled giving way (her rule's manoeuvre, `racingKeepClear`'s for that rule); a right-of-way boat holds; a boat taking a penalty is her circle (#517). Fidelity is question 3.
- **Score**, lexicographic then weighted: a candidate that brings her inside her keep-clear distance of a boat she must keep clear of (rules 10–13, mark-room she owes), or inside a mark's clearance, or over the line early, is out; among the rest, metres lost against her desired course over the horizon, plus a cost per tack or gybe, minus a commitment bonus for the candidate she chose last decision (so she finishes a manoeuvre instead of swinging between two). Right of way is unchanged: `holdingCourse` still centres the rudder when a turn would take room from a boat that must keep clear of her (rule 16.1), and the candidates that do so are out for a right-of-way boat.
- **Output**: the winning candidate's first aim, through the existing `steer` / `handTurn` / `planRoll`, so planing, hand turns, the start plan and tactics are unchanged. A tack or gybe candidate replaces `tapIsClear`'s yes/no with "the best manoeuvre is a tack", which is the plan B a refused turn lacks today.
- **Tiers**: horizon and candidate count by skill (Club: 5 s, the six heading candidates and ease; National: 8 s, all), and `ruleMisjudgeRate` as today. Measured in question 5.
- **Determinism and tracing**: plain arithmetic from the seat view, no draw outside her streams, the losing candidates and their scores written to `BotProbeTrace`. Bit-identical across platforms as every brain decision is (ADR 0002 unaffected: replays never run brains).
- **Cost**: at most 11 candidates × 8 s at the decision step (0.5 s) = 176 dynamics steps per triggered decision, against the 5 ms tick budget and the brain's current p99 of 0.5–0.6 ms; question 4. If it is over, the candidate set shrinks before the horizon does.

What does **not** change: `SeatView` (she sees what she sees today), the rules files, the right-of-way logic, the start plan, tactics, planing, the hand turn, the gate pick. The rework is `BotBrain+Conduct.swift` and the `keepClear` / `evasion` / `tapIsClear` seam in `BotBrain.swift` and `BotBrain+Start.swift`.

## Questions to answer

1. **(A)** Where do main's fouls come from: the classification table above, with the decision rule applied and written down.
2. **(B)** Does the rework move the gate: fouls per encounter on the live all-National cells (target ≤ 0.020; anything under 0.030 is a go for a build ticket), by rule and phase against A's table, so the gain is where the fouls were. Plus everything that could pay for it: on-time share (≥ 0.60), finish share, missed-penalty DSQs, pre-start calls per boat, mark touches, rule 16.1 calls (the hold-course watchdog stays at 0), finish share by tier and the Club/Regional/National place gap, the cautious bot's suite (`CautiousBotSuiteTests`), and the #464 / #523 rounding measures so a boat that keeps clear better does not round worse. The pack scenario (#526) for traffic.
3. Roll-out fidelity: where she was at the horizon against where the roll-out put her, metres, by tier; and the other boats' predicted against actual tracks with and without the obligation model. If constant velocity is within a hull length at 5 s, the obligation model is a tier lever, not a requirement.
4. Tick cost: p99 and max brain time per tick at 16 boats with the rework, triggered share of ticks, against the 5 ms budget and main's 0.6 ms. Candidate set and horizon that fit under 2 ms.
5. Tiers: does horizon × candidate count give a Club–National gradation in fouls and places as today's constants do, or does every tier converge (as #525's planner did at the gate)? If they converge, the lever is scoring noise or `ruleMisjudgeRate` alone, and that is a finding.
6. The pre-start specifically: with "a foul is worse than an OCS" in the score, what happens to OCS share (gate ≤ 0.05) and on-time share; and penalty cascades (calls on a boat turning, episodes of 2+ calls) with and without the obligation model for a boat taking a penalty.

## Sweeps

The CI live matrix (`--profile-mix live --tier-mix national`, seeds 1–4, 2/5/10/16 boats, the four venues) is the gate and the baseline: main at 6fc061d2 has it on record. Add: 12 boats all-National on dev-venue@7 and hollin-bay@1 (the owner's playtest fleet; the matrix for it is in #525's findings thread), seeds 1–8, and the same with `--boat-class skiff@7` so the class is held constant across the comparison. The pack scenario, both currents. Every comparison paired by seed and venue; noise from the two seed halves as in #525.

## Not this ticket

- **New conduct rules.** Nothing in `BotBrain+Conduct.swift` grows a case until A has placed the fouls.
- **A learned helm or learned scorer.** The determinism, tiering, rules-conduct and traceability objections in #525 stand. If B's hand-written score plateaus the way the rules did, a learned scorer over B's candidates is the follow-on, with B's trace as its data.
- **The start timing regression** (on-time 0.66 → 0.48 from the hand-tack block, 2026-10-10): recovery after a hand turn 18.6 s against 8–10 s, "on port inside 20 s" 7 % → 14 %, "couldn't fetch the pin" 3 % → 7 %. Its own ticket, measured by the start gate cell alone; B's pre-start work must not make it worse.
- **The gate planner** (#525, parked) and the hand fixes in flight for it.
- **Making the Bot suite workflow block merges.** A process decision for the owner: the log should record that from 2026-10-05 to today no bot PR was held to the absolute gate. Until it is green, "no regression against main" is not validation for bot PRs.

## Time box

A: two days. B: three days, started only on A's decision rule. A fourth day on B only if question 2 is within 0.005 of the target and a named change would close it.

## Deliverable

`.prototype/<n>-findings.md` on the prototype branch and the same as the closing comment here: A's table and decision; B's numbers against main for every measure in question 2, by tier, both seed halves; fidelity, cost, tiers; a go / no-go on a build ticket for the evaluator, and the build tickets A produced on its own. Then the orchestration log row.

## Owner commands

```
# the gate as CI runs it (main's baseline)
swift build -c release --package-path Packages/RegattaCore --product regatta-botsuite
.build/release/regatta-botsuite --profile-mix live --tier-mix national --diagnose --json live-national.json
# the playtest fleet (matrix JSON: fleetSizes [12], tierMixes ["national"], profileMixes ["live"], seeds 1-8,
# venues dev-venue@7 and hollin-bay@1 with classic-oscillating@7 and sea-breeze@7)
.build/release/regatta-botsuite --matrix matrix-nat12.json --diagnose
.build/release/regatta-botsuite --matrix matrix-nat12.json --diagnose --boat-class skiff@7
# the pack
.build/release/regatta-botsuite --scenario pack --fleet-size 6 --seeds 16
# the fouls probe (Part A; on the prototype branch)
.build/release/regatta-roundprobe --fouls --profile-mix live --tier-mix national --json fouls.json
```


---
_Generated by [Claude Code](https://claude.ai/code)_
