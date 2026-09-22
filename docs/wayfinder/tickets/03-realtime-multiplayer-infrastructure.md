---
id: 3
title: Real-time multiplayer infrastructure options
labels: [wayfinder:research]
parent: map
status: open
assignee:
blocked_by: []
---

## Question

What are the realistic options for hosting a small-scale, server-authoritative, real-time (20–60 Hz) physics game with iOS clients: Game Center / GameKit real-time, custom UDP or WebSocket servers, Cloudflare Durable Objects, Nakama, Hathora/Edgegap-style hosting, etc.? For each: latency, regions, cost at ~100 and ~10k concurrent players, Swift client support, and fit for running the existing Swift RegattaCore simulation on the server (Swift on Linux vs. a port).

## Context

Findings: branch `research/realtime-multiplayer-infrastructure`, file `docs/research/realtime-multiplayer-infrastructure.md`.
