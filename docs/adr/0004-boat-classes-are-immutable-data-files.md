# Boat classes are immutable data files

A boat class is one versioned JSON file (hull, polar, momentum, steering, shadow, contact), shipped in the app and on the server; RegattaCore holds no boat constants. A released version never changes: tuning ships a new version, and each race log records the class id and version it was sailed with. This lets new classes be explored without code changes, and keeps every logged race replayable (ADR 0002) even after the boat is retuned.

## Considered Options

- **Swift constants in RegattaCore:** rejected because every tuning pass or new class would be a code change, and retuning would silently change how old race logs replay.
- **Editable class data (tuned in place):** rejected for the same replay reason.

## Consequences

- Client and server must agree on the file: the server names the class id and file hash at race start.
- Old class versions ship for as long as their race logs must replay.
- Derived values (best upwind and downwind angles, course sizing) are computed from the file at load, never stored in it.
- Behaviour that needs new code (spinnaker, foils, trim or pump inputs) is a code change plus a new schema version, not just a new file.
