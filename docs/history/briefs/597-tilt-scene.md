# Brief: #597, the 2.5D race scene for production (from the #596 probe)

Worktree `.claude/worktrees/t597`, branch `build/597-tilt-scene`: cut from `prototype/596-tilt` and merged with
main (owner, 2026-10-23: "start from the existing branch, I really like the look"). The look is signed off from
#596's shots. This ticket is the cleanup that makes the probe shippable: the player setting, the camera-space
layers, quality tiers, tests, fixtures and references. One PR, three layer commits. Read `gh issue view 597`
for the Build and Done lists; they are the contract. The orchestrator (Fable) is your guide: technical
questions go in your report, never to the owner.

## The owner's decisions (final)
- Tilt is a per-device setting: **5…55°, default 45°**, 0 = straight down. Everything (tuning, fixtures,
  references) at 45°.
- The SceneKit fleet draws at every tilt, the floor included. **Today's flat hull/outline/sail sprites go.**
  One render path.
- The 30° "sail wedge" is fine; no fix.
- Boat-up stays boat-up: the squash happens after the camera's rotation (the probe's tilt/rotor pair).

## What the probe left (fix here)
- Edge arrow, hint leader and the wind vane use the unsquashed projection, so they sit off their targets at a tilt.
- `-tilt` ranges 0…80 and defaults 0; `-boats` is a dev flag (keep it, document it in `LaunchOptions`' header).
- No tiers, no tests, no ghost/far/cues-only handling in `Fleet3D`/`Boat3D`; `-hideScene` still renders the SK3DNode.
- `out/596/` and `docs/agents/briefs/596-tilt-prototype.md` are probe artefacts: `git rm` them in layer 1 (history
  keeps them).

## Layer 1: projection + setting (one commit)
- `DeviceSettings.tilt` (Double, default 45, clamped 5…55, defaults key `settings.tilt`), read/written like
  `camera`. `ControlSettings.tilt` with `-tilt` over it (the launch option now 5…55; `LaunchOptions.tilt`
  becomes `Double?`). Fixtures (`-fixture`, `-uitesting`) take the default 45 unless `-tilt` says otherwise.
- `SettingsView`: a "Tilt" row under Camera/Auto zoom, 5…55 step 5 (follow the page's row style: short words, no
  numbers beyond the degrees; see the `pickerRow`/`toggleRow` helpers, add a slider row if none exists). The
  owner's rule: sparse, descriptive UI.
- `GameScene` reads `session.controls.tilt` each frame and eases the tilt node's squash to it over ~0.5 s (a change
  mid-race eases like a camera change; `settled` snaps). `ChartGeometry.obliqueSquash(tiltDegrees:)` stays the one
  place.
- Camera-space layers follow the squash: edge arrow, hint leader (camera children) and the wind vane (cue layer),
  and `ruleCues.update(... rotation:)`: whatever a layer draws in screen space against a world point must use the
  squashed point. Add a `GameScene` helper `screenPoint(of world: Vec2)` and use it everywhere a camera child is
  placed.
- Tests: `new: ControlSettingsTests.tiltDefaultsTo45AndClampsTo5To55`,
  `new: GameSceneTests.cameraLayersFollowTheSquash` (place a mark off-screen at tilt 45, check the edge arrow's
  position equals the squashed projection), `LaunchOptionsTests` for `-tilt` 5…55 and rejection outside.
- UI test for the setting: `new: SettingsUITests.tiltSliderChangesTheRace`: **write it, don't run it** (UI tests
  are CI-only on this Mac; never run `RegattaUITests` locally).

