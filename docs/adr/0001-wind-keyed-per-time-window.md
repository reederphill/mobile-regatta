# Wind is keyed per time window, revealed just ahead

Wind is a pure function so the server and every client compute it identically without streaming it, but a pure function of one race seed would let a modified client compute every future shift and puff, and knowing the next shift is most of the game. So wind is a pure function of a chain of time-window keys, the venue, the race clock and position, and the server reveals each key about 30 s before its window starts: roughly how far ahead an honest player can see puffs anyway. After the race the full chain is known, so the race stays reproducible.

## Considered options

- **One seed per race:** simplest, but gives a modified client full foresight.
- **Server streams wind state:** no foresight, but adds bandwidth on top of the ~8 KB/s per player snapshots and needs wind snapshots for late joiners, losing the "free on every device" property.
- **Accept the risk for v1.0:** rejected because foresight breaks the promise that races are won by reading the wind, not luck.

## Consequences

- Nothing in the wind may be derivable from information known at race start, including the oscillating shift. Shifts last 90–180 s but windows are about 30 s, so the oscillation has to be built from per-window values joined smoothly across window boundaries; any smoothing that reads later windows' keys lengthens the reveal lead.
- The scheme, settled in [Netcode and authority model](https://github.com/reederphill/mobile-regatta/issues/18): windows are 30 s, with a knot at each boundary. A window's key gives the shift's value **and slope** at the next knot, plus that window's puff spawns. Within a window the shift follows a cubic Hermite curve between its two knots, so it is smooth across boundaries and reads only the next knot. Knot values come from an oscillator whose period is redrawn within 90–180 s. The key for the knot ending window *k* must be known by the start of window *k*, so the reveal lead is one window (30 s), and exact foresight of the shift is 0–30 s. Puffs fade in, so an early key reveals little that can't soon be seen.
- Clients only need to match the server closely enough for prediction, since the server decides results; last-bit differences between Darwin and glibc `sin`/`exp` are harmless.
- Bots run on the server and could read unrevealed keys; they are limited to what a player could perceive.
- A vetted wind seed sails at most one online race ([G1 on the build plan map](https://github.com/reederphill/mobile-regatta/issues/37#issuecomment-5801505861)). Anyone who sailed it holds its full key chain and could recognise a reuse from the first key. Seed pools are topped up per venue × conditions × tide state instead.
- The current mutable `WindField` puff list, and the physics research's "server sends only the seed and venue ID", are superseded.
