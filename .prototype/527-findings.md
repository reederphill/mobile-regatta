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

The top cell goes almost entirely through `startKeepClear`, the "by the water" code path ticket 1's racing rewrite does not touch. Holding course avoids 27 of those 59 at 8 s. It needs its own line in ticket 1's scope (below).

## Decision

- **Not as the ticket's rule read it.** The conclusion is not "the evaluator's output is right and its inputs are wrong".
- **Decision quality.** The evaluator chose headings, and in most evasion fouls the chosen heading was worse than the one she was on.
- **Part B in two halves.**
  - **Manoeuvre candidates and roll-outs: no-go.** Only 4% of fouls need them.
  - **The heading half, with commitment and a better prediction: go.** It becomes ticket 3 below, measured with Part B's rigour (question 2 in full).

## Draft build tickets (not filed; in the owner's order)

### 1. Bots: penalty turns in clear water

- **Scope.** 142 calls (24%) plus most of the 130 cascades.
- **Before she starts a circle.** She checks the turn's sweep (`turnSweep`, a disc of her turn's diameter as #517 gives other boats) against the boats round her, and delays or bears off to clear water rather than turning through them.
- **While she turns.** She keeps checking; a boat entering the sweep makes her finish the current heading change away from it rather than through it.
- **Measures.** Fouls per encounter; 21.2 calls; calls while turning; episodes of 2+ calls; finish share and missed-penalty DSQs; on-time (the five-penalties-before-the-gun complaint); this probe's penalty-turn cause row. All on paired live 160-race runs.

### 2. Bot suite: an overtake scenario (harness, lands before ticket 3)

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

### 3. Bots: keep-clear heading choice with commitment and a turn-aware prediction (Part B's heading half)

Part B with the candidate set trimmed to headings. Replaces `ruleKeepClear`'s first-boat-wins and `clearingHeading`'s least-offset step.

- **Score every boat in range, holding course included.** Score each candidate heading on her tack against every boat within `keepClearRange`: rules 10–13 and the mark-room she owes. Holding course is a candidate and wins when it clears.
- **Commitment.** Keep the chosen heading until it no longer clears. Don't re-derive the least offset every tick (limit 4).
- **Turn-aware prediction.** Predict a turning boat on her yaw rate, and a slowing or stalling one on her measured acceleration over the last second (clamped), from a per-seat velocity memory (limit 1).
- **The overtake** (owner, 2026-10-15):
  - **Horizon in distance.** For a boat ahead on her tack, flag her when the closing brings her inside 1.3 lengths within ~6 lengths of her own travel, whatever the closing speed. Keep the 4.5 s test for crossings.
  - **A committed pass, chosen at the first flag.** Pick a lane two lengths to windward (when her speed margin gets her through before the shadow is hers) or to leeward (with the bear-away's speed), and hold it until clear ahead.
  - **Tactics.** On a beat, the overtake feeds the tactics module's clear-air weight, so a tack is at least considered.
- **Pre-start `startKeepClear`.** It holds the top foul cell: 52 of the 59 rule 10 pre-start port/starboard calls. The same scoring and commitment, port boat keeping clear by the water. Otherwise this ticket does not touch the top cell.
- **Tack clearance** (rides with this ticket). `tapIsClear` / `tapTurnsAtKeepClearBoat` test the turn track she will actually sail (`tapTrack`) against the turn-aware prediction, not straight lines. This covers 62 tack calls (rule 13) and the rule 15 calls after tacks.
- **Measures (#527 question 2 in full).**
  - fouls per encounter on the live cells (target ≤ 0.020; under 0.030 a go), by rule and phase against this table;
  - on-time; finish share; missed-penalty DSQs;
  - 16.1 calls (the hold-course watchdog stays at 0);
  - finish share by tier and the place gap;
  - `CautiousBotSuiteTests`;
  - the #464 / #523 rounding measures;
  - the pack scenario and ticket 2's overtake scenario;
  - this probe's evasion cause rows.
  - Paired by seed and venue, with both seed halves.
- **Tick cost.** p99 brain time at 16 boats against main's 0.6 ms.

## Rerun

```
scripts/heavy.sh swift build -c release --product regatta-roundprobe --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore
scripts/heavy.sh .build/check/RegattaCore/release/regatta-roundprobe --fouls --profile-mix live --tier-mix national --after 8 --json .prototype/527-fouls-8s.json > .prototype/527-fouls-8s.txt
python3 .prototype/527-strict8.py .prototype/527-fouls-8s.json
```
