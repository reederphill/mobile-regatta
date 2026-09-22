---
id: 3
title: Real-time multiplayer infrastructure options
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

What are the realistic options for hosting a small-scale, server-authoritative, real-time (20–60 Hz) physics game with iOS clients: Game Center / GameKit real-time, custom UDP or WebSocket servers, Cloudflare Durable Objects, Nakama, Hathora/Edgegap-style hosting, etc.? For each: latency, regions, cost at ~100 and ~10k concurrent players, Swift client support, and fit for running the existing Swift RegattaCore simulation on the server (Swift on Linux vs. a port).

## Context

Findings: branch `research/realtime-multiplayer-infrastructure`, file `docs/research/realtime-multiplayer-infrastructure.md`.

## Resolution

Resolved by research; full findings on branch `research/realtime-multiplayer-infrastructure` in `docs/research/realtime-multiplayer-infrastructure.md`. Prices were read 2026-09-22. Cost figures are rough, untested estimates.

- **Game Center:** can't be the race server. Both match types cap at 16 players, and real-time matches are peer-to-peer rather than server-authoritative. Use it for identity (the server can verify the player), leaderboards and invites.
- **RegattaCore on Linux:** runs almost unchanged. The only Apple-only dependency is `simd`, used for three small helpers in `Geometry.swift`.
- **Custom Swift server (SwiftNIO) on a VPS or Fly.io:** best fit.
  - Hetzner: about $10–50/month at 100 concurrent players, $1.3–2k/month at 10k.
  - Fly.io: about $15–150/month at 100, around $6k/month at 10k, mostly bandwidth.
  - We'd build matchmaking, accounts and ratings ourselves (e.g. Postgres).
- **Cloudflare Durable Objects:** WebSocket only, and billed the whole time a race runs (about $3–6k/month at 10k). Needs a TypeScript port or Swift compiled to WebAssembly.
- **Nakama:** most built in (matchmaker, Game Center sign-in, leaderboards, chat, a Swift client), but server logic must be Go, Lua or TypeScript, so the simulation would be ported.
- **Edgegap / GameLift:** run the Swift binary unchanged and place each race near its players. Edgegap bandwidth is expensive (about $27k/month at 10k).
- **Hathora** (reportedly shut down in 2026) and **Rivet** are no longer options.

Recommendation: Swift race server over WebSocket first on a few VPSs or Fly.io machines, Game Center sign-in, Postgres for ratings. The same binary can move to Edgegap or GameLift later.
