# #525 step 1 fix round 3: still-below classification, deep tail, sailed far-mark test

origin/main had not moved (25238c7a is an ancestor of HEAD), so nothing was merged.

**Brain code: unchanged.** Two variants were tried and reverted (see below). This commit adds a test only.

The time box was overrun. The owner's mid-round ask (deep outliers, tails base vs HEAD) needed a full base and HEAD tail run, about 25 min each.

## Verdict

- **The 11 still-below are a mix of modes.** No one fix in the round 2 code removes them.
- **The deep tail is a real regression on HEAD, and it has one shape.**
  - She crosses the gate's line on the gybe that does not round her mark.
  - The gybe round the mark below the line then comes 15 to 45 m deep.
  - HEAD's growth is in boats that hold the wrong gybe from far out: 8 on base, 59 on HEAD, over the 4 sets.
- **The new sailed test reproduces it.** On 7814c4b0 the bot fails it from 30 and 40 m up.

## How

- I wrote a temporary trace test in BotSuiteTests. It was not committed; a copy is `.brief/525-1-fix3/TmpGateTrace.swift.keep`.
- It sails each matrix cell like `BotRaceHarness.run`, with the same seats, tiers and drivers. For every boat at the gate it records the following each 0.5 s:
  - along and up from the gate's centre
  - twa and speed
  - tack, `plannedTack`, `gatePick`
  - penalties owed
  - `planingAimed`
  - the current
- **Per rounding:** deepest below the line (course axis) from the gate leg to 15 s after its end, and whether she is still below then.
- **Agreement with the suite** (`--diagnose` "still below"):
  - Exact on m8 (11 HEAD, 6 base), m8n and club8.
  - nat16 reads 59 HEAD and 72 base, against the suite's 54 / 67. My sampling is every 0.5 s and uses the course axis, not the line's normal.
- **Base runs:** I checked out 6fc061d2's `Sources/RegattaBots` and `Tests/RegattaBotsTests`, moved `BotMarkRoomTapTests` aside, and rebuilt in the same scratch dir. HEAD was restored afterwards.

## 1. The 11 still-below roundings (8-mixed s1-8, HEAD)

| # | cell | seat / tier | mark | deepest | on base | mode |
|---|---|---|---|---|---|---|
| 11 | saltings gusty s8 | 7 national | L (needs P) | 81.5 | new | A + pick flip L>R at 39 m up, gybe to R refused, she ran down outside L; pick back to L, gybed to S 8 m up outside L, 2 penalty turns at the mark, crossed on S, turns below the line |
| 9 | saltings gusty s4 | 6 club | L (P) | 57.7 | new | B: on S (wrong gybe) from 55 m up, set-up aim, rounding gybe planned at 14 m up (9 m/s) then dropped; crossed on S at 8.3 m/s, gybed at -43 |
| 8 | saltings gusty s3 | 0 regional | L (P) | 56.3 | new | A |
| 10 | saltings gusty s5 | 2 national | L (P) | 43.6 | on base | A |
| 6 | hollin sea-breeze s4 | 7 club | L (P) | 29.3 | new | C: pick flip L>R at 33 m up beside L, gybe toward R refused, held a reach on P away from R, 25 m outside L, pick back to L, gybed to S 7 m up, 1 penalty, crossed on S |
| 1 | dev light s1 | 7 regional | R (S) | 17.2 | new | D |
| 2 | dev light s2 | 5 club | L (P) | 17.6 | new | D (after a penalty turn up the leg) |
| 3 | fellmere light s1 | 6 club | R (S) | 17.9 | new | D (pick L>R at 20 m up, on the rounding gybe for R) |
| 4 | fellmere light s5 | 5 club | L (P) | 11.6 | on base | D |
| 5 | hollin classic s8 | 7 national | L (P) | 19.5 | on base | D (dirty air on the beat out) |
| 7 | saltings classic s3 | 2 club | R (S) | 18.4 | new | D, with the current setting her down 0.66 m/s |

