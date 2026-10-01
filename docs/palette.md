<!-- machine-generated: for agents, not human readers -->
# Palette

Sources: #22 (art direction), #29 (safe palette), G7 (#37), #53 (values). Consumers: #108, #111, #115, #116, #118, #119, #169.

## Layers

| Layer | Scope | Hue-validated (#111) |
|---|---|---|
| `CuePalette` | race scene + HUD cues; defines the reserved hues | reference set |
| `ChartPalette` | water, puff, lull, land, shallows, foam, shallowsTint, landShade, landLit, landmark, boundary, markEdge | yes |
| Safe palette | livery swatches (#118) | yes + water contrast |
| `ChromePalette` | menus, sheets, results, lobby | no (G7) |

- Menu depictions of on-water elements (Help, livery renders, course preview) use `CuePalette` / `ChartPalette`, not `ChromePalette` (G7).
- Race scene: one fixed daylight look, no dark mode (#22).

## Validator config (#111, #118)

- colour space: OKLCH / OKLab
- reserved hues: vermillion, orange, yellow, chevron blue (`CuePalette` below)
- hue rule: every validated token ≥ 20° OKLCH hue from each reserved hue (tuning: 20°)
- chroma floor: tokens with OKLCH C < 0.06 are exempt from the hue rule (hue undefined at low chroma: white, charcoal, greys, off-white, land, shallows, foam)
- swatch contrast: |ΔL| ≥ 0.20 (OKLCH L) against water, puff and lull, for every swatch except `charcoal`
- `charcoal` exception: fails contrast (min |ΔL| 0.05); readable via the hull outline (#29). Accepted in #53.
- sky blue vs chevron blue (#29, #118): OKLab ΔE 0.26 measured; threshold 0.15 (tuning)
- ripple texture (#116): |ΔL| from water < 0.12 and below the faintest puff/lull at its peak in every conditions file (`WaterTests`); ripple streaks are `lull` at `WaterStyle.rippleAlpha` (ΔL ≈ +0.05); puffs and lulls draw `puff`/`lull` at an alpha of their intensity over `WaterStyle.fullTonePuffGain`/`fullToneLullLoss`; the pressure (#289) draws the same tokens at an alpha of its difference from the course average over `WaterStyle.fullTonePressureGain`/`fullTonePressureLoss`, and the ripple stays below the weakest pressure lane at its peak in every file with a pressure field
- code (#111): `HueRule` (reserved set, tunings; `Regatta/Game/HueRule.swift`); validated set `PaletteValidation.raceSceneAndHUD` = `ChartPalette` + interim `Palette.boats`; test `PaletteTests`

## CuePalette

| Token | Hex | OKLCH L / C / h | Use |
|---|---|---|---|
| `vermillion` | `#D55E00` | 0.62 / 0.170 / 48 | wind vane |
| `orange` | `#E69F00` | 0.75 / 0.158 / 77 | active leg: current marks, zone, rounding arrow, next-mark edge arrow, rule-call line, penalty arc |
| `chevronBlue` | `#3F51E0` | 0.51 / 0.216 / 271 | none now (the give-way chevron is gone); stays reserved |
| `yellow` | `#F0E442` | 0.90 / 0.172 / 105 | laylines; HUD start clock (#111) |
| `giveWayRed` | `#FF4D4D` | 0.67 / 0.215 / 25 | right-of-way glow round a boat you must keep clear of; not reserved |
| `hasRightGreen` | `#3DDC84` | 0.79 / 0.180 / 154 | right-of-way glow round a boat that must keep clear of you; not reserved |
| `inactiveGrey` | `#9AA0A6` | 0.70 / 0.011 / — | inactive marks |
| `cueWhite` | `#FFFFFF` | 1.00 / 0 / — | player glow, wakes, ladder lines (#122); alpha set at use site |
| `hullOutline` | `#F5F5F2` | 0.97 / 0.004 / — | every hull's thin outline, 1 pt inside the edge (#117, #21); #169 restyles |

Cue-to-cue hue separation: vermillion–orange 29°, orange–yellow 28°, chevron–water 29°, chevron–puff 25°.

- The right-of-way glow is the one red/green cue. It has no shape of its own, so under deuteranopia and protanopia the two glows differ by lightness only (green 0.79, red 0.67); neither is in the hue rule's reserved set, so boat colours may match them.
- `orange` reads amber: truer oranges (`#F28C28` 11°, `#FF9500` 15° from vermillion) fail the hue rule.
- `chevronBlue` vs water contrast ≈ 1.5:1: legible by hue + shape, not lightness. Outline is a #123 builder choice.
- Colour-vision filters (deuteranopia, protanopia, tritanopia, greyscale, sunlight washout): run in the #111 harness; orange vs yellow is the pair to watch.

## ChartPalette

| Token | Hex | OKLCH L / C / h | Note |
|---|---|---|---|
| `water` | `#174D70` | 0.40 / 0.081 / 242 | one base for every venue |
| `puff` | `#002D4D` | 0.29 / 0.074 / 246 | water ΔL −0.12 (delta is the spec; hex is derived, gamut-clipped) |
| `lull` | `#3C6F94` | 0.52 / 0.080 / 242 | water ΔL +0.12 |
| `land` | `#9DB08E` | 0.73 / 0.052 / 131 | sage; tan rejected (13–15° from orange/yellow) |
| `shallows` | `#CDC8B4` | 0.83 / 0.028 / 95 | low-chroma sand; exempt via chroma floor |
| `foam` | `#E3EEF2` | 0.94 / 0.013 / 221 | whitecaps (#116), drawn part-transparent; exempt via chroma floor |
| `shallowsTint` | `#574628` | 0.404 / 0.051 / 81 | race-scene shallows (#11, #115): tan at the water's lightness (ΔL +0.001), blended over the water in OKLab by depth; exempt via chroma floor |
| `landShade` | `#889979` | 0.661 / 0.050 / 131 | land relief, coasts facing away from the light (#115) |
| `landLit` | `#AFC2A0` | 0.790 / 0.051 / 131 | land relief, coasts facing the light (#115) |
| `landmark` | `#606F53` | 0.521 / 0.046 / 131 | landmark silhouettes (#22, #115) |
| `boundary` | `#B6C7D3` | 0.820 / 0.025 / 238 | race-area boundary line and hatched band (#15, #115) |
| `markEdge` | `#2B3238` | 0.313 / 0.014 / 244 | dark hairline round buoys and the committee boat (#115) |

- puff/lull delta: ±0.12 (tuning). At the prototype's 0.17, sky blue fails swatch contrast against lull.
- Relief shading (Fellmere hills): drawn in code on `land` (#115); no asset. Bands in from each coast (not along shared inland edges) in `landLit`/`landShade` by the coast's facing to a north-west light, from polygon shape alone.
- Shallows (#115): `shallows` (sand) stays for menu depictions; the race scene draws `shallowsTint`, which keeps the water's lightness (|ΔL| ≤ 0.02 at every depth, `ShallowsTintTests`). Under tritanopia and deuteranopia it stays ~0.12 OKLab ΔE from the water; greyscale can't tell them apart, by spec (#11: hue only).

## Safe palette (livery swatches, #118)

| Id | Hex | Slots | OKLCH L | Nearest reserved hue | min \|ΔL\| vs water/puff/lull |
|---|---|---|---|---|---|
| `white` | `#F5F5F2` | deck, accent, sail | 0.97 | exempt | 0.45 |
| `charcoal` | `#33383D` | deck, accent, sail | 0.34 | exempt | 0.05 (exception) |
| `sky-blue` | `#56B4E9` | deck, accent, sail | 0.73 | chevron 35° | 0.21 |
| `pale-sky-blue` | `#9ED8F2` | deck, accent, sail | 0.85 | chevron 43° | 0.33 |
| `pale-bluish-green` | `#5FD3A8` | deck, accent, sail | 0.79 | yellow 61° | 0.27 |
| `pale-reddish-purple` | `#E6A8CB` | deck, accent, sail | 0.80 | vermillion 63° | 0.28 |
| `lavender` | `#C3B5F0` | deck, accent, sail | 0.81 | chevron 24° | 0.28 |
| `pale-grey` | `#C8CCD0` | deck, accent, sail | 0.84 | exempt | 0.32 |
| `off-white` | `#EDE6D6` | sail only | 0.93 | exempt | 0.40 |

- 8 deck swatches + 1 sail-only (#21 "about 10").
- Rejected: `bluish-green` `#009E73` (min |ΔL| 0.10), `reddish-purple` `#CC79A7` (0.16), all dark variants (≤ 0.08). Mid and dark tones collide with puff/lull; puff is near black, so no dark swatch can pass.
- Buoyancy aid colour (#22): `accent` slot; 2-slot designs use `sail`.

## ChromePalette (menus, G7)

| Token | Light | Dark | Contrast |
|---|---|---|---|
| `background` | `#DCEBF5` (pale chart blue) | `#0B1F33` (navy) | — |
| `text` | `#0E2A47` | `#E8F1F8` | 12.0:1 / 14.6:1 |
| `tint` (buttons, controls, `AccentColor`) | `#1B4F82` | `#7FB3E0` | on background 6.9:1 / 7.5:1; white on light tint 8.4:1 |
| `flagRed` (decorative accent only) | `#C8102E` | `#C8102E` | 4.8:1 on light background |
| `flagYellow` (decorative accent only) | `#FFC72C` | `#FFC72C` | 10.7:1 on dark background |

- Flag accents: headers, burgee motif, icon. Not buttons (red reads destructive on iOS).
- `AccentColor.colorset` = `tint` light/dark.

## Typography (#108)

| Role | Face | Weight |
|---|---|---|
| menu headings | Barlow Semi Condensed | SemiBold |
| menu numbers | Barlow Semi Condensed | Bold, tabular figures (`.monospacedDigit()`; font has `tnum`) |
| HUD numbers (clock, place, wind) | Barlow Semi Condensed | Bold, tabular figures (`HUDFont.number`) |
| body | SF (system) | — |

- Dynamic Type: `Font.custom(_:size:relativeTo:)`.
- HUD: the clock, place and wind numbers are in the display face (#114, `HUDFont`); a notice's words are SF body.
- Files + licence: `docs/assets-manifest.md`.

## Prototype token mapping (#111, #169)

| `Palette.swift` | Replaced by |
|---|---|
| `water` | `ChartPalette.water` |
| `gust` | `ChartPalette.puff` |
| `mark` (`#FF7A1A`, vermillion hue) | `CuePalette.orange` on water; `ChromePalette.tint` in menus |
| `startLine` | `CuePalette.orange` on water (the pin, and the line before the gun: its ends are marks, #15); the HUD clock stays `CuePalette.yellow` |
| `boats` | removed (#119 liveries) |
