---
id: 1
title: Sailing game landscape teardown
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

How do existing sailing games (Regattatron, Virtual Regatta Inshore, eSailing / Sailaway, and any notable mobile titles) handle controls, boat handling, rule enforcement, wind and current display, race length, modes, lobby/matchmaking and monetization? What do players praise and complain about? Output: a comparison that later tickets can cite, with explicit 'steal this / avoid this' calls.

## Context

Findings: branch `research/sailing-game-landscape`, file `docs/research/sailing-game-landscape.md`.

## Resolution

Resolved by research; full findings on branch `research/sailing-game-landscape` in `docs/research/sailing-game-landscape.md`. Some claims rest on search-result excerpts and are marked as such in the file.

- **Controls:** Virtual Regatta (VR) Inshore uses left/right arrows, a one-tap tack/gybe that keeps the same wind angle, a sail-choice button and an "ease" button. Players say the arrows are either too twitchy or too sluggish. On small mobile titles, taps that don't register are the top complaint. Tilt steering and manual sheeting are also disliked.
- **Rules:**
  - Regattatron enforces rules 10, 11, 18, 22 and 31 on the server, judged on actual hull contact.
  - VR Inshore penalises instantly with a timed slowdown, shows the rule number, and disqualifies after two penalties. Its top complaint: it ignores who caused a collision, so barging pays.
  - Sailaway (a PC sim) has no rules at all.
- **Wind and current:** wind is shown as numbers (VR) or drawn on the water (Regattatron's puffs and wind shadow). No mobile racer found simulates current; only Sailaway does.
- **Length and modes:** VR races run about 10 minutes with a 1-minute start sequence and up to 10 boats. Regattatron allows up to 20 boats on windward-leeward laps.
- **Lobby:** Regattatron uses a chat lobby rather than a queue, with bots filling seats, daily regattas and one ELO ladder.
- **Monetization:** VR sells laylines, wind data and a steering aid (pay-to-win). Regattatron Pro sells only the debrief and cosmetics.

**Steal:**
- Fouls decided by the server, with the rule number shown.
- One-tap tacks.
- Bots filling empty seats.
- A chat lobby with daily regattas and one ELO ladder.
- Races of about 10 minutes.
- Wind drawn on the water.
- A paid tier for analysis and cosmetics only.

**Avoid:**
- Selling tactical information or steering help.
- Penalties that let barging pay.
- Penalising an early start twice (time penalty plus returning).
- Fixed-rate arrow or tilt steering.
- No rule enforcement.
- Automation that beats skill.
- Losing a race to a disconnect.

**Gaps:**
- VR's help centre and forum couldn't be read.
- Regattatron's controls and penalty mechanics are only visible after signing in.
- World Sailing's virtual racing rules PDF was unreachable.
- No Reddit threads were found.
