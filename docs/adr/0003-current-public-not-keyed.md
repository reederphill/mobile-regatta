# Current is public, not keyed

ADR 0001 keys the wind per time window so a modified client can't see future shifts. Current goes the other way. It's a pure function of (venue, tide state at the gun, race clock, position), fully known at race start and shown to every player as a tide forecast. Real sailors race with tide tables, so reading the tide ahead is a legitimate skill, and a modified client gains nothing from information an honest player already sees.

## Considered Options

- **Key current per time window like wind:** rejected because it adds an unpredictability real tides don't have, and hides nothing worth hiding.
- **Server streams current state:** rejected because it adds bandwidth to protect information that's public anyway.

## Consequences

- Current can't have a random part (no current "puffs" or unforecast surges) without revisiting this decision, since anything random would need keys.
- The tide forecast has to be complete enough to plan from: when slack comes and where the tide turns first. A forecast that leaves things out would bring back hidden information.
- The tide state at the gun joins the race's recorded keys (ADR 0002), so a replay reproduces the current.
- The note on the Wind model ticket that current "uses the same window-key chain" is superseded.
