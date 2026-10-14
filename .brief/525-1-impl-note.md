# #525 step 1 impl note (H1 + H3)

Branch `build/525-1-hand-fixes` on `build/525-0-pack-scenario` (041d0c17). Bots layer only; no RegattaCore change.

## Changes
- `BotBrain+Gate.swift`: constants `gateTrafficNear` 25, `gateTrafficBoatMetres` 30, `gateTrafficShadowWeight` 1.5, `gateShadowGybeMetres` 45, and ONE ADDITION BEYOND THE BRIEF `gateTrafficSeconds` 12 (see below). `gateTrafficMetres(to:...)` (boat term + 4-sample wake term, as the prototype; single-boat / ghosts-only scene returns 0 before any wake read). `gateOption` adds it to `cost` (`GateOption.traffic` carries it). Shadow gybe in `gateAim` between `guard deeper` and `gateCommitted`.
- `BotBrain.swift`: `gateShadowGybeLeg`, `gateTraffic` (smoothed per-mark traffic).
- `BotBrain+Conduct.swift`: `tapClearanceOwing` 0.6; `tapIsClear` `clear` per boat. `BotBrain+Cautious.swift`: `tapClearanceLengths(for:_:_:)` (0.6 x clearanceScale when `markRoom` has entitled == view.seat, owing == other.seat; else the old 1.3 x scale).
- Digest re-pin: `BotHandTackTests.skiffEightBotsAreBitIdentical` long digest 0x92df68b4d1064722 -> 0xf802fb1dd21dc2b9 (short unchanged); comment extended.

## Beyond the brief: traffic smoothing (pick flip-flop, the brief's named risk)
Trace: 16 races seeds 462-477, 8 bots skiff@8 six rules, 900 s, count of `gatePick.left` changes within one rounding (128 roundings):
- main-equivalent (traffic constants 0): 120 with 0 changes, 8 with 1.
- traffic unsmoothed: 58 with 0, 34 with 1, 29 with 2, 6 with 3, 1 with 4 (70 of 128 changed). Boats-only term was the source (shadow-only: 119/9). Pattern: she picks the clear mark at 40-70 m above with 25-40 m on the other, 5 s later the boat has sailed through and the pick flips back.
- exponential blend of the per-mark traffic over the leg (time constant `gateTrafficSeconds`): 8 s -> 20 changed roundings; 12 s -> 17 (15 with 1, 2 with 2); 15 s -> 13. Shipped 12 s. Variants tried: 3 (8/12/15). `gateRepickMetres` untouched. `gateCosts` stays instantaneous (acceptance 1); the pick uses cost - traffic + blended. First decision on a leg: blended = instantaneous.
The tester should read the pick-change count again in the pack scenario; if lag hurts (a crowded mark stays dear after the boat is through), 8 s is the alternative.

## Acceptance -> test
1. H1 traffic: `BotGateTests.aBoatOnTheLineToAMarkMakesItDearer` (left +30 exactly, right unchanged, symmetric close pick flips left -> right; half-way off +15; through the gate / behind / ghost / 25 m off add 0). Red on base (stubbed to 0).
   Also `aBoatThatSailsOnLeavesTheMarkDearAWhile` (blend), `noBoatInRangeAddsNothing` (item 7 term).
2. H1 shadow gybe: `BotGateTests.gybesOutOfDirtyAirOnceOnTheRoundingGybe` (both tacks; once; not second time; not at 40 m; not unshadowed). Red on base.
3. H3: `BotMarkRoomTapTests.gybePastABoatThatOwesHerRoom` (passes 0.45..1.6 with real notice vs none; true from 0.6 vs 1.3) and `onlyABoatThatOwesHerRoomAndTheCautiousScale` (she-owes stays 1.3; cautious 0.6 x factor). Red on base.
4-6. Tester: club gradation, no new fouls, pack sweep, matrix (not run).
7. Single-boat gate scene bit-identical: `gateTrafficMetres` returns 0 with no non-ghost other (guard before the wake read); H3 inert with no notice; shadow gybe is the one new branch and fires only when shadowed (single boat is unshadowed). No test beyond `noBoatInRangeAddsNothing`; the digest short test (start + first beat, no gate) unchanged.

Ran: BotGateTests, BotMarkRoomTapTests, BotHandTackTests, BotConductTests.scriptedEncountersZeroFoulsAtSkill1 - all pass. Not run: anything else.

## Expect to move
- `skiffEightBotsAreBitIdentical` long digest (re-pinned here); REGATTABOTS replay digest and GOLDEN rows from CI Linux log (core GOLDEN must not move).
- Gate mean on the matrix about -0.7 m (8) / -1.3 m (16) per the prior; pack scenario is the point.
- Watch: 16-boat racing fouls (prototype +5% for every H variant), 18.2 calls (H3 includes rule 18.3 notices), Club gradation (open choice 1 fallback: gate shadow gybe on `tactics.gybesOutOfShadow`, traffic on `seeksClearAir`), pick changes per rounding (17/128 on this trace vs 8 on main).
