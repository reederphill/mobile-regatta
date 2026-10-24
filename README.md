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
  BoatClass.swift         boat class file schema: hull, polar, momentum, steering, shadow, contact, ease; schema 3
                          adds planing, the automatic spinnaker, by-the-lee loss and the averaged groove wind
  PolarTable.swift        polar by TWA × TWS, bilinear, with best upwind and downwind VMG derived at load
  Sails.swift             the automatic spinnaker's states and the planing hysteresis (#248)
  Resources/boat-classes/ boat class files, `<id>@<version>.json`; races sail `skiff@9` by default
  Conditions.swift        conditions file schema: strength range, oscillation, trend, build, puff columns; schema 2 adds the keyed wind's wobble and ramps
  Resources/conditions/   the four conditions files, `<id>@<version>.json`
  WindSetup.swift         the public wind setup drawn from the race seed, its briefing forecast
  Venue.swift             venue file schema: land, pairings with geographic grids, current (docs/venue-file.md)
  Resources/venues/       venue files: the real venues `hollin-bay@1`, `saltings-reach@1`, `fellmere@1` (#83); races
                          sail `dev-venue@2` by default until practice setup picks a venue (#131)
  VenueCheck.swift        the offline venue check: each pairing's course clear of land, grids covering it (#83)
  VenueSailability.swift  the offline sailability check: upwind progress in a 25 % lull at peak current (#14)
  CourseLayout.swift      the course derived from the files and race seed: marks, gate, lines, race area, start row
  Course.swift            rounding rays and obstacles, shared by the course and the rules
  Boat.swift              boat state and hull shape
  Rules.swift             racing rules in 2025 numbering, who had to keep clear, rule calls
  MarkRoom.swift          rule 18: each boat's mark zone, when rule 18 applies, the inside boat, fetching, the record
  EscapeSimulation.swift  rules 15 and 16.1: room judged by sailing the keep-clear boat's candidate inputs on the umpire's recorded track; 43.1(b)
  RulesConfig.swift       rules configuration file schema: incidents, zone, race format (docs/rules-file.md)
  Resources/rules/        rules configuration files; `fleet-rules@8` (the default) is the v1.0 fleet race
  Livery.swift            liveries (#118): design, safe-palette colours, sail number; OKLab and the swatch rule
  LiveryCatalogue.swift   livery catalogue file schema: designs per boat class, safe palette, bot and new-player liveries
  Resources/liveries/     the livery catalogue, `livery-catalogue@1`
  Incident.swift          incidents and the array-backed IncidentIndex, keyed by sorted seat pairs
  Race.swift              fixed-step race loop: per-seat inputs, start sequence, OCS, contacts, penalties, finish;
                          authoritative or prediction mode (seedless, no umpire; tryStep() stops at a missing wind key)
  RaceFiles.swift         resolves a setup's data-file refs (catalog, then bundle), hash checked; the bundled defaults
  UmpireState.swift       the authoritative race's umpire memory: open incidents, rule 18 records and zone presence, the recorded track
  RaceSetup.swift         race setup (seats, laps, race seed, data-file refs) and the separate wind seed
  BoatInput.swift         held input (int8 rudder, ease) and taps (tack/gybe, protest)
  RaceLog.swift           race log: header, inputs as applied, seat events; stable JSON
  Replayer.swift          re-simulates a race log to its final state, never running a bot brain
  Random.swift            SplitMix64, named streams of a seed, and our own range, coin and shuffle mappings
  SimulationVersion.swift simulation version: revision, toolchain, C library, architecture
  Digest.swift            FNV-1a state digest for golden replay tests
  WorldSnapshot.swift     the whole predictable world at a tick; `Race.exportSnapshot()` / `importSnapshot(_:)` (ADR 0005)
  Sources/regatta-replay  `regatta-replay <log>`: replays a race log and prints its final digest
  Sources/regatta-venue-png `regatta-venue-png [dir] [venue@v ...]`: an overview PNG per venue pairing into docs/venues (#83)
  Sources/RegattaBots/    bots, outside the simulation: they sail seats through the input API (#60)
    SeatController.swift    who sails each seat (human, bot, dropped), swappable at any tick
    BotDriver.swift         10 Hz decisions applied next tick; the bot's own seed, hash(race seed, seat, "bot")
    BotBrain.swift          AI helms on the autohelm (#231): steer to a wind angle, centre, tap to tack; start timing, laylines, roundings, keeping clear
    BotBrain+Tactics.swift  what a bot plays off the groove: shifts, planing, puffs, clear air, covering (live bots by skill, or a profile)
    BotProfile.swift        the bot suite's scripted profiles: baseline (groove only) and tactician (#231), blip-tacker (#238), hunter (#355), executor and Club-execution tactician (#105)
    FleetRoster.swift       display metadata: which seats are bots, and their sailing names
  Sources/BotSuite/       the headless bot-race suite (#97): harness, matrix, per-seat metrics, per-tier gate, the skill-gap gate (#231), the fun-pass gate (#238), JSON report; #105's mixes (execution, cautious, rivals, rank stability), the 16.1 watchdog and the placeholder keys #389 sets
  Sources/regatta-botsuite `swift run -c release regatta-botsuite [--profile-mix <mix>] [--json <path|->]`: sails matrix.json, exits 1 on a breach; CI's botsuite.yml runs it on main and nightly
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
  RegattaServerKit/        the server as a library: config and the ENV gate, race tokens, races, the endpoint
    ServerConfig.swift       environment variables; ENV dev, staging or production and what each requires; the App Attest bypass
    RaceToken.swift          the signed race token (race, seat, expiry; HMAC-SHA256) a client joins with
    RaceSession.swift        one race: its RaceHost, wall-clock driver, seats, close; the instant-race fleet
    RaceRegistry.swift       running races by id, and nothing else
    SeatConnection.swift     one connection's Hello, JoinRace and hand-off to the host
    WebSocketSeatTransport.swift  a seat's WebSocket as the host's SeatTransport: buffered, never blocks
    Routes.swift             /health, the dev-only /dev/instant-race and /dev/situation, and /admin/ (#154)
    RegattaHTTPServer.swift  the port: HTTP/1.1, upgraded to a WebSocket at /race or /service
    ServiceEndpoint.swift    one /service connection (#145): handshake, session calls, the Terms gate, pulled streams
    ServiceSessions.swift    sign-in by Game Center signature, session tokens (SHA-256 stored), identity and terms
    ConnectionAttestation.swift  App Attest per service connection (#158): verify, register or advance, the bypass
    AppAttestKeys.swift      the App Attest key store: in memory, or Postgres (migration 0018); no player link
    AccountStore.swift       players, sessions and terms acceptances: Postgres, or in memory for dev and tests
    ServiceSetup.swift       the endpoint from the config (Apple or dev verifier), the dev situations, the HTTPS fetch
    AnalyticsIngest.swift    usage analytics (#156): devices' batches by install id, the server's own events, the roll-up and purge
    Liveries.swift           seat liveries (#159): stored per player, ownership, the lock, raced as a starter, earned unlocks
    Moderation.swift         moderation (#153): reports, the automatic mute, the chat ladder, racing penalties, the admin queue
    OnlineData.swift         Delete my online data (#160): the plan, the erase, leaderboard blocks, the retention and inactivity jobs
    AdminAPI.swift           the admin tool (#154): /admin/ routes behind admin tokens, the queue, decisions, penalties, the audit
    FairPlay.swift           fair-play flags (#155): the nightly scan of the window's race logs, flags to the admin queue
    Measures.swift           measures and balance queries (#157): queue, fleet, briefing, round-trip and Race again events; queries over logs
  GameCenterIdentity/      Game Center identity verification: Apple's chain, RSA PKCS#1 v1.5 over the signed payload
  AppAttest/               App Attest verification (#158): own CBOR decoder, Apple's embedded root, attestations, assertions
  RegattaServer/           the `RegattaServer` executable
  RegattaDevAPI/           the dev endpoints' JSON, shared by the server and the load client
  Persistence/             the server's Postgres (#144, ADR 0009), used by the server when REGATTA_DATABASE_URL is set
    Database.swift           the connection pool; its config from a postgres:// URL (REGATTA_DATABASE_URL)
    Migrator.swift           numbered migrations (Migrations/), applied and reverted in one transaction each run
    Stores.swift             players (by verified teamPlayerID, gamePlayerID bound 1:1), sessions, terms acceptances
    RaceRegistryStore.swift  races running, closed or cancelled, the files each names; orphans cancelled; logs (bytea)
    DataFileStore.swift      every version of every data file, by FileRef; a version never changes
    AnalyticsStore.swift     usage analytics (#156): raw events 90 days, the daily aggregates and the roll-up's arithmetic
    LiveryStore.swift        players' stored liveries (#159), one per player, gone with her
    ModerationStore.swift    reports and penalties (#153), kept past Delete my online data for their retention; the admin audit (#154); fair-play flags (#155)
    PlayerDataStore.swift    a player's online data erased in one transaction (#160), her seats anonymised, the deletion audit
  RegattaLoadClient/       RegattaClient over a NIO WebSocket: scripted helm, bytes and RTT measured; the
                           contract runner's WebSocketServiceConnector (#145)
  regatta-loadclient/      the `regatta-loadclient` executable
  RegattaAdminClient/      `regatta-admin`'s commands as the requests they make (#154)
  regatta-admin/           the `regatta-admin` executable: the admin tool's command line
Regatta/                The iOS app
  Game/RaceDriver.swift   what the app sails a race through: 30 Hz tick clock, tick frames, the interpolated RenderWorld
  Game/PracticeDriver.swift  an offline practice race: owns the Race and on-device bots, latches your input per tick, keeps the log
  Game/VisualCorrection.swift  eases a corrected prediction's drawn position over ~150 ms, snaps past a hull length (online, #68)
  Game/GameScene.swift    SpriteKit renderer, camera, touch steering; reads RenderWorld, never a Race
  Game/BoatNode.swift     batched boat sprites: hull, outline, sail, heel, ghost fade
  Game/BoatEffects.swift  each boat's wake string, wind-shadow cone and backwind; the fleet's one ConeLayer
  Game/WakeShape.swift    a wake's alpha (and V numbers) from speed through the water and pressure
  Game/ShadowShapes.swift the cone's and backwind's outlines, from core's ShadowCone sizes
  Game/ChartLayer.swift   the chart: race-area boundary and hatch, land and relief, landmarks, shallows tint, marks and line
  Game/ChartMarks.swift   which marks are the active leg's (orange) or grey, and the rounding-side arrow (pure)
  Game/ChartGeometry.swift  hatch band, coast edges, relief strips, shallows weight and OKLab blend (pure)
  Game/ChartStyle.swift   the chart's tuning values
  Game/LandmarkSilhouette.swift  placeholder landmark vectors by venue asset name (#169 replaces)
  Game/GameSession.swift  hosts a driver and bridges it to SwiftUI: HUD, rule-call messages, haptics
  Game/RaceConfig.swift   a practice race's settings, seeds and seat controllers; roster names and the bot glyph
  Game/RaceViewportPolicy.swift  race-view sizing: letterboxed portrait in any window (G5)
  UI/                     menu, HUD, minimap, results
  App/                    app and scene delegates, launch arguments, acknowledgements
  Info.plist              shipping keys: A12 minimum, scene manifest, launch screen, export compliance
  PrivacyInfo.xcprivacy   privacy manifest (#28)
  Regatta.entitlements    Game Center and App Attest environment
RegattaTests/           Hosted unit tests for the app
RegattaUITests/         the online UI tests scripts/e2e.sh runs; Fixtures/ for -fixture previews
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

Boat classes, conditions, venues, the rules configuration and the livery catalogue are immutable,
versioned JSON files (ADR 0004), loaded from their bytes by `DataFile<Content>(data:)`. The venue schema
is in `docs/venue-file.md`; the rules configuration schema in `docs/rules-file.md`; the livery catalogue's
in `LiveryCatalogue.swift`.

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

The merge gate (what CI's `packages` job runs): every package built with its tests and run at `-O`, the bot suites
left out (`--bots` adds them; name packages to narrow it):

```bash
scripts/test.sh                 # every package
scripts/test.sh RegattaCore     # one
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
with a race token, then the race; #18), the service WebSocket at `/service` (#145: `Hello`, then a session call
that signs in with a Game Center identity signature or resumes a session token, then the service messages of
#143, the lobby and the queue gated on the current Terms of Use), and in dev `POST /dev/instant-race` and
`POST /dev/situation` (puts a contract-runner test account in a suite's situation). Each service connection's
`Hello` carries an App Attest proof (#158, ADR 0014); the queue, the lobby and races serve only an attested one, and
a race seat is joined only with a race token the queue minted. It refuses to start (exit status 78) unless `ENV` is
`dev`, `staging` or `production`, and outside dev without Apple's root, the moderation key and Postgres, or with the
App Attest bypass on. The dev routes exist only in dev (404 otherwise). In dev, without `REGATTA_APPLE_ROOT_PEM`, any
well-formed fresh identity signature passes; with it, the signature is checked against Apple's chain. It reads:

| variable | default | |
|---|---|---|
| `ENV` | none | `dev`, `staging` or `production`; anything else refuses to start |
| `HOST`, `PORT` | `127.0.0.1`, `8080` | where it listens (the container sets `HOST=0.0.0.0`); `PORT=0` picks a free port |
| `RACE_TOKEN_SECRET` | random per process | HMAC key for race tokens, at least 16 bytes |
| `RACE_TOKEN_TTL` | `600` | seconds a race token joins for |
| `SERVER_BUILD` | `dev` | reported in `HelloAck` and `/health` |
| `MAX_RACES` | `64` | races at once |
| `TERMS_VERSION` | `1` | the Terms of Use version players must accept; a bump re-asks everyone |
| `REGATTA_BUNDLE_ID`, `REGATTA_TEAM_ID` | `com.phillreeder.regatta`, `8S5TQ65X3B` | what Game Center signs, and the team (final values: #49) |
| `REGATTA_APPLE_ROOT_PEM` | none | PEM file with Apple's root and the intermediate that issues Game Center's key (Game Center serves the leaf only); self-signed certificates are the anchors, the rest chain links; required outside dev (ADR 0010) |
| `REGATTA_DATABASE_URL` | none | Postgres (migrations run at start, orphaned races cancelled); unset in dev keeps accounts in memory; required outside dev |
| `APP_ATTEST_BYPASS` | `on` in dev | dev only (#158): `on` lets a connection with no App Attest proof, or the simulator's `unsupported`, through (the load client, the contract runner, e2e); a real proof is still verified; `off` verifies every connection. Outside dev only `off` or unset: `on` refuses to start |
| `APP_ATTEST_ENVIRONMENT` | `both` in dev and staging (TestFlight builds attest as production), `production` in production | the App Attest environments whose keys are accepted (the AAGUID follows the app's entitlement): `production`, `development` or `both`; production takes `production` only |
| `QUEUE_LOCK_SECONDS` | `60` | seconds from the oldest queued player's join to fleet lock (#146); the contract runner's server uses a few |
| `QUEUE_RACE_SECONDS` | none | `ENV=dev` only: a queue race is closed this many seconds after its gun (5 to 3600) with results as it stands, boats still racing placed by distance; for the local demo and the e2e run (#162). Unset, a race sails to its end |
| `ALL_GONE_GRACE_SECONDS` | `30` | `ENV=dev` only: how long a race every person has left waits for one to come back before it closes (G3), so the e2e run's one player can drop and rejoin (#162) |
| `CATCH_FINISHERS` | on | `off`: the queue never holds its lock for a running race's finishers (G2, #147); the contract runner's server sets it |
| `CATCH_FINISHERS_OFFSET_SECONDS` | `15` | a held lock comes this long after the running race's expected close (G2, #147) |
| `CATCH_FINISHERS_MAX_HOLD_SECONDS` | `180` | the oldest queued player waits at most this long, join to lock, for a hold (G2, #147) |
| `SIMULTANEOUS_LOSS_POLICY` | `cancel` | a mass drop (G3: 2+ humans all dropped within 2 s, nobody back in 30 s): `cancel` (no results, no rating) or `ret` (RET in leave order, rated per #30) (#148) |
| `CLIENT_ADDRESS_HEADER` | none | behind a reverse proxy: the request header the proxy sets to the client's address (`Fly-Client-IP` on Fly, `X-Forwarded-For` behind a load balancer). The per-address connection caps then count that address, not the proxy's. Unset, no header is trusted and the socket's address counts. Set it only when every connection comes through the proxy: a client reaching the server directly could put any address in it (#469) |
| `CLIENT_ADDRESS_TRUSTED_HOPS` | `1` | with `CLIENT_ADDRESS_HEADER`, for a header that lists addresses: which entry from the right is the client's, one per trusted proxy in the chain (#469) |
| `RATING_WEIGHT_EXPONENT` | `0.5` | ratings (ADR 0012): a rated race with m human opponents weighs each of its games m^-x; 0.5 is 1/√m, 0 counts every pair in full, 1 makes every race worth one duel (#151) |
| `COVERED_FINISH_GRACE_SECONDS` | `60` | a dropped player's boat is sailed by the cautious bot; if it finishes less than this long after she dropped, the place counts for her rating, otherwise she is rated as retired. Never a completed race or a win either way (#150) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PEM`, `GC_LEADERBOARD_ID` | none | the Game Center leaderboard mirror (#151): an App Store Connect team key (its id, the issuer id, a PEM file of its P-256 private key) and the leaderboard's id. All four, or none: without them no score is sent. The leaderboard must keep the most recent score, not the best (#55) |
| `LEADERBOARD_SWEEP_SECONDS` | `300` | how often leaderboard scores that weren't sent are tried again (#151) |
| `OPENAI_MODERATION_API_KEY` | none | the lobby's toxicity classifier (#152, #51): each free-text post that passes the bundled word list is also checked by OpenAI's moderation endpoint (the text only). Required outside `ENV=dev`. Unset, nothing is called and the word list alone filters. When the classifier can't answer, the post goes through on the word list |
| `CHAT_EXTRA_BLOCKED_PHRASES` | none | `ENV=dev` only: comma-separated phrases the lobby's filter blocks besides the word list (the contract runner needs `contract filtered phrase`) |
| `REGATTA_ADMIN_TOKENS` | none | the admin tool (#154): comma-separated `id:token` pairs, one per admin, each token 32 characters or more (`openssl rand -hex 32`). Each action through `/admin/` is recorded with the id of the admin whose token it carried. Unset: the server has no `/admin/` routes |

The per-address connection caps (8 on `/service`, 32 on `/race`) count an IPv4 address, or an IPv6 address's /64 prefix.
A staging or production server behind a proxy must set `CLIENT_ADDRESS_HEADER`, or all its clients share one address's
cap (#167).

`POST /dev/instant-race?clients=N` starts a race now for N clients (1…16), with bots filling it to 10 boats,
and answers each client's seat and signed race token. `raceSeconds=S` closes the race S seconds after the gun,
where it stands (the dev race-length override, for e2e runs); `startSeconds=S` sets the start sequence (default 60);
`seed=X` makes it reproducible.

The admin tool (#154) is `regatta-admin`, one command per request to the server's `/admin/` routes, as the admin
whose token is in `REGATTA_ADMIN_TOKEN` (the server at `REGATTA_ADMIN_URL`, default `http://127.0.0.1:8080`):
`queue` lists what waits, the first due first (24 h from filing, #34); `report <id>` shows a report with the reported
player's penalties and other reports, and a race report's results and the seat's incidents; `decide <id> <decision>`
(`dismiss`, `uphold_chat`, `override_nickname`, or a racing penalty); `player <id>`; `penalize <player> <penalty>`
(`warning`, `suspension_24h`, `suspension_7d`, `permanent`, `rating_reset`); `mute <player>` (the next chat step);
`nickname-override <player>`; `lift <player> <penalty-id>`; `flag <id>` and `decide-flag <id> dismiss|confirm` for the
fair-play flags (#155), which the server raises into the same queue each night from the last 30 days' race logs and
which never penalize anyone; `audit [player]`; and the measures (#157): `measures [days]` (queue wait, humans per fleet,
briefing leaves and cooldowns, drops, rejoins and RET, the round-trip distribution and the time over 250 ms, the Race
again rate and the time from finish to re-queue) and `balance [days] [--no-splits]` (rule calls and protests per rule,
start and leg splits by venue × conditions from a replay of each race, results by tier, the ratings' calibration by
rating gap, each player's finish variance; races on tuned files left out). The server records what the measures need
as its own analytics events (`queue_joined`, `queue_wait`, `fleet_locked`, `briefing_leave`, `round_trip`: it pings
each seated race connection every 2 s). Every action is in the audit. It isn't in
the container image: run it from a checkout, `swift run --package-path Packages/RegattaServer regatta-admin queue`.

`regatta-loadclient` creates an instant race and sails every seat at once with `RaceClient` on a scripted helm,
then prints each client's bytes down and up (TCP payload, the join included) and its ping round trips. It exits
non-zero unless every client sailed to the race's close and passed the wind audit (no wind key before its reveal
tick, every due key in each join and resync, and in an instant race, whose wind seed the dev endpoint derives from
the public race seed, never the seed's bytes: #95); `--check-bandwidth` also fails a client over #27's budget
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

Bandwidth: with 16 boats a client receives about 4.9 KB/s at worst (a snapshot of about 480 bytes with the
umpire's relations 10 times a second, plus pongs and events) and joins in about 0.7 KB. Fewer boats send less.
The 5 KB/s budget (#27) holds, with little room: `BandwidthBudgetTests` measures it for 16 clients on a virtual
clock (#216), and CI's container job over real sockets. The 1 MB per race budget is measured only on the short
races (8 to 20 s after the start sequence), where it passes trivially. A race costs the join plus that rate times
its length from the join to the close, so it extrapolates to about 2.6 MB for an 8-minute race (with a 60 s
sequence): at the measured rate 1 MB holds only to about 3.4 minutes. The two budgets disagree for real race lengths; which one
gives way (or whether the snapshot rate changes) is an open question for the product owner.

### Server persistence (Postgres)

`Persistence` keeps players, sessions, the race registry, race logs and every version of every data file in
Postgres 17 (ADR 0009). `PersistenceTests` run against a real database named by `REGATTA_TEST_DATABASE_URL`; each
test makes its own schema and drops it, so they run in parallel. Without the variable they're skipped, saying why
(so `scripts/test.sh` runs without a database); with `REGATTA_REQUIRE_DATABASE=1` a
missing variable fails them instead, and the nightly `persistence` job sets it and runs them in the pinned Linux image
next to a `postgres:17` service container.

Locally, with Homebrew's `postgresql@17` (trust auth on localhost; `createdb regatta_test` once). Start it only
for the run (`LC_ALL` is required, or the postmaster refuses to start):

```bash
LC_ALL=en_US.UTF-8 /opt/homebrew/opt/postgresql@17/bin/pg_ctl -D /opt/homebrew/var/postgresql@17 \
    -l /opt/homebrew/var/log/postgresql@17.log -w start
REGATTA_TEST_DATABASE_URL=postgres://$USER@localhost:5432/regatta_test \
    scripts/heavy.sh swift test --package-path Packages/RegattaServer --filter PersistenceTests
/opt/homebrew/opt/postgresql@17/bin/pg_ctl -D /opt/homebrew/var/postgresql@17 -w stop
```

A container works as well:
`podman run --rm -d --name regatta-pg -p 5432:5432 -e POSTGRES_PASSWORD=regatta postgres:17` with
`REGATTA_TEST_DATABASE_URL=postgres://postgres:regatta@localhost:5432/postgres`.

### Online client

The app races online with `RaceClient` over a `URLSessionWebSocketTask` (`Regatta/Online/`, #68). In a Debug
build the menu has **Race online (dev)**: it asks the dev server at the menu's `host:port` field (default
`127.0.0.1:8080`, the Mac the simulator runs on) for an instant race and joins it. `OnlineDriver` draws the
predicted fleet, shows rule calls, OCS, penalties and finishes only from the server's events, rejoins with a
`Resync` when the connection drops, and raises a lag signal after about 5 s of round trips over 250 ms.

With a server address and a player, Race online is the real thing (#162): the online session (#161) carries the
queue, the race session and the profile, Race online joins the queue, fleet lock takes the app over into the briefing,
and the race is sailed on `/race` of the same host with the token the hand-off gave. A race the app dropped out of is
offered again as Rejoin race, on a cold launch too; a race the server no longer has ends on Home with "The race was
cancelled". Your livery follows you: the server's copy replaces the device's when the session opens, a livery saved in
My boat is stored on the server, and one saved before the first sign-in, or while offline, is uploaded first. The
address is `-onlineHost host:port` or the Settings page's field in a Debug build, and Info.plist's `RegattaServiceURL`
otherwise (empty until #167: a build with no address still answers Race online with "Online racing is on its way"). A
Debug build signs in as a dev player with `-devIdentity <n>`, or the number in Settings' **Dev player** field.

#### Two people in one race, on this Mac

```bash
# terminal 1: the dev server (accounts in memory), a short queue and a short race: the demo takes about 3 minutes
cd Packages/RegattaServer && ENV=dev QUEUE_LOCK_SECONDS=10 QUEUE_RACE_SECONDS=90 CATCH_FINISHERS=off swift run RegattaServer
# terminal 2: builds the Debug app, boots two iPhone simulators, installs it and launches it on each as its own dev player
scripts/demo-online.sh
```

The simulators share the Mac's loopback. In each, tap Race online and agree to the terms once (`--auto` taps both for
you, after a first launch on a simulator it had to boot, whose slow start would miss the lock). Both must join within
`QUEUE_LOCK_SECONDS` of the first. The simulators are the iPhone 17 Pro and the iPhone 17e (`DEMO_DEVICES`), not the
iPhone 17 the test runs use. The briefing lists "Dev 1" and "Dev 2" as people among
the bots, the gun is 75 s after the lock, each sees the other on the leaderboard, and the race closes 90 s after the gun
with results and a rating; Race again queues. `--headless-second` launches one simulator and plays the second person
with `regatta-loadclient --queue-player 2`. Two phones on your Wi-Fi can race the same server (`HOST=0.0.0.0`, its LAN
address and a different **Dev player** number in each phone's Settings, then relaunch): not verified.

`scripts/e2e.sh` runs the end-to-end check: it builds `RegattaServer` and `regatta-loadclient`, starts Postgres
(Homebrew's `postgresql@17`, in a temporary directory) and the server on it with `ENV=dev` on a free port, and runs the
online UI tests on the simulator against it, in phases, each a server of its own settings on the same database:
`OnlineRaceUITests` (a short instant race with bots, raced to the close) and `OnlineAccountUITests` (#161: a dev player
signs in, accepts the terms, joins the queue and leaves it, relaunches, meets a suspension and the cooldown); a terms
bump (`TERMS_VERSION=2`); then `OnlineQueueRaceUITests` (#162) on a 4 s queue and a 12 s race (queue to the close, Leave
in the briefing, Rejoin race after a drop, Leave race after the gun, the livery back from the server), with a headless
second person in the fleet (`regatta-loadclient --queue-player 7001`), and with the server killed under a race and
started again. Those are the only UI tests: they skip without a server, saying why. It runs nightly.

```bash
scripts/e2e.sh
```

Run the app's unit tests (`RegattaTests`) on the simulator:

```bash
xcodebuild test -scheme Regatta -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RegattaTests
```

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

CI (`.github/workflows/ci.yml`), the merge gate: `scripts/test.sh` on macOS and the app compiled with its test targets.
Nightly (`.github/workflows/nightly.yml`), never blocking: `scripts/linux-test.sh` (the golden and RegattaBots digests
on the pinned Linux replay platform), the server image under load, Postgres, `scripts/test.sh --bots` plus
`scripts/check-digest-stable.sh`, the app's unit tests on the simulator, and `scripts/e2e.sh`. The bot suite
(`botsuite.yml`) runs nightly too; `ios27.yml` (the iOS 27 SDK: archive, shipping config, launch, unit tests) weekly.

### Launch arguments

Parsed by `LaunchOptions`; bad values are logged and ignored.

- `-autostart` skips the menu and starts a race.
- `-demo` starts a race with a bot controller attached to your seat too. Useful for watching the AI.
- `-perf` starts a 16-boat demo race for profiling.
- `-seed <n>` sails every race on race seed `n`, with the wind seed pinned to it too, so the whole race reproduces.
- `-referenceRace <n>` (Debug builds, #367) sails reference race `n` (1…16, `reference-regatta@7.json`) with you in
  seat 0: the pinned race the bot suite sails with a stand-in (`BotRaceHarness.runReference`), on untuned files with
  the pressure overlay off. It looks like any practice race.
- `-timescale <n>` runs the simulation at `n`× real time.
- `-uitesting` marks a UI test run. It and `-fixture` hide the Debug FPS, node and draw-count overlay so
  screenshots are deterministic.
- `-fixture <name>`, `-scheme halves|tiller` and `-camera course|boat` are parsed for fixture previews
  (#62), steering schemes (#112) and camera (#113): `-camera` overrides Settings' camera as course-up or boat-up.
- `-online` starts an online dev race at launch (Debug builds), on `-onlineHost <host:port>` or the menu's
  host; `-startSeconds <n>` (1…60) and `-raceSeconds <n>` ask the dev server for a short sequence and race.
- `-vision deut|prot|trit|grey|sun` (or `deuteranopia`, `protanopia`, `tritanopia`, `greyscale`, `washout`,
  `none`) puts a colour-vision filter over the whole race view, scene, HUD and letterbox alike (Debug builds,
  #111), to check every cue still reads.
- `-tuning` opens the debug tuning panel at launch (Debug builds, #232; see below).
- `-fakeServices signed-out|underage|communication-restricted|multiplayer-restricted|offline|queued|cancelled-race`
  runs the online services on that scenario's scripted fakes (`RegattaServices`), for UI tests (#242).

### Debug tuning panel

Debug builds only (`#if DEBUG`; the Release config the scheme archives with has no panel): Home's **Tuning**
row, `-tuning`, or **Tuning** in a practice race's pause menu. Grouped sliders for the real-vs-fun values, each
with its value and its file's, and a reset per group:

- **Data values** (conditions, upwind grooves, autohelm, handling, wind shadow, race format) apply at the next
  practice race start as *tuned copies*: the bundled file's bytes with the new numbers written in, keeping its
  id and version, with their own hash and a `tune` number in the ref (ADR 0004, #229). Bots sail them too;
  online races never do (the wire refuses a tuned ref).
- **Render values** (water, camera) apply live, even over the paused race, and are never logged.
- Values persist until reset. **Saved tunings** keep named sets; **Export** shares each tuned file as its next
  version, ready for `Packages/RegattaCore/Sources/RegattaCore/Resources`, with the changed values listed under
  `placeholders`.

Everything lives in the app's Application Support/Tuning folder: `current.json`, `saved/`, every tuned copy
raced in `files/<kind>/<id>@<version>+tune<n>.json` (never rewritten), and the 20 newest tuned practice races
in `races/<date>-<seed>/`, each its `race.racelog.json` with its tuned copies beside it. Share one from the
panel's **Tuned races** and replay it with `swift run --package-path Packages/RegattaCore regatta-replay <folder>`.

### Profiling

The app emits `os_signpost` intervals on the Points of Interest track: **Sim step**, **Bot brains**,
**Render update** and **HUD refresh**. Profile the Regatta scheme in Instruments with `-perf` and compare
them against the budgets in #27 (sim + prediction < 3 ms, bots < 2 ms). **Bot brains** is the seat
controllers deciding before each tick, outside `Race.step()`, so **Sim step** is the simulation alone.
**Water update**, inside **Render update**, is the water (#116): every ripple tile samples the wind where it
is, each frame (`WaterTests.waterUpdateStaysCheap` prints its cost).

## Playing

- Hold the **left** or **right** half of the screen to steer. Short taps make small corrections.
- Steer through the wind to tack or gybe: there is no button.
- You start in a row below the line, reaching towards the pin on the autohelm until you steer.
- Keep all of your hull below the line at the gun. If any of it is over (OCS), sail back until all of it
  is below the line, then start. While you sail back, keep clear of everyone else.
- Round the windward mark and leeward mark to port, then finish by crossing the line downwind.
- Dark water is a puff and pale water is a lull. The faint cone behind each boat is its wind shadow.
- Fouling another boat or touching a mark of your leg (the one you're rounding, or a line end before you
  start or as you finish) costs one penalty turn, and a foul and a touch in one incident cost one between
  them: a 360° one way, a tack and a gybe. Start it within 20 s and finish it within 40 s or you're disqualified; owe more than one and each gets its own
  20 s and 40 s once the one before is done. You can't finish while you owe one: take it on the course side
  and cross again.
