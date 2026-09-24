<!-- machine-generated: for agents, not human readers -->
# Assets manifest

Sources: #21 (liveries), #22 (art direction, audio), #36 (venues, icon), #53. Delivery: #54. Integration: #169. Colours: `docs/palette.md`.

## Conventions

- names: kebab-case, unique across the manifest; livery design ids `<boatClassId>.<slug>`
- images: `Regatta/Assets.xcassets/<name>` (vector: SVG, Preserve Vector Data)
- audio: `Regatta/Audio/<name>.<ext>`
- fonts: `Regatta/Fonts/<file>`, listed in `UIAppFonts`
- licences: `ThirdParty/<Name>/LICENSE*` + optional `VERSION`; `scripts/generate-acknowledgements.swift` builds `Regatta/Acknowledgements.plist` from them (#107). #54's `docs/licences.md` predates this convention.

## Typeface (#108)

| Name | File | Licence |
|---|---|---|
| `barlow-semi-condensed-semibold` | `BarlowSemiCondensed-SemiBold.ttf` | OFL-1.1 |
| `barlow-semi-condensed-bold` | `BarlowSemiCondensed-Bold.ttf` | OFL-1.1 |

- source: `google/fonts` `ofl/barlowsemicondensed`, version 1.408
- licence files: `ThirdParty/Barlow Semi Condensed/LICENSE` (upstream `OFL.txt`), `ThirdParty/Barlow Semi Condensed/VERSION` = `1.408`
- copyright: "Copyright 2017 The Barlow Project Authors (https://github.com/jpt/barlow)"
- OFL-1.1: embedding and redistribution in an app permitted; licence text must accompany the font (met by Acknowledgements); no sale of the font by itself
- verified: `tnum` feature present

## Livery designs (#118, #119)

- boat class: `ilca` (v1.0 has one class); must equal the class file's id
- format: vector spec per design (pattern + sail graphic, SVG) rendered in code (#22, #54)
- slots: 2 = deck, sail; 3 = deck, accent, sail
- product ids: #55 (`docs/prerequisites.md`); App Store product ids can't be reused, so ids below are final once #55 creates products
- earned thresholds: completed online races (G6), tuning placeholders (#118)

| Id | Acquisition | Price | Slots |
|---|---|---|---|
| `ilca.plain` | free | — | 2 |
| `ilca.bow-stripe` | free | — | 2 |
| `ilca.split` | free | — | 2 |
| `ilca.sail-band` | free | — | 2 |
| `ilca.hoops` | earned: 10 races | — | 3 |
| `ilca.pinstripe` | earned: 50 races | — | 3 |
| `ilca.sash` | earned: 200 races | — | 3 |
| `ilca.twin-stripe` | paid | $0.99 | 3 |
| `ilca.diagonal` | paid | $0.99 | 3 |
| `ilca.stern-band` | paid | $0.99 | 3 |
| `ilca.bar-sail` | paid | $0.99 | 3 |
| `ilca.checker` | paid | $1.99 | 3 |
| `ilca.scallop` | paid | $1.99 | 3 |
| `ilca.dash` | paid | $1.99 | 3 |
| `ilca.starburst` | paid | $1.99 | 3 |
| `ilca.harlequin` | paid | $2.99 | 3 |
| `ilca.lightning` | paid | $2.99 | 3 |
| `ilca.fade` | paid | $2.99 | 3 |
| `ilca.tartan` | paid | $2.99 | 3 |

- totals: 4 free, 3 earned, 12 paid (4 per price)
- price tracks how much the design shows (#21)

## Landmark silhouettes (#83, #115)

| Name | Venue file | Format |
|---|---|---|
| `landmark-hollin-bay-clubhouse` | `hollin-bay@1.json` | SVG |
| `landmark-hollin-bay-lighthouse` | `hollin-bay@1.json` | SVG |
| `landmark-hollin-bay-tree-clump` | `hollin-bay@1.json` | SVG |
| `landmark-saltings-reach-sea-wall` | `saltings-reach@1.json` | SVG |
| `landmark-saltings-reach-boathouse` | `saltings-reach@1.json` | SVG |
| `texture-saltings-reach-reed-bed-edge` | `saltings-reach@1.json` | SVG tile |
| `landmark-fellmere-boathouse` | `fellmere@1.json` | SVG |
| `landmark-fellmere-pine-stand` | `fellmere@1.json` | SVG |
| `landmark-fellmere-church-spire` | `fellmere@1.json` | SVG |

- land fills + relief shading: code, from venue land polygons (#72, #115); Fellmere hills are relief, not an asset
- colours: `ChartPalette.land` family; no reserved hue
- no on-water objects (channel posts, buoys): read as marks

## Audio (#126)

| Name | File | Format | Source | Plays |
|---|---|---|---|---|
| `horn` | `horn.caf` | LPCM 16-bit 44.1 kHz mono | licensed | 60 s, 30 s, OCS (repeated), finish; patterns in code |
| `gun` | `gun.caf` | LPCM 16-bit 44.1 kHz mono | licensed | start |
| `beep` | `beep.caf` | LPCM 16-bit 44.1 kHz mono | synthesised | 5-4-3-2-1 (one asset, played 5×) |
| `whistle` | `whistle.caf` | LPCM 16-bit 44.1 kHz mono | recorded | rule call involving you |
| `bell` | `bell.caf` | LPCM 16-bit 44.1 kHz mono | licensed or synthesised | mark rounding |
| `wind-light` | `wind-light.caf` | LPCM 16-bit 44.1 kHz mono, seamless loop ≥ 30 s | licensed or recorded | ambience, crossfaded by wind at the boat |
| `wind-medium` | `wind-medium.caf` | as above | licensed or recorded | as above |
| `wind-strong` | `wind-strong.caf` | as above | licensed or recorded | as above |
| `water-slow` | `water-slow.caf` | as above | licensed or recorded | ambience, crossfaded by boat speed |
| `water-fast` | `water-fast.caf` | as above | licensed or recorded | as above |
| `sail-flog` | `sail-flog.caf` | LPCM 16-bit 44.1 kHz mono, seamless loop ≥ 10 s | recorded (dinghy sail, not yacht) | while easing |
| `menu-music` | `menu-music.m4a` | AAC 160 kbps stereo | licensed (game distribution rights) | menus + lobby; fades at briefing |

- loops are LPCM, not AAC: AAC encoder padding leaves a gap at the loop point
- licence exclusions: CC-BY-NC, BBC Sound Effects (RemArc, non-commercial)
- size estimate: 5 × 30 s loops ≈ 13 MB, flog ≈ 1 MB, one-shots < 1 MB, 3 min music ≈ 3.6 MB; total ≈ 18 MB (#54 budget: download < 150 MB)

## App icon (#36)

| Name | File | Format |
|---|---|---|
| `AppIcon` | `AppIcon.appiconset` | 1024 × 1024 PNG, single size; SVG master kept alongside in #54 delivery |

- brief: top-down dinghy on chart blue with an orange mark; readable at small sizes and under colour-blind filters (#36)
- slot exists, empty: `Regatta/Assets.xcassets/AppIcon.appiconset`

## Colour sets (#108)

| Name | Value |
|---|---|
| `AccentColor` | `ChromePalette.tint` light `#1B4F82` / dark `#7FB3E0` |
