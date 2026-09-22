---
title: Regatta v1.0 game design
labels: [wayfinder:map]
status: open
---

## Destination

A complete **game design spec for Regatta v1.0**, the version we'd ship to the App Store. Every system (controls, rules, wind and current, venues and courses, boat performance, information design, multiplayer, bots, monetization, look and feel) is decided in enough detail that implementation can be broken into build tickets with no design questions left open.

## Notes

- **Domain:** a mobile sailing race game and a native iOS app (Swift, SpriteKit and SwiftUI). A working prototype already exists in this repo. `Packages/RegattaCore` holds the simulation and `Regatta/` holds the app. Check what the code does before deciding against it.
- **Glossary:** use the terms in [`CONTEXT.md`](../../CONTEXT.md) (fleet race, venue, course, leg, mark, OCS, penalty turns, puff, current, boat class, livery). Update it as terms settle. Consult the `domain-modeling` skill in every grilling session.
- **Fixed framing:**
  - **Realism:** an accessible sim. The real Racing Rules of Sailing and real tactics, with boat handling kept simple.
  - **Platforms:** iPhone and iPad, portrait-first.
  - **Boats:** one boat class in v1.0, with the architecture meant for exploring more classes later.
  - **Multiplayer:** real-time and online, with the server deciding the result.
  - **Accessibility:** colour-blind-safe palettes only.
- **Standing preference:** when a decision would constrain the later modes (match racing, regattas and the career ladder in 1.1, the tutorial in 1.2), note the constraint in the ticket, but don't design those modes here.
- **Tracker:** local markdown. See [`README.md`](README.md). List the frontier with `python3 docs/wayfinder/frontier.py`.

## Decisions so far

<!-- one line per closed ticket: [title](tickets/NN-slug.md): gist -->

## Not yet specified

- **First-run experience without a tutorial:** v1.0 has no tutorial (that's 1.2), but a new player still has to learn to steer, start and avoid fouls. How much in-race hinting, and in what form, depends on the controls and information-design decisions.
- **Post-race screen and stats:** what every player sees after a race versus what the paid tier adds. Depends on the paid-tier decision. Replays are out of v1.0, so any debrief has to come from recorded race data.
- **Navigation and screen map:** menus, settings, profile and how they connect. Depends on the multiplayer flow and monetization.
- **Fair play:** anti-cheat for client input, abuse of rule mechanics (deliberately causing fouls), and quitting to protect a rating. Depends on the netcode and multiplayer flow.
- **Performance budget and minimum devices:** frame-rate targets, oldest supported iPhone and iPad, battery and thermal limits. Depends on art direction and information design.
- **Telemetry and privacy:** what we measure to tune balance, and App Store privacy labels.
- **Ranked seasons:** whether and how ratings reset or decay. Depends on the multiplayer flow.
- **Future boat-class exploration:** which class data and presentation hooks must exist in v1.0 so a second class can be tried cheaply. Graduates once the boat performance model settles.

## Out of scope

- **Match racing, regatta series, career ladder:** planned for 1.1.
- **Tutorial or academy:** planned for 1.2.
- **Team racing, time trials and ghost races:** not planned for v1.0.
- **Private races, live spectating, replays:** lobby chat is the only social feature in v1.0.
- **Real-world venues:** venues are fictional.
- **Multiple boat classes in v1.0:** one class ships, but the design stays open to more.
- **Accessibility beyond colour-blind-safe palettes, and localisation:** v1.0 ships in English.
- **AI coaching and written debriefs**
- **Android and web clients**