## Layer 2: the fleet and standing things (one commit)
- `BoatNode` keeps: heel shadow, your glow, right-of-way glow, effects (wake, backwind), `setRightOfWayGlow`,
  `hidesDecoration`. Remove the flat hull/outline/sail sprites, `BoatArt.hull/outline/sail` (keep `hullPath`,
  `glowTexture`, `rightOfWayGlow`), `sailLook`/`hullXScale`. Fix every test that read them: the far tier (#127)
  and `-cuesOnly` tests move to `Fleet3D`'s per-boat state (sail hidden; animation detail share).
- `Fleet3D`/`Boat3D` gain: ghost (materials' transparency = `style.ghostAlpha`, limp sail: `ghostSailBelly`);
  `SailDetail.farReduced` (no flutter/luff/belly pump for a far boat, eased as `BoatNode.sailDetailShare` did);
  `hidesDecoration` (sail hidden); `-hideScene` (`paintsWorld` false hides the SK3DNode); the buoys' tone each
  frame from `ChartMarks.tone(of:in:status:legIndex:)` (orange active, grey else), the committee boat white; the
  land rim behind `ChartStyle` (keep it; it only shows on venues with land).
- Tiers (`RenderQualityPolicy`): the serious thermal tier's `SailDetail` cut applies to every boat's camber
  animation; the fleet node has no cheaper tier. `RenderFixtureThermalUITests` (cues identical across tiers) must
  still hold: the hull, mast, boom and sail position never change by tier, only the animation.
- Draw order: the fleet node sits above the fleet layer and below the rule cues as in the probe (z 15); document
  it in `DrawOrder`'s comment.
- Tests: `new: GameSceneTests.tiltedFleetDrawsWithinBudget` (node count of the scene with 10 boats ≤ the flat
  count + 2, where "flat" is main's count recorded as a constant with a comment), `new: Fleet3DTests` for ghost
  alpha, far detail share, hidden sail, buoy tones (pure checks on the SCN nodes' state).

## Layer 3: water depth (one commit)
- The glint band and the ripple-tile wave shader behind `WaterQuality`: at the frozen-ripple tier the wave shader is
  off and the glint is static; otherwise as the probe. Puffs and lulls untouched. `WaterStyle` gains the glint's
  alpha and band position as debug sliders (defaults from the probe).
- Test: `new: WaterNodeTests.glintAndWavesFollowTheQualityTier`.

## Fixtures and references
- Re-record the fixtures on the default class at 45°: `scripts/record-fixtures.sh` (never wrapped in
  `heavy.sh`: it takes the lock itself and deadlocks). Commit the fixtures.
- Render references are adopted from CI after the push (`scripts/adopt-references.sh <PR>`): the orchestrator
  does that. Don't re-record references locally.

## Validation you run (implementer scope only)
- Compile what you touched with its tests: `scripts/heavy.sh --simulator xcodebuild build-for-testing ...` or the
  app build below; run only your new or changed tests with `-only-testing:RegattaTests/<Suite>` through
  `scripts/heavy.sh --simulator`. No `check.sh`, no suites, no bot matrix, no UI tests.
- Local preview per layer (validation.md, Local preview): build, install, launch
  `-demo -seed 5 -boats 10 -camera boat -startSeconds 20 -timescale 1` (the setting's default 45 applies),
  screenshot to `$SCRATCH/597/layer<N>-<what>.png` where `$SCRATCH` is
  `/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/5cd48d17-7d5e-4b04-bf4f-fccc1af04579/scratchpad`.
  After layer 1 also a shot at tilt 5 and one of the Settings page. The orchestrator posts them on #597.

```
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t597
scripts/heavy.sh --simulator xcodebuild build -project Regatta.xcodeproj -scheme Regatta \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/preview-dd -quiet
APP=$(find .build/preview-dd/Build/Products -name Regatta.app -path '*iphonesimulator*' | head -1)
UDID=983CC37F-13EA-4941-A814-71A228D13151
xcrun simctl install $UDID "$APP"
xcrun simctl launch --terminate-running-process $UDID com.phillreeder.regatta -demo -seed 5 -boats 10 -camera boat -startSeconds 20 -timescale 1
sleep 15; xcrun simctl io $UDID screenshot "$SCRATCH/597/layer1-start45.png"
```

Another session is running simulator tests on this Mac; `heavy.sh` queues on the lock. Builds run in the
foreground with a long timeout, never in the background.

## Commits, budget, report
- One commit per layer (plus the artefact removal in layer 1); `git push -u origin build/597-tilt-scene` after
  each layer's commit so nothing is lost. No PR: the orchestrator opens it.
- Near ~150 tool calls or a very long context: WIP-commit with a handoff note (done, next, gotchas, exact next
  command), push, and return; a fresh agent continues from the note.
- Report: per layer what changed, acceptance item → test (with results), what you expect to move (fixtures,
  references, node counts), the preview paths, deviations and open technical questions for the orchestrator.

## Reading rules
`grep -n` / `sed -n <range>p`, not `cat` of whole files. Start with `git diff main --stat` and the probe's diff
(`git diff main -- Regatta/`), then `Boat3D.swift` whole (it is yours), `GameScene.swift` render and setup,
`BoatNode.swift`, `DeviceSettings.swift`, `ControlSettings.swift`, `SettingsView.swift` rows,
`RenderQualityPolicy.swift`, `WaterNode.swift` ripple. Never read other agents' transcripts or tool-output files.
