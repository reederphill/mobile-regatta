# Real-time multiplayer infrastructure options

Research for [ticket 03](../wayfinder/tickets/03-realtime-multiplayer-infrastructure.md). Sources were read on **2026-09-22**, and every price below is as of that date. Prices are in USD unless marked €.

## Answer in brief

- **Game Center / GameKit can't be the race server.** GameKit caps peer-to-peer and hosted matches at **16 players**, which is below the ~20-boat target. Its real-time `GKMatch` is peer-to-peer, so it isn't server-authoritative. It is still useful for free identity (a signed player ID that a server can verify), leaderboards and invites.
- **RegattaCore can run on a Linux server with a very small change.** The only Apple-only dependency is `import simd`, which three helpers in `Geometry.swift` use. Everything else is Foundation plus stdlib `SIMD2<Double>`, and both work on Linux. SwiftNIO provides UDP and WebSocket servers on Linux. Nakama (Go, Lua or TypeScript) or Cloudflare Durable Objects (JavaScript, or Wasm) would mean porting the ~1,200-line simulation, or running Swift→Wasm, which is not a proven path.
- **Recommended for v1.0:** a small Swift/SwiftNIO race server, WebSocket first, on a few VPSs or Fly.io Machines. Use Game Center for identity and a plain Postgres database for ratings. For global placement at scale, the same Linux binary can later move to Edgegap or GameLift.
- **Hathora is no longer an option.** It exited game hosting on 2026-05-05. Rivet now sells general "Actors" rather than game-server hosting.

## What Regatta needs (context from the repo)

- The design is fixed as real-time, online and server-authoritative ([map](../wayfinder/map.md)). A fleet race has up to ~20 boats.
- `Race` in `Packages/RegattaCore/Sources/RegattaCore/Race.swift` is "the authoritative race simulation", advanced with `step(_:)` at a fixed rate. The package is ~1,200 lines of pure Swift with a deterministic `SplitMix64` RNG.
- **Portability audit:** only `Geometry.swift` imports `simd`, for `simd_length`, `simd_length_squared` and `simd_dot`. The `simd` module is Apple-only. The `SIMD2` type is in the Swift standard library, so these can become `(self * self).sum().squareRoot()` and `(self * other).sum()`. The other files import only Foundation, which exists on Linux.
- **Not a hosting issue, but the server will need it:** `Race` currently assumes a single human (`playerIndex = 0`, `autopilotPlayer`). A multi-human input API is needed on any host.
- **Caveat:** `sin`, `cos` and `atan2` can differ in the last bits between Apple's libm and glibc. With server-authoritative snapshots this only shows up as small prediction corrections, not desyncs. It matters only if lockstep determinism is ever wanted.

## Sizing assumptions (mine, not from sources)

- **Bandwidth:** ~20 Hz server snapshots of 20 boats. At about 16 B per boat plus headers, that is ~0.4 KB per packet, or **~8 KB/s (~64 kbit/s) down per player**. Client input is tiny.
  - Sustained, that is ~21 GB per CCU-month. **100 CCU ≈ 2 TB/month; 10k CCU ≈ 210 TB/month.** These are upper bounds that treat peak CCU as 24/7.
- **Compute:** 10k CCU is 500 concurrent races and 100 CCU is 5.
  - One 20-boat step is cheap: 190 boat pairs, plus wind and bots. The cost has not been measured.
  - I assume ~20 races per vCPU including serialisation, which gives **~25–50 vCPU for 10k CCU** and **1 vCPU for 100 CCU**.
  - Benchmark `Race.step` on Linux before trusting any of this.

## Options

### 1. Game Center / GameKit real-time (`GKMatch`)

