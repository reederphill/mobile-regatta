# Wind is keyed per time window, revealed just ahead

Wind is a pure function so the server and every client compute it identically without streaming it, but a pure function of one race seed would let a modified client compute every future shift and puff, and knowing the next shift is most of the game. So wind is a pure function of a chain of time-window keys, the venue, the race clock and position, and the server reveals each key about 30 s before its window starts: roughly how far ahead an honest player can see puffs anyway. After the race the full chain is known, so the race stays reproducible.

## Considered options

- **One seed per race:** simplest, but gives a modified client full foresight.
- **Server streams wind state:** no foresight, but adds bandwidth on top of the ~8 KB/s per player snapshots and needs wind snapshots for late joiners, losing the "free on every device" property.
- **Accept the risk for v1.0:** rejected because foresight breaks the promise that races are won by reading the wind, not luck.

## Consequences

- Nothing in the wind may be derivable from information known at race start, including the oscillating shift. Shifts last 90–180 s but windows are about 30 s, so the oscillation has to be built from per-window values joined smoothly across window boundaries; any smoothing that reads later windows' keys lengthens the reveal lead. The exact scheme is for "Netcode and authority model" to settle.
- Clients only need to match the server closely enough for prediction, since the server decides results; last-bit differences between Darwin and glibc `sin`/`exp` are harmless.
- Bots run on the server and could read unrevealed keys; they are limited to what a player could perceive.
- The current mutable `WindField` puff list, and the physics research's "server sends only the seed and venue ID", are superseded.
