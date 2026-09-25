# Venue file, schema version 1

A venue is an immutable, versioned data file (ADR 0004, #32), loaded by `DataFile<Venue>` (`VenueFile`)
through the same loader as boat classes (README, *Data files*). This page is the schema: every field,
its units, how the loader validates it, and how the current model (#78) reads the depth grid.
The code is `Packages/RegattaCore/Sources/RegattaCore/Venue.swift`: `VenueSchema1` is the file as
written (`Codable`, so tools can write files too), and `Venue` is the loaded value in code units.

Files are `<id>@<version>.json`: bundled ones in `Sources/RegattaCore/Resources/venues/`, test fixtures in
`Tests/RegattaCoreTests/Resources/venues/`. A released version never changes; a change ships as
`<id>@<version + 1>.json`, and the venue's seed pools are re-vetted with it.

- `dev-venue@1` (bundled): a stand-in for the app until the three real venues ship (#83). Open water,
  a shore strip beyond each side of the race area, no current, a pairing for each of the four conditions
  at version 1.
- `dev-venue@2` (bundled): `dev-venue@1` with its pairings on the schema-2 conditions files; the venue
  races use until race assembly reads `RaceSetup.venue` (#77, #81).
- `test-venue@1` (test resource): small hand-checkable grids, concave land, a tidal current with an eddy.

## Frame and units

- Positions are in the venue's own frame: **metres, x east, y north**, from an origin the file chooses.
  Points are `[x, y]` arrays.
- Directions are **compass bearings in degrees**, 0 = north, clockwise, in [0, 360). Wind directions are
  where the wind blows *from*; current directions are where the water flows *to*.
- Speeds are **knots**. The loader converts to radians and m/s once; derived values (the deepest node)
  are computed at load, never stored.
- Field names carry their unit (`cellSizeMetres`, `meanDirectionDegrees`, `peakKnots`).

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion`, `id`, `version` | header | As for every data file. `schemaVersion` is 1. |
| `placeholders` | [JSON Pointer] | Optional. Values awaiting tuning; each must resolve. |
| `notes` | [string] | Optional free text; ignored by the loader. |
| `displayName` | string | Name shown to players. Non-empty. |
| `landmarks` | [Landmark] | Silhouettes drawn on the land. May be empty. |
| `land` | [Land] | Land polygons. May be empty. |
| `pairings` | [Pairing] | The conditions this venue can have. At least one. |
| `current` | Current | The venue's current, or `{ "hasCurrent": false }`. |

There is **no start-line skew field**: the line is laid square to the seeded mean direction, and bias
comes only from the oscillation at the gun and geographic shift (#12 overrides #10's "deliberate skew").

### Landmark

| Field | Type | Meaning |
|---|---|---|
| `asset` | string | Asset name from `docs/assets-manifest.md` (#53). Checked only as non-empty for now. |
| `positionMetres` | [x, y] | Where the silhouette is anchored. |

### Land

| Field | Type | Meaning |
|---|---|---|
| `outlineMetres` | [[x, y]] | A closed ring: the last point repeats the first. |

Land is only at the edges of the race area (#12); the race area is the course rectangle trimmed by it (#82).
Polygons may be concave and may be written either way round; the loader stores them anticlockwise,
without the repeated closing point.

### Pairing (one per venue × conditions, #10, #12)

| Field | Type | Meaning |
|---|---|---|
| `conditionsRef` | `{ "id", "version" }` | The conditions file (#74) this pairing is authored for. |
| `meanDirectionDegrees` | bearing | Authored mean wind direction. The race seed varies it by up to ±10° (#77). |
| `trendDirection` | `"veer"`, `"back"` or `"either"` | Which way a persistent shift trends. Veer is clockwise (a right shift, looking upwind), back anticlockwise; `either` lets the race seed choose. Ignored for conditions with no persistent trend. |
| `startLineCentreMetres` | [x, y] | The anchor: the centre of the start line, from which the course is laid up the seeded mean direction (#80). |
| `geographicGrid` | Grid | Geographic shift for this pairing, land shadow baked in. |

`conditionsRef` names a version but no hash: the pairing's anchor, grid and the offline checks (#83)
were made against that conditions entry's wind range, so retuning the conditions ships a new venue
version too. Hashes are checked where files are loaded, against the refs the server names at race start.
`Venue.pairing(for:)` looks a pairing up by exact id and version (`pairing(for: setup.conditions.key)`);
another version of the same conditions has no pairing.

### Grids

The geographic grid and the current grid share one layout:

| Field | Type | Meaning |
|---|---|---|
| `originMetres` | [x, y] | Node (column 0, row 0). |
| `cellSizeMetres` | number | Spacing between neighbouring nodes. |
| `orientationDegrees` | bearing | Direction along which the row index grows. At 0 the row index grows northward and the column index eastward. |
| `columns`, `rows` | integer | Nodes per row and per column, at least 2 each. |
| value arrays | [[number]] | `rows` arrays of `columns` numbers each. Row 0 passes through the origin, so a file lists its southern row first when the grid isn't rotated. |

Node (c, r) is at `origin + c × cellSize × columnAxis + r × cellSize × rowAxis`, where
`rowAxis` points along `orientation` and `columnAxis` is 90° clockwise of it. Values are stored per node;
how they're sampled between nodes belongs to the consumer: `Venue.Grid.cell(containing:)` places a point
in the grid, and the geographic grid samples bilinearly and is neutral (no shift, factor 1) outside the
outer nodes, a point on the edge being inside (`Venue.GeographicGrid.sample`, #77); the current field is #78.

Geographic grid values:

| Array | Meaning |
|---|---|
| `directionDeltaDegrees` | Change in wind direction at the node, in (-180, 180); positive veers (clockwise). |
| `speedFactor` | Multiplier on wind speed at the node, > 0. Land shadow is baked in. |

## Current (#11, ADR 0003)

With no current, the object is exactly `{ "hasCurrent": false }`; any other field is an error.
With current:

| Field | Type | Meaning |
|---|---|---|
| `hasCurrent` | `true` | |
| `peakKnots` | number | Strength at the deepest node at peak tide, 0.5–2 kn (#11). |
| `tidal` | bool | A tidal venue's tide clock runs faster than real time. |
| `tideClockRate` | number | Tidal venues only, and required for them: tide-clock seconds per race second, > 1. About 19, so slack to peak takes about 10 min. Steady venues omit it and run at 1. |
| `allowedTideStatesAtGun` | `{ "fromDegrees", "toDegrees" }` | Tide states a race may start at, drawn per race (#11, #78). Both in [0, 360). The range runs forward from `from` to `to`, wrapping through 0 when `to < from`; equal ends mean one tide state. The one exception is `{ "fromDegrees": 0, "toDegrees": 360 }`: the whole cycle, any tide state. |
| `grid` | Grid | Layout as above, with `depthMetres` (≥ 0; 0 is dry, and some node must be deeper) and `floodDirectionDegrees` (bearing the flood flows towards; the ebb flows the opposite way). This is the channel direction field. |
| `byDepth` | `{ "strengthExponent", "shallowsLeadDegrees" }` | How strength and the turn of the tide follow depth, below. Both required. `strengthExponent` > 0 (authored; 2/3 recommended, Manning); `shallowsLeadDegrees` in [0, 90). |
| `eddies` | [Eddy] | Optional headland eddies. |

### Tide state and the tide clock

The **tide state** is the phase φ of the tidal cycle, in degrees in files and radians in code:
0° is slack before the flood, 90° peak flood, 180° slack before the ebb, 270° peak ebb. The cycle is
the M2 tide (the principal lunar semidiurnal constituent), whose speed is 28.9841042° per hour
([NOAA CO-OPS, harmonic constituents](https://tidesandcurrents.noaa.gov/about_harmonic_constituents.html)),
so one cycle is 360 / 28.9841042 = 12.4206012 h ≈ 44,714.164 s of tide-clock time
(`Venue.Current.tidalCycle`). During a race

    φ(t) = φ_gun + 360° × tideClockRate × t / 44,714.164 s

where t is race seconds since the gun. At 19× slack to peak takes 44,714.164 / 4 / 19 ≈ 588 s.

A steady (non-tidal) venue runs the same clock at rate 1, so its phase still advances, slowly: about
0.48° a minute, ≈ 10° over a 20-minute race. Its current is steady only approximately. Near peak
(φ ≈ 90°) that changes the strength by under 2 %; a steady venue should allow tide states near 90° or
270°, not near slack, where the same 10° is a large relative change.

### The current field (the builder's formula for #78)

With `d_max` the deepest node (derived at load), d(p) the depth at p and θ(p) the flood direction at p,
both sampled from the grid by `CurrentField` (#78):

    relative strength  s(d) = (d / d_max) ^ strengthExponent        (0 when dry, 1 at d_max)
    phase lead         δ(d) = shallowsLeadDegrees × (1 − d / d_max)   (shallows turn first)
    local phase        φ_p(t) = φ(t) + δ(d(p))
    channel current    c(p, t) = peakKnots × s(d(p)) × sin(φ_p(t)) × heading(θ(p))
    current            current(p, t) = c(p, t) + Σ eddies e(p, t)

`strengthExponent` is authored per venue; 2/3 is recommended (Manning's law: for the same surface slope,
speed ∝ depth^(2/3); see `docs/research/wind-and-current-physics-for-realtime-sim.md` §5), normalised so
the deepest water reaches `peakKnots`. The channel current only reverses, never rotates: θ is fixed per
node and the sine changes its sign. `Venue.Current.relativeStrength(depth:)` and `phaseLead(depth:)`
implement s and δ.

**Eddies.** Each eddy has a flood centre and an ebb centre, and each centre follows the local phase at
that centre (so a headland eddy turns with the shallows around it, not with the channel):

    flood strength  a_f(t) = eddy peakKnots × max(0,  sin(φ_{c_f}(t)))    at the flood centre c_f
    ebb strength    a_e(t) = eddy peakKnots × max(0, −sin(φ_{c_e}(t)))    at the ebb centre c_e
    e(p, t) = a_f(t) × f(|p − c_f|) × tangent_f(p) + a_e(t) × f(|p − c_e|) × tangent_e(p)

where φ_c is the local phase at a centre (with the shallows lead at the depth there), `tangent` is the
unit vector at right angles to p − c in the centre's rotation (`floodRotation` at the flood centre,
the other way at the ebb centre; clockwise is `(p − c).rightPerp`, normalised), and f is the radial
profile, `Venue.Eddy.relativeSpeed(atDistance:)`:

    f(r) = r / r_core                                               r ≤ r_core   (solid body)
    f(r) = (r_core / r) × (r_outer − r) / (r_outer − r_core)        r_core < r < r_outer   (Rankine, tapered)
    f(r) = 0                                                        r ≥ r_outer

f is continuous (1 at the core radius, 0 at the outer radius), and each centre's strength passes
through zero at its local slack, so the eddy never jumps in space or time. Each centre is active only
while the tide runs its way; when the two centres' depths differ, both can be weak but active for a
moment around slack. Nothing bounds the sum: channel current plus an eddy can exceed `peakKnots`.

### Eddy

A headland eddy is a Rankine vortex on the down-current side of a headland. It follows the tide and
flips to the other side, turning the other way, when the tide turns.

| Field | Type | Meaning |
|---|---|---|
| `floodCentreMetres`, `ebbCentreMetres` | [x, y] | Centre while the tide floods, and while it ebbs. |
| `coreRadiusMetres` | number | Solid-body rotation inside, > 0. |
| `outerRadiusMetres` | number | No effect from here out; > core radius. |
| `peakKnots` | number | Speed at the core radius at peak tide, > 0 and at most the venue's `peakKnots`. |
| `floodRotation` | `"clockwise"` or `"anticlockwise"` | Sense while flooding; the ebb eddy turns the other way. |

## Validation

The loader throws `DataFileError.malformed` for a missing field, a wrong type, an unknown enum value
(such as a `trendDirection`), or **a field the schema doesn't have** (a typo such as `"eddys"`, or a
`null`): a released file can't be fixed, so it mustn't carry a field nothing reads. Three things are
refused first, before anything parses the file, for every kind of data file, so every parser on every
platform reads the same document: a file that isn't **UTF-8** (files are UTF-8 only; UTF-16 and UTF-32
are refused, as is any 0x00 byte), nesting deeper than 512 (JSONDecoder's limit), and a **key repeated
in one object** (parsers disagree on which copy wins: JSONDecoder the first, JSONSerialization the
first on Darwin and the last on Linux). (Boat class files
don't check this yet.) It throws `invalidContent` for a venue that breaks any of these:

- `displayName` is non-empty; every landmark `asset` is non-empty; every point is two finite numbers.
- Every land ring is **closed** (last point repeats the first, at least 3 corners) and **simple**: no
  repeated corner, no edge crossing or touching another except where neighbours meet, no edge doubling
  back along its neighbour, and some area.
- At least one pairing; one pairing per conditions id; each `conditionsRef` has a valid id and a version
  of at least 1; each start line centre is on water.
- Bearings are in [0, 360); grid `cellSizeMetres` > 0; grids have at least 2 × 2 nodes.
- **Grid dimensions are consistent**: every value array has exactly `rows` rows of `columns` finite numbers.
- Geographic `directionDeltaDegrees` in (-180, 180) and `speedFactor` > 0.
- The current rules in the tables above.

Land clear of the start line, marks and race area, and the estuary's channel inside it, are offline
checks over the derived course (#83), not load-time validation.