- **Model:** `GKMatch` is "a peer-to-peer network" between Game Center players, with `reliable` and `unreliable` send modes ([GKMatch](https://developer.apple.com/documentation/gamekit/gkmatch), [SendDataMode](https://developer.apple.com/documentation/gamekit/gkmatch/senddatamode)). `chooseBestHostingPlayer` elects one *phone* as host, so "server" logic would run on a player's device. That is cheat-prone and not server-authoritative.
- **Player cap:** "For peer-to-peer, hosted, and turn-based matches, the maximum number of players is 16" ([maxPlayersAllowedForMatch(of:)](https://developer.apple.com/documentation/gamekit/gkmatchrequest/maxplayersallowedformatch(of:))). **That is below Regatta's ~20.** Bots could fill the extra slots server-side, but humans are capped at 16.
- **Hosted matches:** Game Center "handles the matchmaking process but returns player identifiers instead of a complete match object". Your game must provide the networking code, the protocol and the server that routes data ([Finding players for custom server-based games](https://developer.apple.com/documentation/gamekit/finding-players-for-custom-server-based-games)). So Game Center can serve as a matchmaking front end for your own server, subject to the 16-player cap.
- **Identity:** `GKLocalPlayer.fetchItems(forIdentityVerificationSignature:)` "generates a signature that you can use to authenticate the local player on your own server" ([GKLocalPlayer](https://developer.apple.com/documentation/gamekit/gklocalplayer)).
- **Latency, regions and cost:** Apple publishes no latency or region information. There is no hosting cost.
- **Swift client:** native. **Server-side sim:** n/a. **Persistence:** Game Center leaderboards and achievements only. There is no custom rating storage.
- **Verdict:** use it for sign-in, identity and maybe invites or leaderboards, not for transport.

### 2. Custom Swift server (SwiftNIO) on a VPS or Fly.io

- **Transport:** SwiftNIO has `DatagramBootstrap` (UDP) and `NIOWebSocket` (client and server), tested on Ubuntu 18.04+ ([apple/swift-nio](https://github.com/apple/swift-nio)). QUIC (`swift-nio-quic`) is described as in active development on `main`, so it isn't stable.
- **iOS client:**
  - WebSocket: `URLSessionWebSocketTask`, iOS 13+ ([docs](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)).
  - Raw UDP: Network.framework.
  - QUIC: `NWProtocolQUIC`, iOS 15+, which supports datagram flows via `isDatagram` / `maxDatagramFrameSize` ([Options](https://developer.apple.com/documentation/network/nwprotocolquic/options)).
  - WebTransport: I found no first-party iOS API for it.
- **Swift on Linux:** Swift 6.4.0 supports x86_64 and aarch64, and the Static Linux SDK builds "fully static binaries" with musl ([swift.org Linux install](https://www.swift.org/install/linux/)). **RegattaCore runs as-is after the `simd` shim.**
- **Fly.io** ([pricing](https://fly.io/docs/about/pricing/), [UDP](https://fly.io/docs/networking/udp-and-tcp/), [regions](https://fly.io/docs/reference/regions/)):
  - **Regions:** 18, including iad, ord, lax, sjc, gru, lhr, ams, fra, nrt, sin, syd and jnb.
  - **Machines (ams baseline, per month):** shared-cpu-2x 1 GB costs $6.64, performance-1x 2 GB costs $32.19 and performance-2x 4 GB costs $64.39.
  - **Networking:** a dedicated IPv4 costs $2/mo. Egress is $0.02/GB in NA/EU, $0.04 in APAC/SA and $0.12 in Africa/India.
  - **UDP:** needs a dedicated IPv4 and a bind to `fly-global-services`. There is no public IPv6 UDP. Assume ~1300-byte packets.
  - **Caveat:** I found no documented way to pin a UDP flow to a *specific* Machine. Anycast sends each player to the nearest Machine. Players in one race must reach the same process, so plan one Machine per region per race pool, or use WebSocket, where HTTP-level routing applies.
- **Hetzner (VPS)** ([price adjustment effective 15 June 2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/), [dedicated vCPU plans](https://www.hetzner.com/cloud/general-purpose/)):
  - **Prices (DE/FI, per month):** CX23 (2 shared vCPU) is €5.49 / $6.49. CAX11 (Arm) is €5.99 / $6.99. CCX13 (2 dedicated vCPU) is €42.99 / $50.49.
  - **Traffic:** 20 TB is included in the EU. US locations include 1–8 TB and Singapore 0.5–8 TB.
  - **Locations:** Germany, Finland, the US (Ashburn, Hillsboro) and Singapore. There is nothing in Japan, Australia or South America.
- **Cost estimate:**
  - **100 CCU:** 1–3 small Machines or VPSs, about **$15–$150/mo** including egress. The upper end uses performance CPUs for tick stability.
  - **10k CCU on Fly.io:** 25 performance-2x Machines at ~$1.6k plus ~210 TB egress at ~$4.2k, about **$6k/mo**.
  - **10k CCU on Hetzner:** 25 CCX13 at ~$1.3k, with EU traffic mostly included, about **$1.3–2k/mo**.
- **Matchmaking and persistence:** none built in, so you build them. A single FIFO queue per region, plus Postgres for accounts (keyed by Game Center player ID) and ratings, is modest work at v1.0 scale.

### 3. Cloudflare Durable Objects (and Containers)

- **Model:** one DO per race, with clients on WebSocket.
- **Placement:**
  - A DO is created near the first `get()`. Optional location hints are wnam, enam, sam, weur, eeur, apac, apac-ne, apac-se, oc, afr and me. Hints are "best effort", and placement is fixed after creation ([data location](https://developers.cloudflare.com/durable-objects/reference/data-location/)).
  - The soft limit is 1,000 requests per second per object ([limits](https://developers.cloudflare.com/durable-objects/platform/limits/)), which is fine for 20 players × 20–30 Hz.
- **Transport:** WebSocket only, with no UDP.
- **Tick loop:** "`setTimeout` and `setInterval` usage" prevents hibernation ([WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)). A 30 Hz race DO is therefore billed for wall-clock duration while the race runs.
- **Pricing** ([DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)):
  - The Workers Paid plan costs $5/mo.
  - Requests: 1M included, then $0.15/M. Incoming WebSocket messages are billed at a 20:1 ratio.
  - Duration: 400k GB-s included, then $12.50/M GB-s.
  - Egress is free.
- **Cost estimate** (assuming a 128 MB isolate, 20 Hz client input):
  - **100 CCU:** ~$20–60/mo.
  - **10k CCU:** ~$2k/mo in duration plus ~$4k/mo in requests, so **~$3–6k/mo**. The lower figure assumes input is sent only when it changes.
- **Server-side sim:**
  - DOs run JavaScript/TypeScript or Wasm. Cloudflare says "WASI support is experimental … only some syscalls implemented" and doesn't mention Swift ([Workers Wasm](https://developers.cloudflare.com/workers/runtime-apis/webassembly/)).
  - Swift 6.2+ has Swift SDKs for Wasm (WASI), including an experimental Embedded Swift variant ([swift.org Wasm](https://www.swift.org/documentation/articles/wasm-getting-started.html)).
  - Swift→Wasm inside a DO is therefore **unproven**. Realistically you would port RegattaCore to TypeScript and keep two copies in sync, or accept the Wasm risk.
- **Cloudflare Containers** could run the Swift Linux binary behind a DO ([pricing](https://developers.cloudflare.com/containers/pricing/)):
  - vCPU costs $0.000020 per second of active use and memory $0.0000025 per GiB-s. Egress is $0.025/GB in NA/EU after 1 TB.
  - Instance types run from 1/16 to 4 vCPU.
  - Access goes through Worker/DO `fetch` (HTTP/WebSocket). I found no direct UDP ingress in the docs ([Containers](https://developers.cloudflare.com/containers/)).
- **Persistence:** DO SQLite storage and D1 are available, so ratings could live there. Matchmaking would be a "lobby" DO you write yourself.

### 4. Nakama (Heroic Labs)

- **Authoritative matches:** match handlers run in **Go, Lua or TypeScript** with a configurable tick rate, from "once per second … to dozens of times per second". Messages should stay under the 1500-byte MTU ([authoritative multiplayer](https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/)).
- **Transport:** the client socket is WebSocket.
- **Swift client:** official `nakama-swift` v1.0.0, supporting iOS, macOS and visionOS, using async/await, gRPC and sockets ([GitHub](https://github.com/heroiclabs/nakama-swift), [client libraries](https://heroiclabs.com/docs/nakama/client-libraries/)).
- **Server-side sim:** **you port RegattaCore to Go or TypeScript**, or run the Swift sim as a separate process and use Nakama only for meta features.
- **Batteries included:**
  - A matchmaker with property queries such as region or rank, and min/max count ([matchmaker](https://heroiclabs.com/docs/nakama/concepts/multiplayer/matchmaker/)).
  - Accounts with **Game Center** and Sign in with Apple auth ([authentication](https://heroiclabs.com/docs/nakama/concepts/authentication/)).
  - Leaderboards, storage and chat, which is relevant to the v1.0 lobby chat.
- **Cost:**
  - Open source and free to self-host (Nakama plus Postgres or CockroachDB on a VPS), so compute and egress cost roughly what option 2 does.
  - Heroic Cloud prices are not published. It is "no DAU/MAU/CCU limits" on dedicated hardware, with optional support packages from $2,000/mo ([pricing](https://heroiclabs.com/pricing/)).
- **Verdict:** the most complete off-the-shelf backend, but it forces a port of the simulation.

### 5. Session-based game-server hosting (Edgegap, GameLift; Hathora gone)

**Edgegap** ([pricing](https://edgegap.com/pricing), [deployments](https://docs.edgegap.com/learn/orchestration/deployments), [matchmaking](https://docs.edgegap.com/learn/matchmaking)):

- **How it works:** any Docker container, so a **Swift Linux binary works as-is**. It spins up one server per match at the location that minimises players' ping ("615+ locations"). It supports UDP, TCP and WebSocket with managed TLS.
- **Pricing:**
  - On demand: $0.00115 per vCPU-minute (0.25–4 vCPU), and **egress $0.10/GB**.
  - Private fleet: $280/host/mo on a 12-month term, for 16 vCPU with 6 TB egress included.
  - Matchmaker tiers: ~$22, ~$105 or ~$395/mo.
  - Free trial: 1.5 vCPU, 60-minute uptime cap.
- **Matchmaker:** latency rules, custom rules such as rating difference, and backfill. It has no accounts or persistence.
- **Cost estimate:**
  - **100 CCU:** 5 races × 0.25 vCPU is about $63 compute plus ~$210 egress, so **~$275/mo**.
  - **10k CCU:** ~$6.3k compute plus ~$21k egress, so **~$27k/mo on demand**. That falls sharply on a private fleet.

**Amazon GameLift Servers** ([supported tools](https://docs.aws.amazon.com/gameliftservers/latest/developerguide/gamelift-supported.html), [pricing](https://aws.amazon.com/gamelift/servers/pricing/)):

- **Server side:** server SDKs exist for C++, C# and Go. A **game server wrapper** hosts a server "without … integrat[ing] the server SDK", so a Swift binary can run on Amazon Linux 2023.
- **Client side:** client SDKs are C++, C#, Unity and Unreal, with no Swift. The iOS client only needs to call your backend and then open a UDP or WebSocket connection.
- **Cost:** network bandwidth is **free on eligible (gen 6+) instances**, which matters at 10k CCU. Per-instance hourly prices are on a JavaScript-rendered table I could not read ([instance pricing](https://aws.amazon.com/gamelift/servers/pricing/instance-pricing/)).
- **Extras:** FlexMatch provides matchmaking. You still build persistence.

**Hathora:** acquired by Fireworks AI. It announced on 2026-03-04 that it was leaving game hosting, shut down on 2026-05-05, and moved customers to Nitrado GameFabric ([GamesBeat](https://gamesbeat.com/hathora-acquired-will-exit-game-infrastructure-biz-and-hand-over-customers-to-nitrado/), a secondary source citing `blog.hathora.dev/hathora-is-joining-fireworks-ai/`). Stormgate's online modes went down as a result, which shows the vendor risk.

**Rivet:** the pricing page now lists only Actors, agentOS and workflows: Free, then Hobby at $20/mo and Team at $200/mo, open source under Apache 2.0. There is no game-server or UDP offering ([pricing](https://www.rivet.dev/pricing)).

## Comparison

| Option | Transport | Regions | Swift client | RegattaCore server-side | Matchmaking | Persistence | ~100 CCU/mo | ~10k CCU/mo |
|---|---|---|---|---|---|---|---|---|
| GameKit `GKMatch` | P2P (reliable/unreliable) | Apple (undocumented) | Native | ✗ (host is a phone) | ✓ (max **16**) | Leaderboards only | $0 | $0 |
| Swift/NIO on Fly.io | UDP\*, WS | 18 | Native (URLSession / Network) | ✓ native Linux | Build | Build (Postgres) | ~$15–150 | ~$6k |
| Swift/NIO on Hetzner | UDP, WS | DE, FI, US, SG | Native | ✓ native Linux | Build | Build | ~$10–50 | ~$1.3–2k |
| Cloudflare DO | WS only | ~11 hint areas | Native WS | Port to TS or unproven Wasm | Build (lobby DO) | DO SQLite / D1 | ~$20–60 | ~$3–6k |
| Nakama (self-host) | WS | Wherever you host | Official SDK | Port to Go/TS | ✓ | ✓ accounts, Game Center auth, leaderboards | ~VPS cost | ~VPS cost + DB |
| Edgegap | UDP, TCP, WS | 615+ | Any (your protocol) | ✓ Docker | ✓ (paid tier) | ✗ | ~$275 | ~$27k on demand |
| GameLift | UDP, TCP | AWS regions | No SDK (not needed) | ✓ via wrapper | FlexMatch | ✗ | Calculator | Calculator (free bandwidth) |

\*On Fly.io, UDP needs a dedicated IPv4, and I found no documented way to pin a UDP flow to a specific Machine.

Cost figures are my estimates from the assumptions above, not vendor quotes.

## Latency note

None of these providers publishes latency figures. For a server-authoritative game, round-trip time is set mainly by the distance to the chosen region.

- The choice is really between a handful of regions and per-match placement:
  - A handful of regions: VPS or Fly.io, the latter with 18 including Tokyo, Sydney and São Paulo.
  - Per-match placement: Edgegap, Durable Objects.
- **WebSocket runs over TCP.** On lossy mobile links, a lost packet stalls later snapshots (head-of-line blocking). UDP or QUIC datagrams avoid that.
- Sailing boats are slow and turn slowly. Client-side prediction plus 20 Hz snapshots over WebSocket is likely tolerable. Unmeasured, it's an assumption to validate with a prototype.

## Open questions for the design

1. Is a 16-human cap acceptable, with bots filling the rest? If so, Game Center hosted-match matchmaking becomes an option as a front end.
2. What tick and snapshot rates are needed? A 20 Hz sim with 10 Hz snapshots would halve bandwidth and egress cost.
3. Benchmark `Race.step` with 20 boats on Linux to replace the races-per-vCPU assumption.