**Modes:**
- **A, current set past her point** (saltings gusty-offshore, 3 of 11, 1 also on base):
  - On the rounding gybe P she is set outside her point by the cross-gate current (0.5 to 0.8 m/s). The planing heat-up adds to it: asked 177°, sailed about 157°.
  - She arrives above or outside L 10 to 30 m up. The point is then on the other side, so the `!onOwn` branch gybes her onto S 8 to 17 m up.
  - `gateSetUp` reaches at 100° for 1 to 2 s, then returns nil within `gateSetUpLow`. She crosses inside on S at about 8 m/s.
  - The gybe round the mark is refused for 4 to 6 s while she runs dead downwind (`refusedTurnAim`), and she lands 30 to 80 m deep.
- **B and C** (1 each, both Club):
  - B: the set-up gybe comes too late on the plane.
  - C: H1's traffic flips the pick at about 35 m up, and the gybe it then asks for is refused in the pack.
- **D, clean roundings** (6 of 11, 2 also on base):
  - She crosses on the rounding gybe at her point. In light air (3 to 4 m/s) the rounding luff lags the ask by 30 to 50°, so she rounds 12 to 17 m below.
  - The beat back hasn't regained the line 15 s on (last -1.9 to -6.8 m).
  - This is main's rounding plus the threshold, not round 2 code.
- **W1** (Club 9 -> 22 still below in 8-boat sets): of the 6 Club cases here, 4 are D, 1 is B and 1 is C. No Club-specific signature in the gate code. D is plausibly Club's slower luff, which is not touched by this branch.

## 2. The deep tail, base vs HEAD

Roundings deeper than 20, 30 and 40 m, and the deepest (m):

| set | n (b / H) | > 20 m | > 30 m | > 40 m | max | still below |
|---|---|---|---|---|---|---|
| 8-mixed s1-8 | 635 / 634 | 20 / 23 | 4 / **10** | 2 / **4** | 45.1 / **81.5** | 6 / 11 |
| 8-mixed s9-16 | 639 / 639 | 16 / 22 | 7 / 10 | 3 / 3 | 45.5 / 45.2 | 7 / 8 |
| all-Club 8 | 636 / 636 | 14 / **22** | 4 / 7 | 0 / 1 | 38.3 / 46.5 | 5 / 11 |
| all-National 16 | 2550 / 2547 | 173 / **238** | 48 / **88** | 15 / **27** | 67.3 / **81.9** | 72 / 59 |

- Base and HEAD share few deep boats. Same boat over 30 m on both trees: m8 3, m8n 5, club8 3, nat16 12.
- Raw rows: `.brief/525-1-fix3/tails-<set>-<base|head>.tail.txt`.

Shape of every rounding over 30 m (`classify.py`, all 4 sets):

| | base (69) | HEAD (115) |
|---|---|---|
| crossed on the wrong gybe, having gybed onto it 0-20 m up | 40 | 36 |
| crossed on the wrong gybe, held it from far (no gybe in the last 60 m) | **8** | **59** |
| crossed on the wrong gybe, gybed onto it above 20 m | 5 | 7 |
| crossed on the rounding gybe | 10 | 13 |

- **The growth is "held the wrong gybe from far".** In nat16 these are typically boats sent to R on P down the middle:
  - They cross near the gate's centre (along 0 to 7 m) at 7.5 to 8.7 m/s.
  - Their first gybe is 12 to 41 m below the line.
- **On base** the deep ones are mostly the gybe-round-the-mark path that round 2 targeted, and HEAD did cut that path (40 -> 36).

