# Rules configuration file, schema versions 1, 2 and 3

The rules configuration is an immutable, versioned data file (ADR 0004, #32, #73), loaded by
`DataFile<RulesConfig>` (`RulesConfigFile`) through the same loader as boat classes and venues. It holds
every replay-affecting value the rules and the race format use: none of them is folded into the
simulation version. A race log records the file's ref (id, version, SHA-256 of its exact bytes) in
`RaceSetup.rulesConfiguration`, so retuning any value, including tuning the rules from protest data,
ships a new version and never changes how an old race replays. Old versions ship for as long as their
race logs must replay.

The code is `Packages/RegattaCore/Sources/RegattaCore/RulesConfig.swift`: `RulesConfigSchema` is the
file as written (every schema), and `RulesConfig` is the loaded value (angles in radians; durations stay
in seconds, `RulesConfig.ticks(_:)` converts them). The race-format values are a section of this file,
not a sibling file, so one ref covers both.

Files are `<id>@<version>.json` in `Sources/RegattaCore/Resources/rules/`. A released version never
changes; a change ships as `<id>@<version + 1>.json`.

- `fleet-rules@1` (bundled, schema 1): the v1.0 fleet race. Kept so its race logs replay.
- `fleet-rules@2` (bundled, schema 2): version 1 plus `startRow.minimumSpacingHullLengths` (#85). Kept so
  its race logs replay.
- `fleet-rules@3` (bundled, schema 3): version 2 plus `penalty.stackedPenaltyDeadlines`, `sequential` (#89,
  G4), with the penalty deadlines loosened a little, to 20 s and 40 s (#9's 15 s and 30 s; the owner, #89).
  The default (`RaceFiles.defaults`, `Race.defaultRulesConfiguration`).

Schema 2 is schema 1 plus `raceFormat.startRow.minimumSpacingHullLengths`, the start row's spacing floor:
required in schema 2, refused in schema 1. A schema-1 file has no floor (`RulesConfig.StartRow.minimumSpacing`
is nil), so a start row squeezed off land narrows its spread with its depth, as #82 squeezed its placement.
Schema 3 is schema 2 plus `raceFormat.penalty.stackedPenaltyDeadlines`: required in schema 3, refused
before it. A schema-1 or -2 file means `fromCall`, which is what it meant: each penalty turn's deadlines from
its own call.
The tables' `v1` column gives version 1's values; version 2's are the same, plus that floor, and version
3's the same again, plus `sequential` stacking and its looser penalty deadlines (marked v3).

## Units

- Durations are **seconds**, and each must be a **whole number of ticks** (1/30 s): the loader refuses
  anything else, so every tick count derived from the file is exact.
- Angles are **degrees**; the loader converts them to radians.
- Sizes are in **hull lengths (L)** of the race's boat class (`BoatClass.Hull.length`), so one file fits
  every class: `HullLengths.metres(hullLength:)` gives metres. Course sizes that scale with the course
  are in **line lengths** or **fractions of the beat**. Field names carry their unit
  (`radiusHullLengths`, `horizonSeconds`, `headingDegrees`).

## Builder values and placeholders

- `builderValues` lists, as JSON Pointers, the values the spec leaves to the builder: the near-miss sweep
  geometry, the escape simulation's candidate set, start tick and "initially" window, and the
  mark-room-given and "on a beat" tests. Each must resolve (the loader checks). They are ordinary data:
  changing one is a new version like any other value.
- `placeholders` (the header field every data file has) lists values awaiting tuning: the start row
  (#35, and from version 2 its spacing floor, #85), the edge speed retention (#82) and the beat-sizing
  calibration factor (#80, #105).

The loader refuses unknown fields and `null`s (as for venues), duplicate keys, and any value outside
the ranges below.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion`, `id`, `version` | header | As for every data file. `schemaVersion` is 1, 2 or 3. |
| `placeholders` | [JSON Pointer] | Optional. Values awaiting tuning; each must resolve. |
| `builderValues` | [JSON Pointer] | Values the builder chose; each must resolve. |
| `notes` | [string] | Optional free text; ignored by the loader. |
| `incidents` | Incidents | How incidents are detected and separated. |
| `zone` | Zone | The rule 18 zone. |
| `markRoomGiven` | MarkRoomGiven | Builder value: the test of whether mark-room was given (rule 18.2). |
| `onABeat` | OnABeat | Builder value: the test of whether a boat is on a beat (rule 18.1(a)). |
| `raceFormat` | RaceFormat | Sequence, penalties, windows, limits and course sizes. |

### Incidents

| Field | Unit | v1 | Meaning |
|---|---|---|---|
| `nearMissSweep.headingDegrees` | degrees, (0, 90] | 10 | The right-of-way boat's heading is swept this far either way … |
| `nearMissSweep.seconds` | s | 0.5 | … and she is sailed on this long, to see whether she would have hit. |
| `nearMissSweep.headingSamples` | count, odd ≥ 3 | 5 | *Builder value.* Headings tried, evenly spaced, both ends and straight on included. |
| `nearMissSweep.stepTicks` | ticks ≥ 1 | 1 | *Builder value.* Ticks between the positions checked along each heading. |
| `nearMissSweep.clearanceHullLengths` | L ≥ 0 | 0 | *Builder value.* Hulls closer than this count as a hit. |
| `escape.horizonSeconds` | s | 2 | How far ahead the escape simulation looks: could the keep-clear boat have kept clear? |
| `escape.candidates.rudder` | [−1…1] | −1, −0.5, 0, 0.5, 1 | *Builder value.* Rudders tried. |
| `escape.candidates.ease` | [bool] | false, true | *Builder value.* Ease settings tried. The candidate set is every rudder with every ease, rudder outermost, in file order. |
| `escape.startTickOffset` | ticks ≥ 0 | 1 | *Builder value.* The simulation starts this many ticks after the obligation began (its last point of certainty): the first tick the keep-clear boat can answer. |
| `escape.initiallySeconds` | s | 2 | *Builder value.* The "initially" window of rules 15 and 16.1: how long after acquiring right of way a boat must give the other room to keep clear. |
| `separationHullLengths` | L | 2 | Contacts between the same two boats closer together than this are one incident. |
| `lastPointOfCertaintySeconds` | s | 0.5 | A change in overlap or zone state counts only once it has held this long (#18). |

A ruling is triggered by contact or by a near miss (#9, #88). **The near-miss sweep** (builder geometry,
`RulesConfig.NearMissSweep.hits`): for a pair overlapped as of the last point of certainty, not touching and
with no incident open, the right-of-way boat (the other must keep clear, `Rules.judge`) is tried on each of
`headingSamples` headings evenly spaced across ±`headingDegrees` of her own, at her speed through the water
plus the current. On each, both boats sail on in straight lines at those velocities over the ground (the
keep-clear boat on her own heading and velocity), checked every `stepTicks` ticks from the first through
`seconds`. Any check with the hulls overlapping, or closer than `clearanceHullLengths`, is a near miss. No
turning, no speed change, no dynamics along the way (#92's escape simulation is the dynamic one). Only the
authoritative race sweeps: a prediction never calls a near miss.

**Incidents** are one per pair: the umpire (`UmpireState`) holds a pair's incident open from the contact or
near miss that opened it until their hulls are more than `separationHullLengths` apart; a touch or near miss
before then is part of the same incident and draws no second call.

### Zone

| Field | Unit | v1 | Meaning |
|---|---|---|---|
| `radiusHullLengths` | L | 3 | The zone's radius. `Course.zoneRadius` = this × the class hull length. |

### MarkRoomGiven (builder value)

Mark-room was given when the boat entitled to it could pass the mark within `roundingDistanceHullLengths`
of it with at least `clearanceHullLengths` between hulls. From #91: on a tick when she has passed the mark
(crossed the first rounding stage of the leg, or left the leg) with her hull within `roundingDistanceHullLengths`
of it and at least `clearanceHullLengths` from the other boat's hull, mark-room has been given, and rule 18 no
longer applies between the two at that mark.

| Field | Unit | v1 |
|---|---|---|
| `roundingDistanceHullLengths` | L > 0 | 1 |
| `clearanceHullLengths` | L ≥ 0 | 0.25 |

### OnABeat (builder value)

A boat is on a beat when her true wind angle is at most `maxTrueWindAngleDegrees` and, if
`windwardLegOnly`, her leg ends at a windward mark. From #91, rule 18 doesn't apply between two boats on
opposite tacks when both are on a beat (18.1(a)).

| Field | Unit | v1 |
|---|---|---|
| `maxTrueWindAngleDegrees` | degrees, (0, 180] | 60 |
| `windwardLegOnly` | bool | true |

### RaceFormat

| Field | Unit | v1 | Meaning |
|---|---|---|---|
| `startSequenceSeconds` | s | 60 | Sequence start to gun. `RaceSetup.defaultStartSequenceTicks`. |
| `penalty.startSeconds` | s | 15 (v3: 20) | Each owed penalty turn must be started this long after its clock starts, or she is disqualified (`missedStart`) … |
| `penalty.completeSeconds` | s ≥ start | 30 (v3: 40) | … and completed this long after it (`missedComplete`). v3 loosens #9's 15 s and 30 s a little (the owner, #89). |
| `penalty.startedTurnDegrees` | degrees, (0, 360] | 30 | Turned this far, the turn counts as started. |
| `penalty.stackedPenaltyDeadlines` | `sequential` or `fromCall`; schema 3 | — (v3: `sequential`) | When an owed turn's clock starts (#89, G4). Owed turns are served in order, each a call's one turn. `sequential`: at the later of its call and the completion of the turn before it, so a turn queued behind another gets its full start and complete windows once that one is done. `fromCall`: at its own call, however many turns are owed ahead of it. Absent before schema 3: `fromCall`. |
| `protestWindowSeconds` | s | 15 | After an incident, a protest can be lodged for this long. |
| `finishWindowSeconds` | s | 120 | After the first finish, the rest can finish for this long. |
| `timeLimitSeconds` | s | 960 | After the gun, the race ends whatever happens. |
| `startLine.hullLengthsPerBoat` | L | 1.25 | Line length = this × fleet size × L … |
| `startLine.minimumMetres` | m | 42 | … and at least this. |
| `leewardGate.aboveLineBeatDivisor` | > 1 | 6 | The gate's midpoint is beat ÷ this above the line. |
| `leewardGate.widthHullLengths` | L | 10 | The gate's width. |
| `offsetMark.toPortHullLengths` | L | 12 | The offset mark is this far to port of the windward mark, square to the axis. |
| `raceArea.acrossAxisBeatFraction` | × beat | 0.75 | The race area reaches this far either side of the axis … |
| `raceArea.belowLineLineLengths` | × line | 1 | … this far below the line … |
| `raceArea.aboveWindwardBeatFraction` | × beat | 0.25 | … and this far above the windward mark. |
| `startRow.depthLineLengths` | × line | 0.5 | *Placeholder.* The start row is this far below the line (#35) … |
| `startRow.spreadLineLengths` | × line | 1.5 | *Placeholder.* … spread over this width, centred on the line … |
| `startRow.trueWindAngleDegrees` | degrees | 90 | … on starboard, reaching at this true wind angle … |
| `startRow.polarSpeedFraction` | (0, 1] | 1 | *Placeholder.* … at this fraction of polar speed. |
| `startRow.minimumSpacingHullLengths` | L > 0; schema 2 | — (v2: 1.25) | *Placeholder.* A row squeezed off land (#82) never brings neighbours closer than this, centre to centre: clear ahead and clear astern (#35) with a quarter of a hull between them (#85). Absent in schema 1: no floor. |
| `edgeSpeedRetention` | [0, 1] | 0.3 | *Placeholder.* Fraction of her speed along the edge a boat keeps on meeting land or the boundary (#82). |
| `beatSizing.leaderSeconds` | s > 0 | 480 | The beat is sized for a leader's race of about this long (#8) … |
| `beatSizing.maxMetres` | m | 360 | … and at most this (#14) … |
| `beatSizing.calibrationFactor` | > 0 | 1 | *Placeholder.* … scaled by this, calibrated with the bot suite (#80, #105). |

## What reads it today

The simulation behaviour is unchanged by #73: the zone (3 L) and the start sequence (60 s) are read from
the file, and each rule call's penalty deadlines come from `penalty`. From #89 they are enforced, per owed
turn: a boat owing turns serves them in order, 360° one way each, and one that hasn't started her current
turn (turned `startedTurnDegrees`) at its start deadline, or completed it by its complete deadline, is
disqualified and a ghost at that tick. Under fleet-rules@3 (20 s and 40 s), two calls 5 s apart
(at t and t + 5 s), the first turn completed at c: the first turn's deadlines are t + 20 s and t + 40 s
either way; the second's are c + 20 s and c + 40 s under `sequential`, and t + 25 s and t + 45 s under
`fromCall`. The other values are loaded,
checked and exposed for the tickets that use them (#80–#96); until then the race keeps its old
behaviour. From #86 the race closes at `finishWindowSeconds` after the first finish, capped by
`timeLimitSeconds` after the gun (`Race.closeTick`). From #91 rule 18 reads the zone, `markRoomGiven`,
`onABeat` and the last point of certainty: the umpire records, per pair, who reached the zone of the mark
they are racing to first and whether they were overlapped (as of the last point of certainty) at that moment,
and so which is entitled to mark-room, until mark-room has been given, the entitled boat passes head to wind or
leaves the zone (out for the last point of certainty), or both have left the mark astern. The overlap terms
apply on opposite tacks while rule 18 applies between the boats. No rules-file value was added: schemas 1–3
all carry these.

Course derivation (#80): `CourseLayout.derive` reads `startLine`, `leewardGate`, `offsetMark`,
`raceArea`, `startRow`, `edgeSpeedRetention` and `beatSizing` to lay out the course, sizing the beat
from the class polar in the race's base strength (the model is on `CourseLayout.beat`). The race
sails it from #81; until then it sails `Course.standard`. From #85 the race places its boats with
`startRow` (`CourseLayout.startRow`): slots in the row, a seeded order, the heading and the speed. The
row is squeezed towards the line only where it would put a boat within a hull length of the race area's
boundary or its land, its neighbours never closer than `startRow.minimumSpacingHullLengths` (none with a
schema-1 file).
