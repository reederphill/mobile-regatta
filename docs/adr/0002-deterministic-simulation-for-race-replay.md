# Deterministic simulation for race replay

Every race is stored on the server as its keys (the race seed and the wind's chain of time-window keys from ADR 0001) and its input log, not as recorded state, so that any incident can be re-simulated exactly for a future protest jury and for training the v1.3 model that judges subjective rules. This makes RegattaCore a pure function of (keys, inputs, simulation version): bit-for-bit identical results on the Linux race server, with each log tagged with the simulation version that produced it and replayed by that version.

## Considered Options

- **Record state snapshots instead of inputs.** Robust to code changes, but much larger, and a replay couldn't be re-run to ask "what if" questions (the escape simulation for room, for example).
- **Deterministic on iOS clients too.** Rejected for now. Apple's maths library and glibc don't guarantee identical `sin`, `cos` and `atan2` results, and the server is the authority, so clients only need to be close.
- **Let old logs expire when the simulation changes.** Rejected: protests and incidents are the training data, and losing them on every physics change would defeat the point.

## Consequences

- No unseeded randomness and no wall-clock time in RegattaCore. All randomness comes from the race's recorded keys.
- Don't rely on `Double.random(in:using:)` or `Bool.random(using:)` for replayed values: the standard library says their algorithm may change in a future version of Swift, which would change replays with no code change of ours. Map generator output to ranges with our own functions.
- The server's Swift toolchain and C library are part of the simulation version. Upgrading either can change results, so it needs the same check as a physics change.
- Any change to simulation output bumps the simulation version, and the server keeps a build that can replay each version still in the logs. Golden replay tests (a fixed seed and input log with a known final state) catch unintended changes.
