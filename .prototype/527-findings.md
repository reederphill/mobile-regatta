# #527 Part A findings: where main's fouls come from (revised after the owner's critique, 2026-10-15)

Prototype branch `prototype/527-fouls` (main 0135bdae + the #464 trace). Probe: `regatta-roundprobe --fouls [--after s]`
(`Sources/regatta-roundprobe/Fouls.swift`). Per-call records: `.prototype/527-fouls-8s.json` (call + 8 s, quoted
below) and `.prototype/527-fouls.json` (call + 3 s, the first cut). Recount: `.prototype/527-strict8.py`.

## Method and checks (accepted)

- **Races.** The 160 races of the CI live gate (`--profile-mix live --tier-mix national`), sailed through `BotRaceHarness.run`.
- **Gate count.** 606 calls as offender (275 before the gun, 331 after), equal to `regatta-botsuite`'s counts. Mark touches (203) are counted separately.
- **Determinism.** The botsuite report on pristine main is textually identical to this branch's, apart from timing lines.
- **Main on this Mac.** fouls per encounter 0.043 (CI 0.045), on time 0.46, finish share 0.912, 5 missed-penalty DSQs.
- **Counterfactuals.** Each call is re-sailed from a snapshot at T−5 s. Each fork replays 9 s of recorded inputs first, so the umpire has its look-back history. The others then sail their recorded inputs, and the offender is steered by one of hold, luff 10/20/40°, bear away 10/20/40°, ease, tack or gybe.
- **Identity check.** Replaying the offender's own recorded inputs re-creates the same call in 601 of 602 forks.
- **Strict "avoided".** From the branch to **the call + 8 s**: no call on her (any boat, any rule), not over the line early, and not merely put off.
- **Upper bounds.** The other boats sail their recorded inputs. In the recording they reacted to her real evasion, so in the fork they swerve for a boat that is not there. Every avoided share below is an upper bound. The tickets are judged on live paired races.

## The window: 3 s → 8 s

| | call + 3 s | call + 8 s |
|---|---|---|
| holding course from 5 s out avoids it | 410 (68%) | **346 (57%)** |
| some own-tack heading avoids it | 570 (95%) | 537 (89%) |
| only ease / tack / gybe | 14 (2%) | 25 (4%) |
| nothing from 5 s | 18 (3%) | 40 (7%) |

Holding course is still the largest single row. The best candidate at 8 s is a tack (65%); the others range from 55% to 63%.

The own-tack heading row is 89–95% **by construction**: the scan covers her whole own-tack range in 5° steps, so it is not evidence about the evaluator. The ticket's decision rule was mis-specified on that point. The conclusion rests on the cause table below.

## Cause table (what she was doing in the 5 s before; first that holds; 602 calls)

| cause | calls | holding course avoids (8 s) |
|---|---|---|
| keep-clear evasion steering for **this** boat | 177 (29%) | 117 |
| keep-clear evasion steering for **a third** boat | 118 (20%) | 60 |
| her own penalty turn (incl. every 21.2) | 142 (24%) | 84 |
| her tack or gybe (51 of the 59 rule 13 calls) | 62 (10%) | 40 |
| pre-start: rule keep-clear crossed the line early, fell back to `startKeepClear` (limit 5) | 52 (9%) | 9 |
| a plan turn, no evasion | 42 (7%) | 33 |
| straight, no evasion | 9 (1%) | 3 |

**Correction to the first write-up.** It said the line-over-rules fallback accounted for 1 call. That came from a bad test in my recount, which required a "start" path decision as well as the fallback. The fallback fired in the 5 s before 52 calls. In most of those, holding course does not avoid the call either (9 of 52): the boat is already committed.

**Reading.**
- **Evasion.** About half the fouls (49%) happened while she was evading, and holding course avoids 60% of those (177 of 295). The evasion caused the foul. This is decision quality from limits 1, 3 and 4: a turning boat predicted straight, the first boat wins, no commitment. The heading toggled 2+ times in 107 calls.
- **Penalty turns.** 24% were her own penalty turns steered into traffic, or calls drawn while turning. There were 130 cascades: 57 on a boat already turning, 92 within 15 s of her last call.
- **Tacks.** 10% were tacks `tapIsClear` passed and rule 13 then called.
- **Manoeuvre candidates.** Ease, tack or gybe as the only remedy is 4%. The manoeuvre-candidate half of Part B is not justified, and neither is the roll-out dynamics.

## Pre-start: `startKeepClear` vs `ruleKeepClear`

The 271 calls before the gun (tick < 0, with candidates), split by the keep-clear path taken in the 5 s before:

| | `startKeepClear` (port, OCS, or keeps clear of all) | `ruleKeepClear` | line fallback | no keep-clear |
|---|---|---|---|---|
| all pre-start | 111 (41%) | 61 (23%) | 32 (12%) | 67 (25%) |
| rule 10 port/starboard (the top cell: 59 at tick < 0; 67 in `PenaltyPhase`'s pre-start) | **52** | 0 | 0 | 7 |
| rule 11 | 23 | 43 | 28 | 16 |
| rule 15 | 15 | 11 | 1 | 7 |


The top cell goes almost entirely through `startKeepClear`, the "by the water" code path the racing rewrite does not touch. Its cause analysis (round 3, below) gives it its own ticket.

## Round 3 (owner, 2026-10-15): `startKeepClear`, the tack candidate, and the 10 s reruns

Run: `--after 8 --always10` (every call also forked from T−10 s). `.prototype/527-fouls-8s10.json`; analysis `.prototype/527-round3.py`. The 8 s numbers above are unchanged. Identity from T−10 s: 592 of 592.

### Inside `startKeepClear` (111 pre-start calls), against the racing evasion (178 calls)

| | `startKeepClear` | pre-start `ruleKeepClear` (starboard boats) | racing evasion |
|---|---|---|---|
| calls | 111 | 61 | 178 |
| holding course avoids (8 s) | 53% | 33% | 68% |
| a tack avoids | 68% | 26% | 80% |
| some own-tack heading avoids | 87% | 85% | 93% |
| only ease / tack / gybe | 6% | 8% | 3% |
| nothing from 5 s | 6% | 7% | 4% |
| heading toggled 2+ times | **40%** | 21% | 22% |
| evasion aimed at a third boat (first boat wins) | **54%** | 49% | 30% |
| decisions in keep-clear | 74% | 73% | 68% |
| mean / median-max offset off her course | 35° / 72° | 42° / 85° | 43° / 115° |
| her off-course decisions that luff / bear away | 46 / 54% | 69 / 31% | 47 / 53% |
| … that point her closer to the boat she then fouls | 29% | 44% | 37% |
| the other boat stopped (< 30% polar) at the call | **61%** | 43% | 16% |
| her speed (share of polar) | 0.32 | 0.25 | 0.30 |
| her tack | port 101, starboard 10 | starboard 61 | port 117, starboard 61 |
| rules | 10: 59, 11: 23, 15: 15, 13: 10 | 11: 43, 15: 11, 16.1: 5 | 10: 86, 11: 54, 15: 22 |

**Same failure, different weights; its own ticket.** `startKeepClear` fails the way the racing evasion does: its heading is worse than holding course in half its fouls, and a tack beats both. But two of the limits weigh far more here, and one barely applies:

- **First boat wins (limit 3).** Its evasion was steering for a different boat in 54% of calls, against 30% when racing.
- **No commitment (limit 4).** Its heading toggled 2+ times in 40% of calls, against 22%.
- **Straight-line prediction (limit 1) barely applies.** The boat she fouls is already stopped in 61% of calls (a starboard row parked below the line): there is no turn to predict.

So the fix is the scorer's two cheaper parts, weigh every boat and commit, without the turn-aware prediction or the overtake. It ships as its own ticket on its own code path, ahead of the racing scorer, and the racing ticket reuses its scorer.

The pre-start `ruleKeepClear` group (starboard boats, mostly rule 11 at the line) has another signature again. Holding course avoids only 33%, its evasion luffs (69%) and points at the boat it fouls 44% of the time, and 21 of its 61 calls are the line fallback. That is the start's approach (below), not the keep-clear scorer.

### The tack candidate

A tack is the best single candidate at 8 s:

| group | a tack avoids | holding course avoids |
|---|---|---|
| all calls | 65% | 57% |
| racing evasion | 80% | 68% |
| `startKeepClear` | 68% | 53% |

It is the most inflated upper bound. A tack takes her out of the recorded traffic altogether, and nobody reacts to her. Owner ruling: one tack candidate in the scorer, below. The roll-out planner stays a no-go.

### The committed subsets from 10 s

- **Base rate.** From T−10 s, 94% of *all* calls have some clean candidate. "Avoidable from 10 s" is near-universal, so read the subsets against it. They are harder than the average call, not easier.
- **Nothing avoids from 5 s (39 calls; 25 before the gun).** 69% are avoidable from 10 s.
  - Racing, 14 calls: 79% avoidable (holding 36%, a heading 71%). That is the horizon-in-lengths item for racing.
  - Pre-start, 25 calls: 64% avoidable. 17 of them are line-fallback calls.
- **Line fallback (52 calls, 46 of them rule 11).** 77% are avoidable from 10 s, by a heading 62%, by holding only 15%. Of the 43 that holding course does not avoid from 5 s, 72% are avoidable from 10 s.

The mistake is made before the 5 s window, and the remedy from 10 s is a change of course, not holding on. The start plan puts her where her keep-clear course and the line conflict. That is approach timing, not conduct: a line in the start-regression ticket.

## Decision

- **Not as the ticket's rule read it.** The conclusion is not "the evaluator's output is right and its inputs are wrong".
- **Decision quality.** The evaluator chose headings, and in most evasion fouls the chosen heading was worse than the one she was on.
- **Part B in two halves.**
  - **The roll-out planner and the manoeuvre set: no-go.** Ease, tack or gybe as the only remedy is 4%.
  - **The heading scorer with commitment: go**, plus one tack candidate (round 3). It is tickets 2 and 4 below, measured with Part B's rigour (question 2 in full).

## Draft build tickets (not filed; in order)

Each ticket reruns this probe's Part A table on its branch (`--after 8`), so the gain shows in the rows the fouls came from. Every counterfactual share above is an upper bound; the tickets are judged on paired live races.

### 1. Bots: penalty turns in clear water

- **Scope.** 142 calls (24%) plus most of the 130 cascades.
- **Before she starts a circle.** She checks the turn's sweep (`turnSweep`, a disc of her turn's diameter as #517 gives other boats) against the boats round her, and delays or bears off to clear water rather than turning through them.
- **While she turns.** She keeps checking; a boat entering the sweep makes her finish the current heading change away from it rather than through it.
- **Measures.** All on paired live 160-race runs:
  - fouls per encounter; 21.2 calls; calls while turning; episodes of 2+ calls;
  - finish share and missed-penalty DSQs;
  - on-time (the five-penalties-before-the-gun complaint);
  - this probe's penalty-turn cause row.

### 2. Bots: pre-start keep-clear weighs every boat and commits (`startKeepClear`)

- **Scope.** 111 pre-start calls, a fifth of all fouls: rule 10 port/starboard 52 (the top cell), 13/15 25.
- **What changes.** `startKeepClear`'s heading choice becomes a score over candidate headings on her tack, holding course included, against every boat she must keep clear of within range. It is no longer the first boat that trips the test.
- **Commitment.** She keeps the chosen heading until it no longer clears, which ends the toggling.
- **Tack candidate.** One tack candidate on the existing tack track (`tapTrack`), costed in lengths. It wins when the best heading clears only by a thin margin, or only if the other boat holds her course.
- **Not in scope.** No turn-aware prediction: the boats she fouls are mostly stopped.
- **Shared code.** The scorer is written to be reused by ticket 4.
- **Measures.**
  - pre-start calls per boat by rule;
  - pre-start penalty episodes a race;
  - on time and OCS share (gate ≤ 0.05);
  - fouls per encounter;
  - this probe's `startKeepClear` row (toggling, third-boat share, hold-avoids).

### 3. Bot suite: an overtake scenario (harness; lands before ticket 4)

- **Why.** The owner's playtest complaint is "bots run into me from behind with easy evasions available". Between bots this geometry is 5% of fouls (clear astern 31 + into a stopped boat 45), because a bot behind a slow bot is usually in the same air. With a player ahead it is a routine beat, so the live gate cannot show it.
- **Scenario.** A scripted boat sails the player's part:
  - at 60–70% of polar on the first beat;
  - holding below the line before the gun;
  - with bots astern at 2–6 lengths, on both tacks and both currents.
- **Measures.**
  - contacts;
  - rule 12 calls (and rule 11 overlapped);
  - closest approach;
  - how far back the pass was chosen (the first tick of a sustained offset);
  - seconds to clear ahead.
- **Pattern.** As `--scenario pack` (#526) did for the gate.

### 4. Bots: racing keep-clear on ticket 2's scorer, with a turn-aware prediction and the overtake (Part B's heading half)

Replaces `ruleKeepClear`'s first-boat-wins and `clearingHeading`'s least-offset step when racing.

- **Scorer.** Ticket 2's scorer, holding course and the tack candidate included, against every boat within `keepClearRange`: rules 10–13 and the mark-room she owes. It keeps ticket 2's commitment.
- **Turn-aware prediction.** Predict a turning boat on her yaw rate, and a slowing or stalling one on her measured acceleration over the last second (clamped), from a per-seat velocity memory (limit 1).
- **Horizon in distance.** For a boat ahead on her tack, flag her when the closing brings her inside 1.3 lengths within ~6 lengths of her own travel, whatever the closing speed. Keep the 4.5 s test for crossings. The racing calls nothing avoids from 5 s are 79% avoidable from 10 s.
- **A committed pass, chosen at the first flag.** Pick a lane two lengths to windward (when her speed margin gets her through before the shadow is hers) or to leeward (with the bear-away's speed), and hold it until clear ahead. On a beat, the overtake feeds the tactics module's clear-air weight, so a tack is at least considered.
- **Tack clearance** (rides with this ticket). `tapIsClear` / `tapTurnsAtKeepClearBoat` test the turn track she will actually sail (`tapTrack`) against the turn-aware prediction, not straight lines. This covers 62 tack calls (rule 13) and the rule 15 calls after tacks.
- **Measures (#527 question 2 in full).**
  - fouls per encounter on the live cells (target ≤ 0.020; under 0.030 a go), by rule and phase against this table;
  - on-time; finish share; missed-penalty DSQs;
  - 16.1 calls (the hold-course watchdog stays at 0);
  - finish share by tier and the place gap;
  - `CautiousBotSuiteTests`;
  - the #464 / #523 rounding measures;
  - the pack scenario and ticket 3's overtake scenario;
  - this probe's racing evasion and tack cause rows.
  - Paired by seed and venue, with both seed halves.
- **Tick cost.** p99 brain time at 16 boats against main's 0.6 ms.

### A line for the start-regression ticket (not a conduct ticket)

- **The calls.** 52 pre-start calls (46 of them rule 11) came in the 5 s after her keep-clear course would have crossed the line early and she fell back. She is mostly committed by then: holding course avoids 9.
- **From 10 s.** 77% are avoidable, by a heading 62%.
- **The cause.** The start plan puts her where her keep-clear course and the line conflict. That is approach timing.
- **Measure.** Count this row on that ticket's branch.

## Rerun

```
scripts/heavy.sh swift build -c release --product regatta-roundprobe --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore
scripts/heavy.sh .build/check/RegattaCore/release/regatta-roundprobe --fouls --profile-mix live --tier-mix national --after 8 --always10 --json .prototype/527-fouls-8s10.json > .prototype/527-fouls-8s10.txt
python3 .prototype/527-strict8.py .prototype/527-fouls-8s10.json
python3 .prototype/527-round3.py .prototype/527-fouls-8s10.json
```
