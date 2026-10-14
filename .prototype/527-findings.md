# #527 Part A findings: where main's fouls come from

Prototype branch `prototype/527-fouls` (main 0135bdae + the #464 trace). Probe: `regatta-roundprobe --fouls`
(`Sources/regatta-roundprobe/Fouls.swift`). Raw output: `.prototype/527-fouls.txt`, per-call records `.prototype/527-fouls.json`.

## Method and checks

- **Races.** The 160 races of the CI live gate (`--profile-mix live --tier-mix national`), sailed through `BotRaceHarness.run` itself.
- **Gate count.** Calls as offender: 606 (275 before the gun, 331 after), equal to `regatta-botsuite`'s `foulsAsOffender` and `preStartCallsByRule`. Mark touches (203) are counted separately, as the gate counts them.
- **Determinism.** On pristine main 0135bdae the botsuite report is textually identical to this branch's, apart from timing lines. The probe changes no brain decision.
- **Main on this Mac.** fouls per encounter 0.043, on time 0.46, finish share 0.912, 5 missed-penalty DSQs. The ticket's CI numbers are 0.045 / 0.47 / 0.916 / 2.
- **Counterfactuals.** Every call is re-sailed from a snapshot at T−5 s. Each fork replays 9 s of recorded inputs first, so the umpire has its look-back history. Every other boat then sails on its recorded inputs, and the offender is steered by one of 10 fixed manoeuvres: hold; luff 10/20/40°; bear away 10/20/40°; ease to half speed; tack; gybe.
- **Identity check.** Replaying the offender on her own recorded inputs re-creates the same call (rule, pair, tick) in 601 of 602 forks. 4 calls are too early in the sequence to have a snapshot.
- **"Avoided" is the strict reading.** No call on her at all to the call + 3 s, not over the line early, and not merely put off. The probe's own table counts a call into a third boat as avoided. On the strict reading, holding course avoids 68% rather than 80%.
- **Caveats.** The other boats do not react to her new course; they sail their recorded inputs. "Avoided" covers only the 3 s after the call. Runtime is 3 min 10 s with 4 jobs.

## Classification (strict, 602 calls with candidates)

| class | calls | share |
|---|---|---|
| (a) an own-tack heading inside `clearingHeading`'s scan avoids it, holding course included | 570 | **95%** |
| … of which simply holding her course from 5 s out avoids it | 410 | 68% |
| … of which the trace shows `ruleKeepClear` steering for a different boat (the ticket's (c), "weighing a second boat") | 162 | 27% |
| (b) only ease, tack or gybe avoids it | 14 | 2% |
| (d) nothing avoids it from 5 s | 18 | 3% (3 of those avoidable from 10 s) |

The scan steps 5° both ways across her whole own-tack range, from the no-go angle + 5° to 180° TWA. So every luff and bear-away candidate is inside it.

By rule, phase and geometry (the probe's lenient table; full cells in `527-fouls.txt`):

| rule | n | hold avoids (strict) | | geometry | n |
|---|---|---|---|---|---|
| 11 | 187 | 0.62 | | port/starboard crossing | 164 |
| 10 | 174 | 0.66 | | tacking too close | 117 |
| 15 | 58 | 0.74 | | windward/leeward overlapped | 96 |
| 13 | 59 | 0.68 | | turning a penalty | 66 |
| 16.1 | 52 | 0.81 | | into a stopped boat | 45 |
| 21.2 | 51 | 0.76 | | changing course (16.1) / clear astern | 31 / 31 |

- **By phase.** pre-start 316 (52%), first beat 204, later legs 84, last leg 2. The pre-start phase follows `PenaltyPhase`, so it includes boats not yet started after the gun.
- **Largest cells.** rule 10 pre-start port/starboard 67 (11%), rule 11 pre-start overlapped 60 (10%), rule 10 first-beat port/starboard 46, rule 10 later-legs port/starboard 45. No two cells hold more than half the fouls (the top two hold 21%).
- **Cascades.** 130 (21%): 57 on a boat already turning a penalty, 92 within 15 s of her last call.
- **Line over rules (limit 5).** In 56 of the 316 pre-start calls she fell back to `startKeepClear` in the 5 s before, and never kept the line-crossing heading. Only 1 call is attributable to the fallback. Limit 5 is not a source of fouls.

## What she was doing (first that holds, 602 calls)

| cause in the 5 s before | all | of which holding course from 5 s avoids it |
|---|---|---|
| keep-clear evasion steering for **this** boat | 206 (34%) | 145 |
| keep-clear evasion steering for **a third** boat | 140 (23%) | 86 |
| her own penalty turn (incl. every 21.2) | 142 (24%) | 97 |
| her tack or gybe (51 of the 59 rule 13 calls) | 62 (10%) | 41 |
| a plan turn, no evasion | 42 (7%) | 37 |
| straight, no evasion / line fallback | 10 | 4 |

- **Brain trace.** `isAboutToHit` fired on the called boat before 465 of 505 evaluated calls. The heading toggled 2+ times in 107. A tap was wanted and refused in 92 (boats 48, slow 25, interval 25). Misjudged: 0.

## Answer to question 1 and the decision rule

The fouls are in (a). In 95% of them a heading the evaluator can already produce, on her own tack, would have kept her clear. In 68% that heading is simply the course she was sailing 5 s before. (b) is 2%; (d) is 3%, and 10 s does not rescue it. No one or two rule × geometry cells hold half the fouls.

The fouls are not a missing manoeuvre. The bot turns into the boat she is trying to avoid:

- **Wrong heading choice.** The keep-clear evasion picks a heading from its 5° scan that is worse than holding on. The straight-line prediction (limit 1) reads a turning, slowing or luffing boat as sailing straight. With no memory (limit 4), a "clear for 4.5 s" heading swings back.
- **Penalty and tacks.** Her own penalty turns and tacks are steered into traffic. `tapIsClear` passes tacks that rule 13 then calls.

**Decision rule applied:** (a) holds most of the fouls. Per the ticket, the evaluator's output is right and its inputs are wrong: fix them as targeted build tickets, and **Part B does not start**.

Weighing a second boat (the ticket's (c), 27%, limit 3) overlaps (a): an own-tack heading avoids 164 of those 170 calls in the probe's table. So it is a fix to which heading the scan checks against, not a different evaluator.

## Build tickets from A

Each ticket is measured by the gate's fouls row and by this probe's cause row, on the paired 160 races. Run the rerun command below on the build branch, with this probe cherry-picked.

1. **Prefer holding course when it clears** (cause rows "this boat" + "third boat", up to 346 calls, 231 avoided by holding). Before steering off, `clearingHeading` scores the held course against every boat in range, not only the one `ruleKeepClear` returned on. It keeps a chosen offset until it no longer clears, which is the hysteresis for limit 4. The test predicts a boat that is turning on her yaw rate, not straight (limit 1).
2. **Penalty turns in clear water** (142 calls, 21.2 and the calls she draws while turning; most of the 130 cascades). Before she starts a penalty circle, and while she turns it, she checks the turn's sweep (`turnSweep`) against the boats round her. She delays or bears off to clear water rather than turning through them.
3. **`tapIsClear` against the tack's real track** (rule 13 and tacks: 62 calls; rule 15 after tacks: 58). The refusal test uses the turn track she will actually sail (`tapTrack`) and the other boat's turn, not straight lines.
4. Not a ticket: the pre-start line-over-rules fallback (limit 5) causes 1 call.

## Rerun

```
scripts/heavy.sh swift build -c release --product regatta-roundprobe --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore
scripts/heavy.sh .build/check/RegattaCore/release/regatta-roundprobe --fouls --profile-mix live --tier-mix national --json .prototype/527-fouls.json > .prototype/527-fouls.txt
python3 .prototype/527-strict.py .prototype/527-fouls.json   # the strict recount and cause attribution above
```