**Mechanism** (the sailed test, traced per tick, matches the suite's shape):
1. `gateSetUp` sails her across above her point on a reach (about 115° off the wind) toward the set-up point.
2. She plans the rounding gybe only when her point bears past dead downwind, about 19 m up.
3. By hand from a 115° reach the gybe is a turn of about 65° at about 14°/s, so the turn runs over 4 s.
4. `handTurn` was on from 3.1 s, with `canTap` false only because the turn was already running; isClearToTurn, room and evasion were all clear.
5. At 6 to 8 m/s, 4 s is the whole 19 m. She crosses the line with the turn unfinished, on the wrong gybe, then the gybe round the mark comes deep.
- **Minor:** `navigate`'s reach branch sets `plannedTack = b.tack`, which drops `gateSetUp`'s planned gybe. Re-asserting it (variant 2) kept "plan P" to the line in the trace, but the boom still did not cross before the line, so it is not the cause.

## Variants tried (both reverted)

- **v1, current allowance in `gateOption`:**
  - What: steer for her point upstream by `currentAllowance`, as `navigate` does. This matters for mode A; it does nothing for Club, whose current sense is 0.
  - 8-mixed s1-8: still below 11 -> 11, gate mean 15.0 -> 15.0.
  - 8-mixed s9-16: 8 -> 7.
  - all-Club 8: identical.
  - It fixed s5 (#10) but not s3/s8. It does not pay. Outputs: `.brief/525-1-fix3/*-v1.txt`.
- **v2, re-assert `plannedTack` after `navigate` in `gateSetUp`:** the sailed test was still red, for the reason above. Not measured on the suite.

## Suggested next fix (not done; the box was overrun)

**Start the set-up gybe early enough to finish it above the line.** Two ways:
- Test her point's side from where she will be after the turn: her position plus her velocity times the hand-gybe time, from `steering.turnRate(speed:)` and the turn from her angle through dead downwind.
- Or keep the set-up aim near her groove, so the gybe is a short turn.

The sailed test is the acceptance. The deep-tail table above is the measure: the "held from far" row and nat16's >30 / >40.

Fallback C (round 1 note) also removes it, at the cost of the gain.

## Tests

- **New `BotGateTests.farMarkSailedSheCrossesOnTheRoundingGybe`:**
  - Setup: the far-mark scene, posed 28 m out past her mark, 30 and 40 m up, both gybes, with a boat stopped 6 m above the other mark's point to hold the pick. Default class, sailed with `track`, 30 s.
  - Asserts: she keeps her pick, is on the rounding gybe at the crossing, and gybes exactly once before the line.
  - **Red on 7814c4b0 in all 4 cases** (crosses on the wrong gybe, 0 gybes). It is red with `gateSetUp` disabled too, so today it does not tell gateSetUp from no gateSetUp. It is a finding.
  - It is committed inside `withKnownIssue`, so the gates stay green. It turns red ("known issue not recorded") once the bot passes, and then `withKnownIssue` comes off. It was not weakened.
- `swift test -Xswiftc -O --filter "BotGateTests|BotMarkRoomTapTests|BotHandTackTests|PackScenarioTests"`: 48 tests pass, 8 known issues, all in the new test.
- Digest: no brain change, so nothing to re-pin.

## Doc check: `PackLayout.offset`

- **The comment is right; no edit.**
  - `CourseLayout.derive` puts the gate's left mark at `gateCentre + right * halfGate`, with `right = upwind.rightPerp`.
  - `PackScenario.poses` puts the bunch at `gate + right * offset * hull`.
  - So +6 is over the left mark (mark 0 in `markUsed`).
- Checked by placing seed 1, size 5: at +6 the bunch's mean along (left -> right) is -25.7 m, nearer the left mark; at -6 it is +33.2 m.
- **So the tester's observation reads the other way:** a bunch at -6 (over the right mark) rounds mark 0, the left, about 80% of the time. The bunch mostly goes to the far mark. Their "near" proxy in report 2, owner addition 3, is therefore the far mark, and their near/far rows are swapped.

## Tester must re-test

Nothing. Only a test was added, inside `withKnownIssue`; there is no brain or comment change. The next brain round should re-run the deep-tail table with `.brief/525-1-fix3/tails.sh` (it needs `TmpGateTrace.swift.keep` copied into BotSuiteTests).
