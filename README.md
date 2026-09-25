# Regatta

A native iOS take on [Regattatron](https://regattatron.com): top-down dinghy fleet racing with
the Racing Rules of Sailing enforced. Swift, SpriteKit and SwiftUI.

This first cut is single-player against bots. Multiplayer, the lobby and rankings come later.

## Layout

```
Packages/RegattaCore/   The simulation: pure Swift, no UI, unit tested
  Geometry.swift          vectors, angles, line crossings, SAT collision
  Trig.swift              `sin` and `cos` that optimized builds can't merge into `sincos` (Determinism, below)
  WindKey.swift           the 30 s wind windows, a window's key (knot, strength, wobble, puff seed) and the key chain
  WindKeyGenerator.swift  the server-side (or practice) key chain from the wind seed, by HMAC-SHA256
  WindField.swift         the pure keyed wind: Hermite knots between keys, sampled by position and tick
  WindSeedPool.swift      server-only pools of vetted wind seeds per venue × conditions × tide state
  Polar.swift             the prototype's boat speed by true wind angle (the race still sails it until #70)
  DataFile.swift          versioned data-file loader: header, schema check, SHA-256 content hash, FileRef
  BoatClass.swift         boat class file schema: hull, polar, momentum, steering, shadow, contact, ease
  PolarTable.swift        polar by TWA × TWS, bilinear, with best upwind and downwind VMG derived at load
  Resources/boat-classes/ boat class files, `<id>@<version>.json`
  Conditions.swift        conditions file schema: strength range, oscillation, trend, build, puff columns; schema 2 adds the keyed wind's wobble and ramps
  Resources/conditions/   the four conditions files, `<id>@<version>.json`
  WindSetup.swift         the public wind setup drawn from the race seed, its briefing forecast, the venue pairing stub
  Venue.swift             venue file schema: land, pairings with geographic grids, current (docs/venue-file.md)
  Resources/venues/       venue files; `dev-venue@1` stands in until the real venues (#83)
  Course.swift            windward-leeward course, start/finish line, rounding gates
  Boat.swift              boat state and hull shape
  Rules.swift             racing rules in 2025 numbering, who had to keep clear, rule calls
  RulesConfig.swift       rules configuration file schema: incidents, zone, race format (docs/rules-file.md)
  Resources/rules/        rules configuration files; `fleet-rules@1` is the v1.0 fleet race
  Incident.swift          incidents and the array-backed IncidentIndex, keyed by sorted seat pairs
  Race.swift              fixed-step race loop: per-seat inputs, start sequence, OCS, contacts, penalties, finish;
                          keys-only (seedless) races for online prediction, whose tryStep() stops at a missing wind key
  RaceSetup.swift         race setup (seats, laps, race seed, data-file refs) and the separate wind seed
  BoatInput.swift         held input (int8 rudder, ease) and taps (tack/gybe, protest)
  RaceLog.swift           race log: header, inputs as applied, seat events; stable JSON
  Replayer.swift          re-simulates a race log to its final state, never running a bot brain
  Random.swift            SplitMix64, named streams of a seed, and our own range, coin and shuffle mappings
  SimulationVersion.swift simulation version: revision, toolchain, C library, architecture
  Digest.swift            FNV-1a state digest for golden replay tests
  WorldSnapshot.swift     the whole predictable world at a tick; `Race.exportSnapshot()` / `importSnapshot(_:)` (ADR 0005)
  Sources/regatta-replay  `regatta-replay <log>`: replays a race log and prints its final digest
  Sources/RegattaBots/    bots, outside the simulation: they sail seats through the input API (#60)
    SeatController.swift    who sails each seat (human, bot, dropped), swappable at any tick
    BotDriver.swift         10 Hz decisions applied next tick; the bot's own seed, hash(race seed, seat, "bot")
    BotBrain.swift          AI helms: start timing, laylines, shifts, roundings, keeping clear
    FleetRoster.swift       display metadata: which seats are bots, and their sailing names
  Tests/Goldens.json      golden digests keyed by simulation version
  Tests/Fixtures/         the golden 16-seat scripted race log, and a wind seed pool for the loader
Packages/RegattaProtocol/ The race wire protocol: messages, frames and a binary codec, no transport (#63)
  Frame.swift             frame (type, seq, tick) and every message type
  Messages.swift          handshake, race start, resync, snapshot, ping; placeholder payloads for later tickets
  SnapshotWire.swift      the quantised wire snapshot and its field list (what's sent, what's left out and why)
  EventWire.swift         race events on the wire, and who each one is sent to
  WireCodec.swift         little-endian integers, varints, strings; strict decoding
Packages/RegattaClient/   The online race client, over a transport protocol, no sockets or UI (#64)
  RaceClient.swift        one race over one transport: update(now:) reads frames, pings, stamps inputs, predicts
  PredictedRace.swift     the whole fleet predicted on a keys-only Race: snapshot import, re-prediction, Resync
  ClockSync.swift         the server's tick from Ping/Pong: min-RTT offset, per-ping uplink delays
  LeadController.swift    the adaptive lead: uplink delay + jitter buffer + 1 tick, the server's late feedback, ≤ 30 ticks
  InputStamper.swift      held input on change + 200 ms heartbeat, taps; the #26 caps over a sliding window
  ReliableStream.swift    events and wind keys back in order; a lasting gap asks for a Resync
  RaceTransport.swift     the transport protocol the app (#68) and the load client (#67) implement
  FaultInjectingLink.swift  an in-memory link on a virtual clock: seeded delay, jitter, loss, reorder, disconnect
Packages/RegattaServer/   The race server (#65, #67) and the load client; SwiftNIO WebSockets (ADR 0006)
  RaceHost/RaceHost.swift  actor owning one Race: 30 Hz catch-up scheduler, input buffer, snapshots, events, close
  RaceHost/InputGate.swift the #26 caps over a sliding window, strikes to disconnect; the 1 s stamp limit
  RaceHost/HostIO.swift    the clock and seat transport protocols the host is driven through
  RegattaServerKit/        the server as a library: config and the ENV=dev gate, race tokens, races, the endpoint
    ServerConfig.swift       environment variables; dev auth; refuses to start unless ENV=dev
    RaceToken.swift          the signed race token (race, seat, expiry; HMAC-SHA256) a client joins with
    RaceSession.swift        one race: its RaceHost, wall-clock driver, seats, close; the instant-race fleet
    RaceRegistry.swift       running races by id, and nothing else
    SeatConnection.swift     one connection's Hello, JoinRace and hand-off to the host
    WebSocketSeatTransport.swift  a seat's WebSocket as the host's SeatTransport: buffered, never blocks
    Routes.swift             /health and the dev-only /dev/instant-race
    RegattaHTTPServer.swift  the port: HTTP/1.1, upgraded to a WebSocket at /race
  RegattaServer/           the `RegattaServer` executable
  RegattaDevAPI/           the dev endpoints' JSON, shared by the server and the load client
  RegattaLoadClient/       RegattaClient over a NIO WebSocket: scripted helm, bytes and RTT measured
  regatta-loadclient/      the `regatta-loadclient` executable
Regatta/                The iOS app
  Game/RaceDriver.swift   what the app sails a race through: 30 Hz tick clock, tick frames, the interpolated RenderWorld
  Game/PracticeDriver.swift  an offline practice race: owns the Race and on-device bots, latches your input per tick, keeps the log
  Game/VisualCorrection.swift  eases a corrected prediction's drawn position over ~150 ms, snaps past a hull length (online, #68)
  Game/GameScene.swift    SpriteKit renderer, camera, touch steering; reads RenderWorld, never a Race
  Game/BoatNode.swift     batched boat sprites, sails, wakes, wind-shadow cones
  Game/GameSession.swift  hosts a driver and bridges it to SwiftUI: HUD, rule-call messages, haptics
  Game/RaceConfig.swift   a practice race's settings, seeds and seat controllers; roster names and the bot glyph
  Game/RaceViewportPolicy.swift  race-view sizing: letterboxed portrait in any window (G5)
  UI/                     menu, HUD, minimap, results
  App/                    app and scene delegates, launch arguments, acknowledgements
  Info.plist              shipping keys: A12 minimum, scene manifest, launch screen, export compliance
  PrivacyInfo.xcprivacy   privacy manifest (#28)
  Regatta.entitlements    Game Center and App Attest environment
RegattaTests/           Hosted unit tests for the app
RegattaUITests/         UI tests; screenshots attach to the xcresult
```

The simulation runs at a fixed 30 Hz (`Race.tickRate`), independent of the display (the app renders at
up to 120 Hz on ProMotion). The race clock is an integer `tick`: 0 at the gun, so a 60 s sequence starts
at −1800, and `time` is derived from it, never accumulated. Falling behind means running several fixed
ticks, never one longer step. Everything the rules engine decides lives in `RegattaCore`, so it can move
to a Linux server for authoritative multiplayer.

In the app a `RaceDriver` runs the ticks (`TickClock`) and the scene draws the fleet between the last two
(`RenderWorld`: positions lerped, headings the short way round), one tick behind the simulation. Your input
is latched: the scene sends it every frame and the driver applies the latest once per tick. A practice
race's driver is `PracticeDriver`; the online one (#68) wraps the client's prediction the same way.

### Determinism

Races are replayed from their seed and input log (ADR 0002), so on the race server `RegattaCore` must be
bit-for-bit deterministic:

- All randomness comes from the race's `SplitMix64`, mapped with its own `unit()`, `range`, `bool()`,
  `int(in:)` and `shuffle`. No standard-library random APIs, and no wall clock. A new use of a seed takes
  its own stream, `SplitMix64(seed:stream:)`, so it never moves existing draws: `WindSetup` draws from the
  race seed's `"windsetp"` stream, never from the wind seed. The keyed wind is the exception: each
  window's key is drawn from HMAC-SHA256 of the wind seed and the window index, which is one-way where
  SplitMix64 is not (ADR 0001, `WindKeyGenerator`).
- The step path never iterates a `Set` or `Dictionary`: their order depends on a per-process hash seed.
  Look them up by key and iterate arrays.
- `simulationVersion` is `<revision>/<toolchain>/<C library>/<architecture>`. Bump `simulationRevision`
  for any change to simulation output and add its row to `Tests/Goldens.json`; a changed digest without a
  new row fails the golden test. The golden replays a fixed 16-seat input log with no bot brains (ADR 0002:
  replays never run bots), so retuning bots never moves it.
- Every input reaches the race through `Race.apply(_:seat:atTick:)` (held) or `Race.tap(_:seat:atTick:)`, and
  the race logs it exactly as applied. `Race.log` is the race as stored (ADR 0002); `Replayer` and
  `swift run regatta-replay <log>` re-simulate it. The wind seed is kept apart from the public race seed
  (ADR 0001).
- `Race` runs no bots. RegattaBots' seat controllers send each bot's decisions through the same input API,
  so the log holds them as applied and replays never run a brain (ADR 0002). A bot draws only from its
  own seed, `botSeed(raceSeed:seat:)`, never from the race's streams, so retuning bots moves neither
  placement, wind nor the golden, and needs no simulation version bump. Names and bot marks live in
  `FleetRoster`, outside the simulation.
- The replay platform is pinned to the `swift:6.3.3-noble` image (by digest, in `scripts/linux-test.sh`)
  on `linux/amd64`: Swift 6.3.3, glibc 2.39, x86_64. Trig uses that platform's libm rather than our own
  implementation: the C library is already part of the simulation version, and iOS clients only have to
  be close. Upgrading the image is a simulation version change.
- Debug and release builds must replay a race identically. Swift doesn't fuse `a * b + c` into a
  multiply-add, but LLVM merges `sin(x)` and `cos(x)` into one `sincos` call in optimized code, and
  Apple's `__sincos_stret` rounds differently from `sin`. RegattaCore's own `sin` and `cos`
  (`Trig.swift`) shadow the C library's and prevent the merge, so don't qualify them as
  `Foundation.sin` or `Darwin.cos`.
- Golden digests are asserted only on the replay platform, where `scripts/linux-test.sh` also checks
  that debug and release agree on the golden and on RegattaBots' replay race. On macOS the tests check
  that the digest is the same twice in one process, across two processes and in release
  (`scripts/check-digest-stable.sh`).

### Data files

Boat classes, conditions, venues and the rules configuration are immutable, versioned JSON
files (ADR 0004), loaded from their bytes by `DataFile<Content>(data:)`. The venue schema is in
`docs/venue-file.md`; the rules configuration schema in `docs/rules-file.md`.

- Files are UTF-8 JSON. Before anything parses one, the loader refuses other encodings, nesting deeper
  than 512 and a key repeated in one object (parsers disagree on which copy wins, and differently on
  Darwin and Linux), so every parser reads the same document.
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

Run the simulation and bot tests (RegattaCore and RegattaBots) from the command line:

```bash
cd Packages/RegattaCore && swift test
```

and the protocol's, the client's and the server's with `swift test` in `Packages/RegattaProtocol`,
`Packages/RegattaClient` and `Packages/RegattaServer`.

Check everything a change reaches, compiling it all before running any test (flags are in the script):

```bash
scripts/check.sh
```

Run the golden and RegattaBots' replay race in debug and release, and build every package, on the pinned Linux
replay platform (needs podman or docker); `--all` runs every package's tests there too:

```bash
scripts/linux-test.sh
```

The image is `linux/amd64`. On Apple silicon, run it in a podman machine with Rosetta enabled and at least 6 GiB
of memory (for example `podman machine init --rosetta --memory 8192 …`, made the default connection). Without
Rosetta, podman emulates x86_64 with qemu, which is very slow and has deadlocked the parallel build. The build
persists between runs in a podman volume. On the Rosetta machine SwiftPM can now and then fail copying package
resources ("encountered an I/O error (code: 4)", an interrupted read); the script retries that step.

### Race server and load client

`RegattaServer` serves races on one port: `GET /health`, the race WebSocket at `/race` (`Hello`, then `JoinRace`
with a race token, then the race; #18), and in dev `POST /dev/instant-race`. It has dev auth only (no accounts,
no App Attest yet), so it refuses to start (exit status 78) unless `ENV=dev`, and the instant race exists only
there (404 otherwise). It reads:

| variable | default | |
|---|---|---|
| `ENV` | none | must be `dev` |
| `HOST`, `PORT` | `127.0.0.1`, `8080` | where it listens (the container sets `HOST=0.0.0.0`); `PORT=0` picks a free port |
| `RACE_TOKEN_SECRET` | random per process | HMAC key for race tokens, at least 16 bytes |
| `RACE_TOKEN_TTL` | `600` | seconds a race token joins for |
| `SERVER_BUILD` | `dev` | reported in `HelloAck` and `/health` |
| `MAX_RACES` | `64` | races at once |

`POST /dev/instant-race?clients=N` starts a race now for N clients (1…16), with bots filling it to 10 boats,
and answers each client's seat and signed race token. `raceSeconds=S` closes the race S seconds after the gun,
where it stands (the dev race-length override, for e2e runs); `startSeconds=S` sets the start sequence (default 60);
`seed=X` makes it reproducible.

`regatta-loadclient` creates an instant race and sails every seat at once with `RaceClient` on a scripted helm,
then prints each client's bytes down and up (TCP payload, the join included) and its ping round trips. It exits
non-zero unless every client sailed to the race's close; `--check-bandwidth` also fails a client over #27's budget
(5 KiB/s down, under 1 MB per race). `--token` sails one seat of a race made elsewhere; `--json` prints the reports.

```bash
cd Packages/RegattaServer
ENV=dev swift run RegattaServer                    # listening on 127.0.0.1:8080
swift run regatta-loadclient --clients 16 --race-seconds 20 --start-seconds 5 --check-bandwidth
curl localhost:8080/health
```

In a container (Linux, no host-specific dependencies; build `linux/amd64` for the authoritative replay platform):

```bash
podman build --platform linux/amd64 -t regatta-server .
podman run --rm -d --name regatta -e ENV=dev -p 8080:8080 regatta-server
podman exec regatta regatta-loadclient --clients 16 --race-seconds 20 --check-bandwidth
podman stop regatta
```

Bandwidth: with 16 boats a client receives about 3.5 KB/s (a snapshot of about 350 bytes 10 times a second,
plus pongs and events) and joins in about 0.4 KB. Fewer boats send less: about 2.3 KB/s with 10. The 5 KB/s
budget (#27) holds. The 1 MB per race budget is measured only on the short e2e races (8 to 20 s after the
start sequence), where it passes trivially. A race costs the join plus that rate times its length from the join to
the close, so it extrapolates to about 1.7 to 1.9 MB for an 8-minute race (with a 60 s sequence): at the
measured rate 1 MB holds only to about 4.5 minutes. The two budgets disagree for real race lengths; which one
gives way (or whether the snapshot rate changes) is an open question for the product owner.

### Online client

The app races online with `RaceClient` over a `URLSessionWebSocketTask` (`Regatta/Online/`, #68). In a Debug
build the menu has **Race online (dev)**: it asks the dev server at the menu's `host:port` field (default
`127.0.0.1:8080`, the Mac the simulator runs on) for an instant race and joins it. `OnlineDriver` draws the
predicted fleet, shows rule calls, OCS, penalties and finishes only from the server's events, rejoins with a
`Resync` when the connection drops, and raises a lag signal after about 5 s of round trips over 250 ms.

`scripts/e2e.sh` runs the end-to-end check: it builds and starts `RegattaServer` with `ENV=dev` on a free port,
runs `OnlineRaceUITests` on the simulator against it (a short instant race with bots, raced to the close), and
stops the server. The regular UI test run skips that test, saying why, since it has no server.

```bash
scripts/e2e.sh
```

Run the app's unit tests (`RegattaTests`) and UI tests (`RegattaUITests`) on the simulator:

```bash
xcodebuild test -scheme Regatta -destination 'platform=iOS Simulator,name=iPhone 17'
```

UI tests attach screenshots to the result bundle with `attachScreenshot(named:)`.

### Shipping config

The app ships for iOS 18 on A12 or newer (`iphone-ipad-minimum-performance-a12`, which can never be tightened
after v1.0). It uses the scene life cycle and a launch screen, which apps built with the iOS 27 SDK need to
launch, and doesn't set `UIRequiresFullScreen`: on iPad it runs in any window, and the race sequence keeps its
full-screen portrait shape and world area, letterboxed with water (`RaceViewportPolicy`). Menus adapt to the
window. The root view controller prefers a locked orientation only while the race sequence shows; iPhone is
portrait only. `SceneDelegate` forwards the scene's activation state to `SceneState.phase` (`\.sceneState`), since
`@Environment(\.scenePhase)` isn't reliable when UIKit owns the scene.

Signing is done by a person in Xcode (automatic signing, team `8S5TQ65X3B`). The App Attest environment
entitlement is `development` in Debug and `production` in Release (`APP_ATTEST_ENVIRONMENT`). To archive
without signing and check the archived bundle:

```bash
xcodebuild archive -scheme Regatta -destination 'generic/platform=iOS' -archivePath Regatta.xcarchive CODE_SIGNING_ALLOWED=NO
scripts/check-shipping-config.sh Regatta.xcarchive/Products/Applications/Regatta.app
```

`Regatta/Acknowledgements.plist` lists third-party licences for Settings → About. It's generated from the
resolved remote Swift packages and `ThirdParty/<Name>/LICENSE` (plus an optional `VERSION`), so regenerate it
after adding either, and CI checks it's current:

```bash
swift scripts/generate-acknowledgements.swift
```

CI (`.github/workflows/ci.yml`) runs only the jobs a change reaches: `scripts/linux-test.sh` on Linux,
`scripts/check.sh` for the packages plus `scripts/check-digest-stable.sh` on macOS, and `xcodebuild test` on the
iOS Simulator (iPhone, plus the UI tests on iPad), and `scripts/e2e.sh` when the app or server changes. `.github/workflows/ios27.yml` runs on GitHub's Xcode 27 image: it archives with the iOS 27 SDK, checks
the archive with `scripts/check-shipping-config.sh`, launches the app, and runs its tests on iOS 27 iPhone and
iPad simulators. To save macOS minutes it runs only on pull requests that touch shipping config, on main, weekly
and by hand.

### Launch arguments

Parsed by `LaunchOptions`; bad values are logged and ignored.

- `-autostart` skips the menu and starts a race.
- `-demo` starts a race with a bot controller attached to your seat too. Useful for watching the AI.
- `-perf` starts a 16-boat demo race for profiling.
- `-seed <n>` sails every race on race seed `n`, with the wind seed pinned to it too, so the whole race reproduces.
- `-timescale <n>` runs the simulation at `n`× real time.
- `-uitesting` marks a UI test run. It and `-fixture` hide the Debug FPS, node and draw-count overlay so
  screenshots are deterministic.
- `-fixture <name>`, `-scheme halves|tiller` and `-camera course|boat` are parsed for the render fixtures
  (#62), steering schemes (#112) and camera (#113).
- `-online` starts an online dev race at launch (Debug builds), on `-onlineHost <host:port>` or the menu's
  host; `-startSeconds <n>` (1…60) and `-raceSeconds <n>` ask the dev server for a short sequence and race.

### Profiling

The app emits `os_signpost` intervals on the Points of Interest track: **Sim step**, **Bot brains**,
**Render update** and **HUD refresh**. Profile the Regatta scheme in Instruments with `-perf` and compare
them against the budgets in #27 (sim + prediction < 3 ms, bots < 2 ms). **Bot brains** is the seat
controllers deciding before each tick, outside `Race.step()`, so **Sim step** is the simulation alone.

## Playing

- Hold the **left** or **right** half of the screen to steer. Short taps make small corrections.
- **Tack / Gybe** swings you through the wind onto the mirror-image angle.
- Be below the line at the gun. If you're over (OCS), dip back below the line, then start.
- Round the windward mark and leeward mark to port, then finish by crossing the line downwind.
- Dark water is a puff and pale water is a lull. The faint cone behind each boat is its wind shadow.
- Fouling another boat costs a 720°, and touching a mark costs a 360°. Turn circles to serve it.
  Finishing with a penalty unserved is a DSQ.
