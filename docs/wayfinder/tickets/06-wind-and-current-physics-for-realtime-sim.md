---
id: 6
title: Physical models of wind, current and shoreline effects for a real-time sim
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

What lightweight, real-time-friendly models exist for: oscillating vs persistent wind shifts and their typical periods/amplitudes; puff and lull size, speed and lifetime; wind bending and accelerating around headlands and shorelines; wind shadow from land; tidal current varying across a venue and over a tidal cycle; and wind-against-tide effects? How do other sims (Sailaway, VR Inshore, tactical trainers) approximate them? Output parameters and formulas usable by the wind and current tickets.

## Context

Findings: branch `research/wind-and-current-physics-for-realtime-sim`, file `docs/research/wind-and-current-physics-for-realtime-sim.md`.

## Resolution

Resolved by research; full findings on branch `research/wind-and-current-physics-for-realtime-sim` in `docs/research/wind-and-current-physics-for-realtime-sim.md`.

**Wind shifts:**
- Real oscillations last about 3 minutes in heavy air to over 10 minutes in light air, and swing about 5–40°.
- A sea breeze swings persistently by about 5–10° per hour.
- Model: two or three sines with periods that never repeat together, plus a slow ramp or pulses. Game races need these periods compressed.

**Puffs and lulls:**
- At 10–12 kn they are 100–200 m across the wind, about twice that at 20 kn.
- They add 30–40% wind, cover about half the water, recur about every 60 s and last 2–4 minutes.
- They fan out from their centre, lifting a boat on one side and heading one on the other.
- Model: discs with an outward-pointing direction change, placed by a hash per grid cell so no state is stored. Moving noise can add background texture.

**Shorelines and land:**
- Experts disagree on which way wind bends at a shore, so design it per venue rather than from one rule.
- Model: a precomputed grid holding bending towards the shore, stronger or weaker bands along the coast, and 1.2–2× speed-ups at headlands.
- Shadow behind land (from windbreak data): strongest at 2–5 times the obstacle's height, useful to 10 times, measurable to 30 times. Fits `0.7·exp(−x/10H)`.

**Current:**
- Follows a sine from slack (the 50/90 rule; one tide cycle is 12 h 25 min).
- Strongest in deep channels, weaker in shallows by depth to the power 2/3.
- Turns first near the shore.
- Headland eddies can be a steady swirl whose strength follows the tide.

**Wind against tide:**
- Each boat sails in the wind minus the current, then moves over ground with the current added back.
- A chop penalty on upwind speed is a tuning value; no source gives a number.

**Other sims:**
- Sailaway: real forecast data.
- VR Inshore: internals unpublished.
- eSail: shore bending, no current.
- Trainers: hand-made grids.

**Cost:** a deliberately heavy sample takes about 127 ns on an M1. 20 boats at 60 Hz is about 0.3 ms of CPU per second, and 500 races on a server use about 0.15 of a core. The real constraints are drawing it on the water and keeping client and server results identical.
