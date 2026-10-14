# #525 step 0: pack scenario, implementation note

## What changed
- `Sources/BotSuite/Command.swift`: `BotSuiteOptions` gains `scenario`, `packCurrent` (with/without/both), `packOffsets`, `packAbove`; flags `--scenario`, `--pack-current`, `--pack-offset`, `--pack-above`; usage text; `validateScenario()` (unknown scenario, refused flags, pack flags without `--scenario`, `--fleet-size` < 3); `BotSuiteCommand.run` branches to `runScenario` (prints the table, writes `--json`, exit 0). Nothing else in that file moved.
- New `Sources/BotSuite/PackScenario.swift`: `PackLayout`/`PackCell` (layout = current, size, offset, gybes), placement (`poses`, `place`, `placedRace`), `sail`, `PackProbe` (entry neighbours, mark used, dirty air, current), `PackRaceResult`/`PackBoatResult`, `PackGroupRow`, `PackReport` (`lines`, `jsonData()`).
- New `Tests/BotSuiteTests/PackScenarioTests.swift`; a bullet in `docs/agents/validation.md`.
- No file under Sources/RegattaCore, Sources/RegattaBots, and none of Harness/Diagnose/DiagnoseReport/Roundings/Report/Matrix/Thresholds.swift changed. The scenario only uses their internals (`BotRaceHarness.raceSetup/raceFiles/windSeed`, `RaceTally`, `RoundingScorer`, `BotSuite.inParallel`) and the public `exportSnapshot`/`importSnapshot` seam. No core change was needed.

## Choices (the brief's defaults taken, plus these)
- Placement at gun + 1 s, offsets -6/0/+6 L, gybes same and mixed, pack re-draw to >= 2 neighbours within 20 m (50 draws, then `PackScenarioError`, exit 2), cap 240 s, `saltings-reach@1` vs `dev-venue@7`, tier national, dirty-air column in, sizes through `--fleet-size`.
- The bunch stream is keyed by seed, size, offset, above and gybes but NOT by current, so a with-current and a without-current race draw the same bunch (paired) and differ in water and wind.
- Bots take their seats with `BotDriver.takingOver()` (they arrive mid-race), tier by `cell.tierMix`.
- I used `RoundingScorer` per boat directly instead of `RaceObserver` (the observer's start/penalty bookkeeping assumes a race from the start; the scorer is what produces `entryToEnd`/`belowTheLine`, same samples as the observer feeds it).
- Pack extra metres: sum of the pack members' entry-to-end extras in a race, mean over the races that held a pack. Tier rows pool the boats of that tier over the races that have one; the race columns (pack held, marks, contacts, calls) are the whole races'.
- Boat contacts a race = sum of the seats' contacts / 2 (the tally counts a contact for both boats). Calls = offender counts. Dirty air = ticks on the gate leg within 80 m of the gate centre with `boat.shadow < 0.85`.
- Race ends when every boat has been on a later leg 15 s (or is no longer racing), or at 240 s after placement; `capped` marks the second.
- JSON: `scenario`, `above`, `rows` (the groups), `races` (each with layout, seed, `tideStateAtGun` (absent for dev-venue), ticks, capped, `maxCurrent`, per-boat results).

## Acceptance -> test (all in `PackScenarioTests`)
1. `sameOptionsSailTheSameRaces` (jobs 1 twice, jobs 4; races and JSON equal)
2. `withoutAScenarioNothingChanges` (options and `--help` flags; the byte-identical plain and `--diagnose` JSON is the tester's diff vs main). `BotSuiteCommandTests` still pass.
3. `boatsAreBunchedAboveTheGate(size:)` 4/5/6 x offsets x gybes x seeds 1-3 x both venues; `offsetsLieOverTheirMarks`; `theBunchIsSeeded`; `anImpossibleBunchThrows`
4. `aBoatIsInAPackWithTwoOthersWithin20Metres`, `entryIsWithin80MetresAndAboveTheGate`
5. `currentIsInTheWithRacesAlone`
6. `reportHasTheColumnsAndOneRowPerGroup`, `columnsPoolTheBoatsAndRaces` (arithmetic by hand)
7. `badUsageExitsTwo`, `aSailedRunExitsZero`
Also `theBunchRoundsTheGate` (a sailed race ends by its rule, every boat rounds).
Run: `scripts/heavy.sh swift test --filter PackScenarioTests --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore -Xswiftc -O` -> 14 tests pass (about 6 s of test time).

## What it expects to move
Nothing: goldens, RegattaBots digests, the bot matrix, render references. Without `--scenario` the only changed output is `--help`.

## Smoke run (debug binary built with -O, `--scenario pack --seeds 1 --jobs 4`, 36 races, 180 boats, 0 capped)
Full table in `/tmp/claude-501/smoke.txt` (may be wiped); the head of it:
```
group            races  boats  pack held  both marks  less-used mark  gate done  extra m mean  median  p90
all                 36    180       0.97        0.67            0.89       1.00          24.0    11.8  61.6
current with        18     90       1.00        0.56            0.83       1.00          17.9     9.0  39.0
current without     18     90       0.94        0.78            0.94       1.00          30.0    20.7  77.7
size 4 / 5 / 6                      0.92 / 1.00 / 1.00 held     extra m mean 15.5 / 27.1 / 27.1
offset -6 / 0 / 6                   0.92 / 1.00 / 1.00 held     both marks 0.50 / 0.92 / 0.58
gybes same / mixed                  0.94 / 1.00 held            extra m mean 21.3 / 26.7
```
For tester: the pack holds at entry in 97% of races (vs 1-4% in the matrix), so the scenario does see packs.
