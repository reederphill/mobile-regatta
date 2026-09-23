# Full-world prediction without server rewind

Every client runs RegattaCore for the whole fleet, not only its own boat: it applies its own inputs and assumes every other boat, bots included, keeps its last known input. The client runs ahead of the server clock by its one-way latency plus a small jitter buffer, so its inputs reach the server before the tick they are stamped for. The server applies each input at its stamped tick, or at the next tick if that one has already been simulated, and never rewinds. The umpire judges the one server timeline, and the input log is exactly what the server applied.

We did this because sailing is decided at close quarters. With the usual approach (predict your own boat, show others interpolated ~200 ms in the past) a rival appears about a quarter of a boat length behind where the umpire has her, so crossings that look clear get called as fouls. Boats are slow and turn slowly, so assuming held inputs is right almost all the time and wrong only briefly after someone moves the rudder.

## Considered options

- **Own boat predicted, others interpolated:** the standard for shooters and simple to build, but it shows other boats in the past, which is where rule calls happen.
- **Server rewind (lag compensation):** the server would judge each input against the world as that player saw it. Rejected: it makes the umpire's timeline depend on each player's latency, lets a lagging or tampered client claim favourable timings, and means the log no longer shows one plain sequence of what happened.
- **Input delay / lockstep:** everyone waits for everyone's inputs. Rejected: one slow phone would delay the whole fleet, and it needs bit-for-bit determinism on iOS, which ADR 0002 decided against.

## Consequences

- Each client simulates up to 16 boats at the 30 Hz tick, which counts against the device performance budget.
- Snapshots must carry each boat's held input as well as her state, so clients can predict her.
- Prediction errors are eased out over about 150 ms, and snapped when they're larger than a boat length. The client never shows a rule call until the server sends it.
- A late input takes effect a tick later than intended. A player on a slow link pays for their own latency, and nobody else does.
- The last-point-of-certainty margin (0.5 s) must stay longer than typical prediction error, so a flickering overlap never changes who has right of way.
