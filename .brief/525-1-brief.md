# #525 step 1: hand fixes H1 + H3 at the leeward gate (bots layer only)

Worktree `.claude/worktrees/t525-1`, branch `build/525-1-hand-fixes`, stacked on `build/525-0-pack-scenario` (PR #526, `regatta-botsuite --scenario pack`). PR targets main, review range `origin/build/525-0-pack-scenario..HEAD`. Reimplement from main's code; **never merge or cherry-pick** `origin/prototype/525-gate-planner` (reference: `BotBrain+Gate.swift` hunks `gateTrafficMetres` and `h1GybeMin`, `BotBrain+Conduct.swift` `clearOwing`, `BotVariant.swift` values). No `BotVariant` letters, no env sliders: plain named `static let`s like the existing gate constants.

Owner 2026-10-14 (#525): "Hand fixes H1 + H3 (H2 dropped)", every recommended answer. Ticket 1: "`gateTrafficMetres` in `gateOption` and the one shadow gybe on the rounding gybe (H1), 0.6-hull tap clearance against a boat that owes her room (H3). Moves: RegattaBots goldens, bot matrix; gate mean -0.5 to -2.7 m. Drop H2." Stances: bots sail like real sailors (named situational heuristics, internal, never telegraphed); no orderly bots (nothing slows, queues or keeps off to avoid fouls); fix bots, not rules.

## Goal
Bots at the leeward gate (a) price a crowded or shadowed mark in the pick and gybe once out of dirty air on the rounding gybe, (b) gybe past a boat that owes her mark-room with 0.6 hull lengths clearance, not 1.3. Measured on the pack scenario first, the matrix second. Honest prior: prototype H1 and H3 each moved the 8-boat gate mean inside the 1.6 m noise gap; H2 was most of H's gain and is dropped, so expect about -0.7 m (8 boats) to -1.3 m (16 boats) on the matrix. The pack scenario is the point of this ticket.

## Acceptance (each item has a named test or a tester measurement)
1. H1 traffic: a boat parked on the line to one mark's point makes that mark dearer (`gateCosts`), and a symmetric scene that picks the left mark on main (tie goes left) picks the other. Test fails on main (equal costs). Boats through the gate, behind her, and ghosts add nothing.
2. H1 shadow gybe: on the rounding gybe, shadowed (`b.shadow < dirtyAir`), 45 m or more from her point, she plans the other gybe once on the leg (`plannedTack` flips, `navigate` brings her back on its layline); not a second time that leg; not inside 45 m; not unshadowed. Fails on main.
3. H3: against a boat that owes her mark-room (`b.markRoom` has `entitled == view.seat`, `owing == other.seat`) `tapIsClear` is true at a pass of 0.6 to 1.3 hull lengths and false inside 0.6; the same geometry with no notice is false (1.3 unchanged). Cautious bot scales: 0.6 x `clearanceFactor`. Fails on main.
4. Club gradation unchanged (tester measures): mixed-10 mean place C/R/N stays about 6.0/4.5/3.0, finish shares within 0.03, club calls as offender flat, rule 18.2 not up; all-Club gate gain is not read as a breach by itself.
5. No new fouls (tester measures): racing fouls, calls as offender by rule (10/11/12/13/16.1/17/18.2), mark touches per boat, pack-scenario contacts/race, touches/race, calls/race not above main beyond noise. Prototype warning: every H variant had 16-boat racing fouls about +5% (686 -> 696-724); H3 alone 720.
6. Pack scenario default sweep (576 races): extra m mean and pack extra m not above main; direction read across the group rows (size, offset, gybes, current), not one row. Matrix gate mean not worse than main beyond noise (below).
7. Without a boat in range nothing changes: a single-boat gate scene is bit-identical (H1 term 0, H3 inert).

## Files and hook points (cites on this base, `Packages/RegattaCore`)
- `Sources/RegattaBots/BotBrain+Gate.swift`: constants block :17-67 (add H1's after `gateRecoverUp` :61, before `gateExitSeconds` :65); `gateOption` :121-149 (`let cost: Double` :136 -> `var`, add the traffic metres before `return GateOption` :147; the pick compares `cost`, `gateCosts` :152 exposes it, `picksLeftGateMark` :159 keeps `gateRepickMetres` 10 m); `gateAim` :174: `let l/r` :198, `if b.tack == mine.needs` :205, `guard deeper else` :212, then `gateCommitted = ` :214. Put the shadow gybe between :212 and :214.
- `Sources/RegattaBots/BotBrain.swift` :196-201: new `var gateShadowGybeLeg: Int?` beside `gateCommitted`.
- `Sources/RegattaBots/BotBrain+Conduct.swift`: `static let tapClearance = 1.3` :66 (add the owing constant beside it); `tapIsClear` :266-292 (`let clear` :270 becomes per boat); `keepClearRule` :113-118 shows the notice test. `Sources/RegattaBots/BotBrain+Cautious.swift` :67/:75 `clearanceScale`, `tapClearanceLengths`; `tapApproach` :274 takes the same `clear`.
- Reads: `view.wake.factor(at:tick:receiver:)` (`WakeRibbons.swift` :272), `TurbulenceRibbons.tick(after:from:)` :75, `BotBrain.dirtyAir` = 0.85 (`BotBrain+Tactics.swift` :390), `SeatView.OwnBoat.markRoom` / `MarkRoomNotice` (`SeatView.swift` :230, :336). No RegattaCore change.
- #523 is on main: do not re-add `isNearHerMark` defer or `gateExit`.

## H1 design (prototype values, hand-set, all named lets)
Traffic, in metres, added to `cost` of each mark's `GateOption` ("avoid the crowded mark"): for each non-ghost boat that is below her (`rel.dot(up) < 0`), on the way (`0 < along < length + 5`) and not already through the gate (`up.dot(other - gate.centre) > -3`): if its offset from the line to the point is under `gateTrafficNear = 25` m, add `gateTrafficBoatMetres = 30 x (1 - off/25)`. Plus shadow: four samples along the line, loss `1 - view.wake.factor(...)` at the arrival tick (`tick(after: length*f/max(speed,1))`) times `length/4`, summed, weighted `gateTrafficShadowWeight = 1.5`. Why: 30 m is about a gybe and a half (`gateGybeMetres` 20, `gateMarkGybeMetres` 35), enough to flip a close pick, not a far one; linear fade so a boat nearby on the line matters most. Boats are read where they are now.
Shadow gybe ("gybe out of dirty air, once"): on the rounding gybe, past `guard deeper`, if `b.shadow < Self.dirtyAir`, `mine.distance >= gateShadowGybeMetres = 45` (room to come back before `gateStraightRange` 30), and `gateShadowGybeLeg != b.legIndex`: set the leg, `plannedTack = b.tack.other`, `return navigate(b, to: mine.entry, view)`.
Risk to watch: the traffic term jumps by up to 30 m when a boat crosses the line, against a 10 m repick margin, so the pick may flip-flop (the planner's regression). Count pick changes a rounding in a trace; if it flips, damp it (smooth fade) rather than widen `gateRepickMetres`.

## H3 design
One helper (e.g. `tapClearanceLengths(for other, _ b, _ view)`): `Self.tapClearanceOwing = 0.6` when `b.markRoom.contains { $0.entitled == view.seat && $0.owing == other.seat }`, else `tapClearance`, both times `clearanceScale`. Use it for that boat's `clear` in the circle test, the straight test and `tapApproach`. Why 0.6: the boat that owes room must keep clear of her, so the gybe may pass close; 1.3 refused gybes at the gate and left her on the wrong gybe. The prototype tried only 0.6 (not swept). Not telegraphed; internal.

## What it moves (tester and orchestrator, not the implementer)
- Digests: core `GOLDEN` must not move. `BotHandTackTests.skiffEightBotsAreBitIdentical` long digest (`hex64(long)`, seed 462, two laps) will likely move, as in #523: the fixer re-pins it with the comment extended. `REGATTABOTS replay digest` and `GOLDEN` lines from the CI Linux log; #524 committed no row for them. Render references: none expected.
- Bot matrix, once on this Mac after the last fix round, run by the orchestrator: `scripts/bot-matrix.sh --profile-mix live --tier-mix national --tier-mix mixed --seeds 16`.
- Tester sweeps (release binary, `scripts/heavy.sh`, one at a time; build per validation.md, "Bot diagnosis"). BIN = `.build/check/RegattaCore/release/regatta-botsuite`; base = `041d0c17` (step 0 tip, same bot code as main), built in `.claude/worktrees/t525-0` (copy its binary to the scratchpad before it is pruned), branch built here. Same command on both, outputs to the scratchpad, compare the `gate` rows (extra m, entry to end, over, below the line, still below, p90), `calls`, `fouls`, tier places:
  - 8 mixed: `$BIN --profile-mix live --laps 2 --diagnose --tier-mix mixed --fleet-size 8 --seeds 8`
  - 16 mixed: same with `--fleet-size 16 --seeds 4`
  - all-Club 8: `--tier-mix club --fleet-size 8 --seeds 8`
  - all-National 16: `--tier-mix national --fleet-size 16 --seeds 16` (160 races, 3-4 min)
  - mixed 10: `--tier-mix mixed --fleet-size 10 --seeds 16` (tier places, club calls)
  - noise sets (no seed-start flag): copy `Sources/BotSuite/matrix.json` with `"seeds": [9,...,16]` (8 boats) and `[5,...,8]` (16 boats) and pass `--matrix <file>` instead of `--seeds`. Prototype noise on main: 1.6 m (8 boats), 0.7 m (16). A move inside it is not a finding. Prototype main references (gate mean): 17.6 / 20.4 / Club 15.2 / National-16 24.9 / mixed-10 18.0.
  - pack, default: `$BIN --scenario pack --json <f>` (576 races, about 36 s; main baseline in `.claude/worktrees/t525-0/.brief/525-0-baseline.txt`, regenerate on the base binary); also `--tier-mix mixed` and `--fleet-size 6`. No noise flag: split the JSON's races by seed 1-8 against 9-16 to read it. Main: pack held 0.84, extra m mean 33.5, pack extra m 108.5, contacts/race 0.94, calls/race 0.67.
  - cost: `BotBenchmarkTests` filtered once, branch against base.

## Implementer rules
- Compile with `scripts/heavy.sh swift build --build-tests --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore -Xswiftc -O`; run only your new tests, `scripts/heavy.sh swift test --filter BotGateTests` / `BotConductTests` style filters on the names you add, red first on main where you can. No `check.sh`, no suites, no matrix, no push.
- Tests: extend `BotGateTests` (`scene(...)` :83 places seat 1 400 m away; move or add boats with an `exportSnapshot`/`importSnapshot` edit as `noSpeedBuildBetweenPickAndMarkRange` does; `#require` a shadow under 0.85 before the gybe test). H3: take real notices from `BotConductTests.markRoom(seed:abeam:ahead:)` (seat 0 inside is entitled, seat 1 owes), `place` :83.
- Commit locally, no rebase (merge the step-0 branch only if it moves). Write `.brief/525-1-impl-note.md` (not committed, as step 0): changes, acceptance -> test, expected moves.
- Near ~400K context or ~150 tool calls: WIP commit with the handoff in its message and `.brief/525-1-handoff.md` (done, next, gotchas, exact next command), then return.
- Update the header comment of `BotBrain+Gate.swift` and the doc comments of `tapIsClear`; one line each on the new heuristics. No `CONTEXT.md` change.

## Open choices (recommended default first)
1. Tiers: all tiers, as measured (place gap held in `H-10`). Fallback if Club gradation moves: gate H1's shadow gybe on `tactics.gybesOutOfShadow` (National top, #366 ramp) and the traffic term on `seeksClearAir`. Tester decides from item 4.
2. H1 or H3 alone failing items 5-6: drop the failing fix and ship the other; the orchestrator decides, the fixer does not tune past ~45 min / 3 variants.
3. Mark-room notice only (`entitled`/`owing`), not any boat to leeward: yes. Rule 18.3 tacking notices count as the prototype's did (same test); revisit if 18.2 calls rise.
4. Traffic read from boats' positions now, not predicted: yes (a roll-out is the planner's, step 2).
5. Add a `--seed-start` flag to the suite for noise sets: no (matrix file instead); not this ticket.
