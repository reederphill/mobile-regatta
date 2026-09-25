# Rules configuration file, schema version 1

The rules configuration is an immutable, versioned data file (ADR 0004, #32, #73), loaded by
`DataFile<RulesConfig>` (`RulesConfigFile`) through the same loader as boat classes and venues. It holds
every replay-affecting value the rules and the race format use: none of them is folded into the
simulation version. A race log records the file's ref (id, version, SHA-256 of its exact bytes) in
`RaceSetup.rulesConfiguration`, so retuning any value, including tuning the rules from protest data,
ships a new version and never changes how an old race replays. Old versions ship for as long as their
race logs must replay.

The code is `Packages/RegattaCore/Sources/RegattaCore/RulesConfig.swift`: `RulesConfigSchema1` is the
file as written, and `RulesConfig` is the loaded value (angles in radians; durations stay in seconds,
`RulesConfig.ticks(_:)` converts them). The race-format values are a section of this file, not a sibling
file, so one ref covers both.

Files are `<id>@<version>.json` in `Sources/RegattaCore/Resources/rules/`. A released version never
changes; a change ships as `<id>@<version + 1>.json`.

- `fleet-rules@1` (bundled): the v1.0 fleet race. `Race.defaultRulesConfiguration` until race assembly
  reads `RaceSetup.rulesConfiguration` (#81).

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
  (#35), the edge speed retention (#82) and the beat-sizing calibration factor (#80, #105).

The loader refuses unknown fields and `null`s (as for venues), duplicate keys, and any value outside
the ranges below.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion`, `id`, `version` | header | As for every data file. `schemaVersion` is 1. |
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

### Zone

| Field | Unit | v1 | Meaning |
|---|---|---|---|
| `radiusHullLengths` | L | 3 | The zone's radius. `Course.zoneRadius` = this × the class hull length. |

### MarkRoomGiven (builder value)

Mark-room was given when the boat entitled to it could pass the mark within `roundingDistanceHullLengths`
of it with at least `clearanceHullLengths` between hulls.

| Field | Unit | v1 |
|---|---|---|
| `roundingDistanceHullLengths` | L > 0 | 1 |
| `clearanceHullLengths` | L ≥ 0 | 0.25 |

### OnABeat (builder value)

A boat is on a beat when her true wind angle is at most `maxTrueWindAngleDegrees` and, if
`windwardLegOnly`, her leg ends at a windward mark.

| Field | Unit | v1 |
|---|---|---|
| `maxTrueWindAngleDegrees` | degrees, (0, 180] | 60 |
| `windwardLegOnly` | bool | true |

### RaceFormat

| Field | Unit | v1 | Meaning |
|---|---|---|---|
| `startSequenceSeconds` | s | 60 | Sequence start to gun. `RaceSetup.defaultStartSequenceTicks`. |
| `penalty.startSeconds` | s | 15 | After a rule call, the penalty must be started by then. |
| `penalty.completeSeconds` | s ≥ start | 30 | … and completed by then. |
| `penalty.startedTurnDegrees` | degrees, (0, 360] | 30 | Turned this far, the penalty counts as started. |
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
| `edgeSpeedRetention` | [0, 1] | 0.3 | *Placeholder.* Fraction of her speed along the edge a boat keeps on meeting land or the boundary (#82). |
| `beatSizing.leaderSeconds` | s > 0 | 480 | The beat is sized for a leader's race of about this long (#8) … |
| `beatSizing.maxMetres` | m | 360 | … and at most this (#14) … |
| `beatSizing.calibrationFactor` | > 0 | 1 | *Placeholder.* … scaled by this, calibrated with the bot suite (#80, #105). |

## What reads it today

The simulation behaviour is unchanged by #73: the zone (3 L) and the start sequence (60 s) are read from
the file, and each rule call's penalty deadlines come from `penalty`. The other values are loaded,
checked and exposed for the tickets that use them (#80–#96); until then the race keeps its old
behaviour (for example, a 180 s finish window and no time limit).
