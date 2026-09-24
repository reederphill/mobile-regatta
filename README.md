# Regatta

A native iOS take on [Regattatron](https://regattatron.com): top-down dinghy fleet racing with
the Racing Rules of Sailing enforced. Swift, SpriteKit and SwiftUI.

This first cut is single-player against bots. Multiplayer, the lobby and rankings come later.

## Layout

```
Packages/RegattaCore/   The simulation: pure Swift, no UI, unit tested
  Geometry.swift          vectors, angles, line crossings, SAT collision
  Wind.swift              oscillating shifts, left/right bias, drifting puffs and lulls
  Polar.swift             the prototype's boat speed by true wind angle (the race still sails it until #70)
  DataFile.swift          versioned data-file loader: header, schema check, SHA-256 content hash, FileRef
  BoatClass.swift         boat class file schema: hull, polar, momentum, steering, shadow, contact, ease
  PolarTable.swift        polar by TWA × TWS, bilinear, with best upwind and downwind VMG derived at load
  Resources/boat-classes/ boat class files, `<id>@<version>.json`
  Course.swift            windward-leeward course, start/finish line, rounding gates
  Boat.swift              boat state and hull shape
  Rules.swift             Rules 10, 11, 12, 13, 18, 22, 31 — who had to keep clear
  Race.swift              fixed-step race loop: start sequence, OCS, contacts, penalties, finish
  BotBrain.swift          AI helms: start timing, laylines, shifts, roundings, keeping clear
  Random.swift            SplitMix64 and our own range, coin and shuffle mappings
  SimulationVersion.swift simulation version: revision, toolchain, C library, architecture
  Digest.swift            FNV-1a state digest for golden replay tests
  Tests/Goldens.json      golden digests keyed by simulation version
Regatta/                The iOS app
  Game/GameScene.swift    SpriteKit renderer, camera, touch steering
  Game/BoatNode.swift     batched boat sprites, sails, wakes, wind-shadow cones
  Game/GameSession.swift  bridges the race to SwiftUI: HUD, rule-call messages, haptics
  UI/                     menu, HUD, minimap, results
  App/LaunchOptions.swift development and test launch arguments
RegattaTests/           Hosted unit tests for the app
RegattaUITests/         UI tests; screenshots attach to the xcresult
```

The simulation runs at a fixed 30 Hz (`Race.tickRate`), independent of the display (the app renders at
up to 120 Hz on ProMotion). The race clock is an integer `tick`: 0 at the gun, so a 60 s sequence starts
at −1800, and `time` is derived from it, never accumulated. Falling behind means running several fixed
ticks, never one longer step. Everything the rules engine decides lives in `RegattaCore`, so it can move
to a Linux server for authoritative multiplayer.

### Determinism

Races are replayed from their seed and input log (ADR 0002), so on the race server `RegattaCore` must be
bit-for-bit deterministic:

- All randomness comes from the race's `SplitMix64`, mapped with its own `unit()`, `range`, `bool()`,
  `int(in:)` and `shuffle`. No standard-library random APIs, and no wall clock.
- The step path never iterates a `Set` or `Dictionary`: their order depends on a per-process hash seed.
  Look them up by key and iterate arrays.
- `simulationVersion` is `<revision>/<toolchain>/<C library>/<architecture>`. Bump `simulationRevision`
  for any change to simulation output and add its row to `Tests/Goldens.json`; a changed digest without a
  new row fails the golden test. For now the golden sails every seat with `BotBrain`, so bot changes also
  move it, until #59's brain-free race-log replay golden replaces it (ADR 0002: replays never run bots).
- The replay platform is pinned to the `swift:6.3.3-noble` image (by digest, in `scripts/linux-test.sh`)
  on `linux/amd64`: Swift 6.3.3, glibc 2.39, x86_64. Trig uses that platform's libm rather than our own
  implementation: the C library is already part of the simulation version, and iOS clients only have to
  be close. Upgrading the image is a simulation version change.
- Golden digests are asserted only on the replay platform. On macOS the tests check that the digest is
  the same twice in one process and across two processes (`scripts/check-digest-stable.sh`).

### Data files

Boat classes (and later venues, conditions and the rules configuration) are immutable, versioned JSON
files (ADR 0004), loaded from their bytes by `DataFile<Content>(data:)`:

- Every file starts with `schemaVersion`, `id` and `version`. A schema version the build doesn't know
  throws. A file's `FileRef` is its id, version and the SHA-256 of its exact bytes, so a released file
  never changes: tuning ships `<id>@<version + 1>.json` next to it, and old versions keep loading.
  `.gitattributes` stops git rewriting their line endings.
- Files use knots, degrees, seconds and hull lengths; the loader converts them once to m/s, radians and
  metres. Derived values, such as the best upwind and downwind angles, are computed at load, never stored.
- `placeholders` lists JSON Pointers to values that are placeholders awaiting tuning; the loader checks
  each one resolves. `notes` is free text for provenance and is ignored by the loader.

## Building

Open `Regatta.xcodeproj` and run the **Regatta** scheme. Xcode must have the iOS platform that matches
its SDK installed (Xcode → Settings → Components); if it doesn't, the scheme will show no run
destinations.

Run the simulation tests from the command line:

```bash
cd Packages/RegattaCore && swift test
```

Run them on the pinned Linux replay platform, in debug and release (needs podman or docker):

```bash
scripts/linux-test.sh
```

Run the app's unit tests (`RegattaTests`) and UI tests (`RegattaUITests`) on the simulator:

```bash
xcodebuild test -scheme Regatta -destination 'platform=iOS Simulator,name=iPhone 17'
```

UI tests attach screenshots to the result bundle with `attachScreenshot(named:)`.

CI (`.github/workflows/ci.yml`) runs `scripts/linux-test.sh` on Linux, `swift test` plus
`scripts/check-digest-stable.sh` on macOS, and `xcodebuild test` on the iOS Simulator.

### Launch arguments

Parsed by `LaunchOptions`; bad values are logged and ignored.

- `-autostart` skips the menu and starts a race.
- `-demo` starts a race with a bot sailing your boat too. Useful for watching the AI.
- `-perf` starts a 16-boat demo race for profiling.
- `-seed <n>` sails every race on seed `n`.
- `-timescale <n>` runs the simulation at `n`× real time.
- `-uitesting` marks a UI test run. It and `-fixture` hide the Debug FPS, node and draw-count overlay so
  screenshots are deterministic.
- `-fixture <name>`, `-scheme halves|tiller` and `-camera course|boat` are parsed for the render fixtures
  (#62), steering schemes (#112) and camera (#113).

### Profiling

The app emits `os_signpost` intervals on the Points of Interest track: **Sim step**, **Bot brains**,
**Render update** and **HUD refresh**. Profile the Regatta scheme in Instruments with `-perf` and compare
them against the budgets in #27 (sim + prediction < 3 ms, bots < 2 ms). **Sim step** includes the **Bot
brains** inside it, so subtract Bot brains from Sim step when checking the sim budget.

## Playing

- Hold the **left** or **right** half of the screen to steer. Short taps make small corrections.
- **Tack / Gybe** swings you through the wind onto the mirror-image angle.
- Be below the line at the gun. If you're over (OCS), dip back below the line, then start.
- Round the windward mark and leeward mark to port, then finish by crossing the line downwind.
- Dark water is a puff and pale water is a lull. The faint cone behind each boat is its wind shadow.
- Fouling another boat costs a 720°, and touching a mark costs a 360°. Turn circles to serve it.
  Finishing with a penalty unserved is a DSQ.
