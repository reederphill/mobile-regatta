<!-- machine-generated: for agents, not human readers -->
# Palette

Sources: #22 (art direction), #29 (safe palette), G7 (#37), #53 (values). Consumers: #108, #111, #115, #116, #118, #119, #169.

## Layers

| Layer | Scope | Hue-validated (#111) |
|---|---|---|
| `CuePalette` | race scene + HUD cues; defines the reserved hues | reference set |
| `ChartPalette` | water, puff, lull, land, shallows | yes |
| Safe palette | livery swatches (#118) | yes + water contrast |
| `ChromePalette` | menus, sheets, results, lobby | no (G7) |

- Menu depictions of on-water elements (Help, livery renders, course preview) use `CuePalette` / `ChartPalette`, not `ChromePalette` (G7).
- Race scene: one fixed daylight look, no dark mode (#22).

## Validator config (#111, #118)

- colour space: OKLCH / OKLab
- reserved hues: vermillion, orange, yellow, chevron blue (`CuePalette` below)
- hue rule: every validated token ≥ 20° OKLCH hue from each reserved hue (tuning: 20°)
- chroma floor: tokens with OKLCH C < 0.06 are exempt from the hue rule (hue undefined at low chroma: white, charcoal, greys, off-white, land, shallows)
- swatch contrast: |ΔL| ≥ 0.20 (OKLCH L) against water, puff and lull, for every swatch except `charcoal`
- `charcoal` exception: fails contrast (min |ΔL| 0.05); readable via the hull outline (#29). Accepted in #53.
- sky blue vs chevron blue (#29, #118): OKLab ΔE 0.26 measured; threshold 0.15 (tuning)
- ripple texture (#116): |ΔL| from water < 0.12 (must stay fainter than puff/lull)

## CuePalette

| Token | Hex | OKLCH L / C / h | Use |
|---|---|---|---|
| `vermillion` | `#D55E00` | 0.62 / 0.170 / 48 | wind vane |
| `orange` | `#E69F00` | 0.75 / 0.158 / 77 | active leg: current marks, zone, rounding arrow, next-mark edge arrow, rule-call line, penalty arc |
| `chevronBlue` | `#3F51E0` | 0.51 / 0.216 / 271 | give-way chevron |
| `yellow` | `#F0E442` | 0.90 / 0.172 / 105 | laylines; HUD start clock (#111) |
| `inactiveGrey` | `#9AA0A6` | 0.70 / 0.011 / — | inactive marks |
| `cueWhite` | `#FFFFFF` | 1.00 / 0 / — | player glow, wakes; alpha set at use site |

Cue-to-cue hue separation: vermillion–orange 29°, orange–yellow 28°, chevron–water 29°, chevron–puff 25°.

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

- puff/lull delta: ±0.12 (tuning). At the prototype's 0.17, sky blue fails swatch contrast against lull.
- Relief shading (Fellmere hills): drawn in code on `land` (#115); no asset.

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
| body | SF (system) | — |

- Dynamic Type: `Font.custom(_:size:relativeTo:)`.
- HUD: unchanged (SF Rounded); #22 scopes the display face to menus.
- Files + licence: `docs/assets-manifest.md`.

## Prototype token mapping (#111, #169)

| `Palette.swift` | Replaced by |
|---|---|
| `water` | `ChartPalette.water` |
| `gust` | `ChartPalette.puff` |
| `mark` (`#FF7A1A`, vermillion hue) | `CuePalette.orange` on water; `ChromePalette.tint` in menus |
| `startLine` | `CuePalette.yellow` |
| `boats` | removed (#119 liveries) |
