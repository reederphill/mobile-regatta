# Boat classes, venues and the rules configuration are immutable data files

A boat class is one versioned JSON file (hull, polar, momentum, steering, shadow, contact), shipped in the app and on the server; RegattaCore holds no boat constants. A released version never changes: tuning ships a new version, and each race log records the class id and version it was sailed with. This lets new classes be explored without code changes, and keeps every logged race replayable (ADR 0002) even after the boat is retuned.

Venues and the rules configuration are handled the same way (settled in [Versioning of venue data and the rules configuration](https://github.com/reederphill/mobile-regatta/issues/32)). A venue's data (land polygons, geographic-shift grid, depth grid and current, the conditions it allows with their mean and trend directions, anchors) and the named conditions entries it draws on are immutable, versioned files. So is the rules configuration (near-miss sweep, escape horizon, incident separation, last-point-of-certainty margin, zone size). Each race log records the id and version of its boat class, its venue and conditions, and its rules configuration, so retuning any of them, including tuning the rules from protest data, never changes how an old race replays.

## Considered Options

- **Swift constants in RegattaCore:** rejected because every tuning pass or new class would be a code change, and retuning would silently change how old race logs replay.
- **Editable class data (tuned in place):** rejected for the same replay reason.
- **Version only boat classes, and fold venues and rules into the simulation version:** rejected because every venue or rules tweak would then bump the simulation version and need its own replay build kept on the server.

## Consequences

- Client and server must agree on the files: the server names each file's id and hash (class, venue, conditions, rules configuration) at race start.
- Old versions of every file ship for as long as their race logs must replay.
- Derived values (best upwind and downwind angles, course sizing) are computed from the files at load, never stored in them.
- Behaviour that needs new code (spinnaker, foils, trim or pump inputs, a new course type) is a code change plus a new schema version, not just a new file.
- Tuned copies from the debug tuning panel ([#229](https://github.com/reederphill/mobile-regatta/issues/229)) keep their base id and version and differ by hash plus an optional `tune` number in the file ref, which the race log records. They exist only in debug and internal TestFlight practice races, and a tuned log replays only with its generated files saved beside it.
- A venue's seed pool isn't part of the versioned venue file: the log records the seed a race used, so changing the pool never affects a replay.
