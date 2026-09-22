---
id: 4
title: Wind and current visualisation conventions
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

How do broadcast graphics (SailGP, America's Cup LiveLine), tactical sailing apps (Expedition, SailRacer, Windy, PredictWind) and games show wind direction, strength, shifts, puffs, wind shadow, laylines, and tidal current? Which representations are legible at phone size and at a glance mid-race? Collect examples (links/screenshots) for the information-design prototype.

## Context

Findings: branch `research/wind-and-current-visual-conventions`, file `docs/research/wind-and-current-visual-conventions.md`.

## Resolution

Resolved by research; full findings with example URLs on branch `research/wind-and-current-visual-conventions` in `docs/research/wind-and-current-visual-conventions.md`. Sources that blocked access are marked secondary in the file.

- **Broadcast (America's Cup, SailGP):**
  - Wind direction is one compass arrow in the corner; the water carries geometry (yellow laylines, mark zones, boundaries, ladder lines).
  - The 2024 America's Cup wind graphic coloured the water only where wind was stronger or weaker than average, with arrows on top.
- **Tactical apps:**
  - SailRacer: a shift bar, with laylines dashed when adjusted for current.
  - Vakaros: lift or header in degrees, plus a row of LEDs.
  - Expedition: laylines curved for tide, wind speed in greyscale.
  - B&G: tide as a blue arrow with a number.
  - Windy / PredictWind: colour fields with streaks or arrows.
  - OpenCPN / tidal atlases: arrows longer and thicker as the rate increases.
- **Games:** darker water means more wind. Wind-shadow cones and laylines are drawn on the water.
- **What reads at a glance on a phone:**
  - Readable: one HUD arrow, puffs shaded against the average, a bold shift glyph, bold laylines, a visible shadow cone, current arrows sized by rate.
  - Not readable: wind barbs, rainbow scales, shift-history charts.
- **Colour-blind safety:**
  - Unsafe: red/green laylines or shift bars, rainbow scales, colour-only current gradients, and the prototype's orange-only "dirty air" warning.
  - Safe: lightness, size, line style, hatching and position.

**Recommended candidates:**

| Quantity | Candidate |
|---|---|
| Wind direction | HUD arrow plus the faint streaks on the water |
| Wind strength | Knots number in the HUD |
| Puffs and lulls | Water lighter or darker than the course average, plus ripple texture |
| Shifts | Needle with ▲ lift / ▼ header and signed degrees |
| Wind shadow | Stronger hatched cone plus a haptic |
| Laylines | Bold single colour, dashed when adjusted for current |
| Boundaries | Line plus a hatched out-of-bounds band |
| Current | Sparse chunky arrows sized by rate, plus a HUD arrow with knots |

- Wind and current must not both use water colour.
- The prototype's shadow cone and laylines are too faint and need strengthening.
