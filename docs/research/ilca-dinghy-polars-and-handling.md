---
question: What published ILCA/Laser polars and handling numbers (VMG targets, saturation and planing thresholds, by-the-lee, tack and gybe loss, coasting, acceleration, leeway) exist to seed the v1.0 single-handed dinghy's polar at 6 to 20 kn?
date: 2026-09-22
---

# ILCA/Laser polars and handling numbers

Research to seed the polar and handling model for the v1.0 boat class, a fictional single-handed 4.2 m dinghy modelled on the ILCA/Laser (no spinnaker). Terms follow [`CONTEXT.md`](../../CONTEXT.md): polar, VMG, tack, sailing by the lee. TWS is true wind speed and TWA is true wind angle. Speeds are in knots unless marked.

## TL;DR

- **No full published ILCA 7 polar exists.** Nobody publishes a TWA × TWS grid over 6 to 20 kn. There are five partial datasets:
  - a validated flat-water VPP covering 5 to 16 kn, upwind and dead downwind only ([Day 2017](https://strathprints.strath.ac.uk/59980/1/Day_OE_2017_Performance_prediction_for_sailing_dinghies.pdf));
  - one measured full polar at 12 kn and partial curves at 9 kn (Binns et al. 2002, digitised from Day's figures);
  - Bethwaite's measured points at 6, 9 and 12 kn;
  - an unattributed hand-drawn polar covering 8.5 to 30 kn;
  - race GPS VMG averages in three wind bands.

  Binns et al. 2002 and Bethwaite are the same dataset: Bethwaite is a co-author, and the 12 kn numbers match to 0.1 kn.
- **Upwind VMG saturates at about 11 to 12 kn TWS.** The VPP gives VMG of 3.63 at 10 kn, 3.73 at 12 kn and 3.81 at 16 kn. The best upwind TWA is about 40° at 9 to 10 kn, widening to 44° in both light and heavy air. Measured ILCA 6 upwind speed also plateaus above about 12 to 14 kn.
- **Downwind, the VPP is too slow.** It runs 1.4 to 1.5 kn below measured speed. Race GPS downwind VMG (4.7 at 8 to 12 kn) is higher than the VPP's boat speed at 10 kn, so the seed polar uses measured data off the wind.
- **Planing starts at about 12 kn TWS.**
  - Race VMG between the 8 to 12 kn and >12 kn bands rises by +66% downwind (4.7 to 7.8) and +57% on reaches (5.8 to 9.1), against only +16% upwind.
  - Reaching speed goes from about 8 kn at 12 kn TWS to about 12 kn at 19 kn TWS.
- **By the lee:** coaching says heading 5 to 40° past dead downwind, more in light air. The only primary aerodynamic test (ILCA 7 MkII wind tunnel) finds drive at 10° by the lee is lower than at 10° above dead downwind, so no speed gain is supported. Model it as a mirrored polar with a small penalty.
- **Tacks:**
  - An ILCA 7 in ~18 kn turns through 69 to 91° and regains 80% of entry speed 6.5 to 8.7 s after starting the tack.
  - A Laser Radial's minimum speed in a tack is about 45 to 50% of entry speed.
  - The typical cost is about one boat length per tack, less in flat light air with a roll tack.
  - No measured Laser gybe loss was found.
- **Coasting head to wind:** about half a boat length (Sailing World rule of thumb). **Leeway:** 3 to 5°, generic, not Laser-specific.

---

## 1. Datasets found

| # | Dataset | Kind | Coverage | Trust | Notes |
|---|---|---|---|---|---|
| D1 | Day (2017) Laser VPP | Modelled | TWS 5–16 kn; best upwind and downwind VMG and angle; BSP vs TWA at 40–60° and 150–180° for 9–14 kn | **High** (peer-reviewed, validated upwind) | Flat water, 80 kg sailor. Can't model surfing or by the lee. [Strathprints PDF](https://strathprints.strath.ac.uk/59980/1/Day_OE_2017_Performance_prediction_for_sailing_dinghies.pdf), DOI 10.1016/j.oceaneng.2017.02.025 |
| D2 | Binns, Bethwaite & Saunders (2002), measured | Measured (method not given in Day) | Full polar at 12 kn; 42–60° and 150–180° at 9 kn | **Medium-high** | Only available as figures in Day (2017). Day says it was likely gathered in surfing conditions. |
| D3 | Bethwaite, *Dynamic Advances in the 90's* booklet | Measured (same source as D2) | 6, 9, 12 kn at four points of sail | **Medium** (second-hand) | Points quoted by David Gardiner on [SailingForums](https://sailingforums.com/threads/laser-speeds.175/). The original graph link (notmd.com) is dead. Search excerpt of the forum. |
| D4 | Hand-drawn "Standard Laser" polar | Unknown | Beaufort F3–F7 (8.5, 13.5, 19, 25, 30 kn), 30–180° | **Low** (no provenance) | [Image via Metaverse Sailing](https://metaversesailing.wordpress.com/wp-content/uploads/2013/02/laserpolar-via-btinternet-and-laser-one.png), originally on a btinternet page. The only source above 16 kn. |
| D5 | Pan & Sun (2022), Heliyon | Measured (race GPS, SAP Sailing) | VMG per leg type in <8, 8–12, >12 kn bands; manoeuvre counts | **High** for VMG; not a polar | 63 World Cup and Olympic races. [PMC9719898](https://pmc.ncbi.nlm.nih.gov/articles/PMC9719898/) |
| D6 | Caraballo et al. (2021), Appl. Sci. | Measured (race GNSS) | VMG per leg type, 3.5–8.3 kn | **Medium** (table garbled in extraction) | [doi:10.3390/app11010264](https://doi.org/10.3390/app11010264) |
| D7 | setcourses.com race-officer table | Rule of thumb | Leg speeds for Laser Full and Radial in 4 wind bands | **Low-medium** | [PDF](https://www.setcourses.com/Dinghy-Speed-Leg-Length.pdf) |
| D8 | Sports Performance Research 18 (2026), ILCA 6 upwind | Measured (15 Hz GPS, motorboat wind) | ILCA 6 upwind BSP, VMG and TWA at 2–9 m/s | **Medium-high** (2 sailors) | [J-STAGE rjsp 18_2369](https://www.jstage.jst.go.jp/article/rjsp/18/0/18_2369/_article/-char/en) |

Rejected or not usable:

- Clark (2014) raw data is about half the other datasets' speeds (Day Fig 3).
- The Binns (2002) VPP and the Carrico VPP are both about 1 kn slow at 40–60° (Day Fig 4–5).
- The Laser Training Manual's Fig 11 is explicitly "a typical small planing dinghy" and not a Laser ([manual](https://www.callalajuniorsailingschool.org/Laser_manual.pdf), §6).
- Sailonline and Second Life boats have virtual polars.
- No Laser polar was found in ORC or qtVlm.

---

## 2. Per-dataset numbers

### 2.1 Day (2017) VPP: best upwind and downwind (D1)

Digitised from Day Fig 8 (VMG) and Fig 9 (TWA) by pixel colour. Accuracy is about ±0.03 kn and ±0.5°. Upwind BSP is derived as VMG / cos(TWA).

| TWS | Upwind VMG | Upwind TWA | Upwind BSP (derived) | Downwind VMG (≈ BSP) | Downwind TWA |
|---|---|---|---|---|---|
| 5 | 2.28 | 43.8° | 3.16 | 2.50 | 178° |
| 6 | 2.65 | 43.6° | 3.66 | 2.99 | 178.5° |
| 8 | 3.27 | 41.0° | 4.33 | 3.81 | 179° |
| 9.5 | — | 40.2° (minimum) | — | — | 180° |
| 10 | 3.63 | 40.6° | 4.78 | 4.55 | 179.5° |
| 12 | 3.73 | 41.7° | 5.00 | 5.19 | 179.5° |
| 14 | 3.79 | 42.9° | 5.17 | 5.91 | 179.5° |
| 16 | 3.81 | 44.2° | 5.31 | 6.73 | 180° |

Other Day findings:

- Depowering (flattening and twisting the sail) starts at about 9 kn.
- The best downwind setup is windward heel: about 20° at 5 kn, easing to about 12° at 9.3 kn, then upright from 9.4 kn (Fig 9).
- The downwind optimum is always within 2° of dead downwind, because the model has no surfing and no by-the-lee flow.

### 2.2 Measured vs VPP around 9 and 12 kn (D1, D2)

Read from Day Fig 4–7. The 12 kn off-wind row comes from Fig 3, digitised in polar coordinates (that chart has unequal x and y scales). It matches Fig 5 at 60° (6.32) and Fig 7 at 150° (7.35).

| TWA | Binns 9 kn (meas.) | VPP 9 kn | VPP 10 kn | Binns 12 kn (meas.) | VPP 12 kn | VPP 14 kn |
|---|---|---|---|---|---|---|
| 40 | — | 4.57 | 4.73 | 4.90 | 4.88 | — |
| 42 | 4.65 | — | — | 5.03 | — | — |
| 46.5 | 5.00 | 4.95 | 5.15 | 5.43 | 5.35 | — |
| 50 | 5.25 | 5.15 | 5.38 | 5.63 | 5.65 | — |
| 55 | 5.60 | 5.40 | 5.68 | 6.00 | 6.00 | — |
| 60 | 5.85 | 5.52 | 5.90 | 6.32 | 6.22 | — |
| 75 | — | — | — | 6.95 | — | — |
| 90 | — | — | — | 7.37 | — | — |
| 110 | — | — | — | 7.94 | — | — |
| 120 | — | — | — | **8.16** (peak) | — | — |
| 135 | — | — | — | 7.89 | — | — |
| 150 | 5.97 | 4.42 | 4.75 | 7.36 | 5.45 | 6.20 |
| 160 | 5.75 | 4.30 | 4.65 | 6.95 | 5.33 | 6.07 |
| 170 | 5.63 | 4.22 | 4.58 | 6.75 | 5.25 | 5.98 |
| 180 | 5.63 | 4.20 | 4.55 | 6.68 | 5.22 | 5.95 |

Upwind, the VPP and the measurements agree within about 0.1 to 0.3 kn. Downwind, the measurements are 1.4 to 1.5 kn faster. Day speculates this is partly the conditions the measured data were gathered in (waves and surfing).

### 2.3 Bethwaite points (D3; search excerpt of a forum quote)

| TWS | Close-hauled | Beam reach | Broad reach | Downwind |
|---|---|---|---|---|
| 6 | 4.0 | 5.4 | 5.0 | 4.1 |
| 9 | 4.8 | 6.3 | 6.1 | 5.5 |
| 12 | 5.0 | 7.3 | 8.0 | 6.7 |

The exact TWA for each point of sail is not stated. At 12 kn these match D2 (45°: 5.3, 90°: 7.4, 120–135°: 7.9–8.2, 180°: 6.7), which is consistent with both coming from Bethwaite's measurements.

### 2.4 Hand-drawn polar (D4; low trust)

Digitised by hue, taking the median radius per 2.5° bin. The F3 curve at 110–130° is hidden under a green overlay arrow, so that cell is interpolated.

| TWA | F3 (8.5 kn) | F4 (13.5 kn) | F5 (19 kn) | F6 (25 kn) | F7 (30 kn) |
|---|---|---|---|---|---|
| 30 | 3.1 | 3.4 | 3.5 | 3.6 | 3.9 |
| 40 | 4.3 | 4.7 | — | 5.1 | 5.4 |
| 45 | 4.7 | 5.2 | 5.6 | 5.7 | 6.1 |
| 52.5 | 5.3 | 5.7 | 6.4 | 6.7 | 7.0 |
| 60 | 5.6 | 6.2 | 6.9 | 7.7 | 8.1 |
| 75 | 6.0 | 6.8 | 8.1 | 10.5 | 11.8 |
| 90 | 6.2 | 7.3 | 10.1 | 14.5 | 17.6 |
| 110 | ~6.3 (interp.) | 7.5 | 12.0 | 15.5 | 19.5 |
| 135 | 6.1 | 7.5 | 11.7 | 15.3 | 18.8 |
| 150 | 6.2 | 7.2 | 11.1 | 13.9 | 18.6 |
| 165 | 6.0 | 7.0 | 10.6 | 13.2 | 17.8 |
| 180 | 5.8 | 7.0 | 10.4 | 13.0 | 17.8 |

The F4 curve (13.5 kn) is below D2's 12 kn measured polar on the reach (7.5 vs 7.9–8.2) and below race reach VMG above 12 kn (9.1, §2.5). It looks like a non-planing curve, so the seed polar skips it and interpolates from 12 kn measured data to F5 instead. The F7 values (19+ kn at 110°) look high for a Laser and are not used.

### 2.5 Race and rule-of-thumb VMG (D5, D6, D7)

Leg VMG includes tactics, manoeuvres and waves, so it sits below polar speed. Upwind it runs about 12% below the VPP at 10 kn.

| Source | Wind band | Upwind VMG | Downwind VMG | Reach VMG |
|---|---|---|---|---|
| Pan & Sun, all sailors | <8 kn | 2.5 | 3.3 | 4.2 |
| | 8–12 kn | 3.2 | 4.7 | 5.8 |
| | >12 kn | 3.7 | 7.8 | 9.1 |
| Pan & Sun, top 10 | <8 / 8–12 / >12 | 2.7 / 3.3 / 3.8 | 3.4 / 4.7 / 7.9 | 4.4 / 6.1 / 9.5 |
| Caraballo, Genoa 2019 | 3.5–8.3 kn | ~2.3 | ~2.9–3.2 | ~4.1–4.7 |
| setcourses, Laser Full | 5–8 / 8–12 / 12–15 / 15+ | 3.0 / 3.2 / 3.75 / 4.0 | 3.5 / 5.0 / 6.0 / 6.7 | 5.0 / 6.7 / 8.6 / 10.0 |
| setcourses, Laser Radial | same bands | 2.7 / 3.0 / 3.5 / 3.75 | 3.3 / 4.3 / 6.0 / 6.7 | 4.6 / 6.0 / 7.5 / 8.6 |

setcourses values are converted from its min/NM table (60 / minutes).

Pan & Sun also report manoeuvre counts:

- **Upwind:** ~18 per race in <8 kn, falling to ~14 above 8 kn.
- **Downwind (gybes and bear-aways):** ~28 per race in <8 kn and ~54 in both higher bands (top-10 group).

### 2.6 ILCA 6 measured upwind (D8)

The ILCA 6 has LOA 4.23 m, a 58.0 kg hull and a 5.76 m² sail. The two sailors were Athlete A (male, 80 kg, an ILCA 7 specialist) and Athlete B (female, 62 kg). Values are read by eye from Figs 5–7, about ±0.05 m/s and ±1°. m/s are converted to knots.

| TWS (kn) | 3.9 | 5.8 | 7.8 | 9.7 | 11.7 | 13.6 | 15.6 | 17.5 |
|---|---|---|---|---|---|---|---|---|
| BSP, A | 3.2 | 4.1 | 4.4 | 4.9 | 4.9 | 5.1 | 5.2 | 5.3 |
| BSP, B | 3.2 | 4.0 | 4.3 | 4.7 | 4.7 | 4.8 | 4.8 | 4.9 |
| VMG, A | 1.8 | 2.4 | 2.9 | 3.3 | 3.6 | 3.5 | 3.6 | 3.9 |
| VMG, B | 1.8 | 2.3 | 2.9 | 3.3 | 3.5 | 3.3 | 3.3 | 3.6 |
| Upwind TWA, A | 54° | 52.5° | 47.5° | 45.5° | 42° | 46.5° | 46° | 43° |
| Upwind TWA, B | 54° | 53° | 47° | 44.5° | 40.5° | 46° | 45.5° | 42.5° |

The paper's own summary: boat speed plateaus above 6 m/s (B) and 7 m/s (A). The upwind angle narrows from about 50° to 40° between 2 and 6 m/s, then widens again above 7 m/s.

Differences between ILCA 6 and ILCA 7:

- At 12 to 18 kn, the ILCA 6 with an 80 kg sailor is within about 0.1 kn of the ILCA 7 VPP's upwind BSP (5.0–5.3).
- setcourses rates the Radial about 7 to 10% slower upwind and 10 to 15% slower on reaches.

---

## 3. Disagreements side by side (about 12 kn TWS)

| Point of sail | Day VPP 12 kn | Binns/Bethwaite 12 kn | Hand-drawn F4 13.5 kn | ILCA 6 A, 11.7 kn | Race VMG 8–12 / >12 |
|---|---|---|---|---|---|
| Close-hauled BSP (~42–45°) | 5.0–5.3 | 5.0–5.3 | 5.2 | 4.9 | — |
| Upwind VMG | 3.73 | ~3.75 | ~3.6 | 3.6 | 3.2 / 3.7 |
| Beam reach (90°) | — | 7.4 | 7.3 | — | 5.8 / 9.1 (reach leg) |
| Best reach | — | 8.2 at 120° | 7.5 at 110–135° | — | — |
| Dead downwind | 5.2 | 6.7 | 7.0 | — | 4.7 / 7.8 |

Upwind, all sources agree within about 0.3 kn. Off the wind they diverge by up to 1.5 kn. The flat-water VPP is lowest, and measured data with waves is highest.

---

## 4. Derived targets

### 4.1 Upwind VMG targets

Use D1. The measured ILCA 6 angles (D8) are 2 to 5° wider above 12 kn, which reflects waves and depowering in real conditions.

| TWS | Target TWA | Target BSP | Target VMG |
|---|---|---|---|
| 6 | 44° | 3.7 | 2.65 |
| 8 | 41° | 4.3 | 3.27 |
| 10 | 41° | 4.8 | 3.63 |
| 12 | 42° | 5.0 | 3.73 |
| 14 | 43° | 5.2 | 3.79 |
| 16 | 44° | 5.3 | 3.81 |
| 20 | ~45° (extrapolated) | ~5.5 | ~3.9 (plateau; D4 and seed polar) |

### 4.2 Downwind VMG targets

Every dataset puts the best downwind VMG at or within about 15° of dead downwind:

- In the VPP it is at 178–180°.
- In D2 at 12 kn, VMG is 6.7 at 180° vs 6.6 at 165°.
- In the seed polar (§7) it is 180° from 8 kn up and 165° at 6 kn.

A Laser without a spinnaker doesn't heat up for VMG the way an asymmetric boat does.

| TWS | Seed downwind VMG (at 180°) | VPP | Race VMG band |
|---|---|---|---|
| 6 | 4.25 at 165° (4.1 at 180°) | 2.99 | 3.3 (<8) |
| 8 | 5.1 | 3.81 | 3.3 / 4.7 |
| 10 | 6.0 | 4.55 | 4.7 (8–12) |
| 12 | 6.7 | 5.19 | 4.7 / 7.8 |
| 14 | 7.8 | 5.91 | 7.8 (>12) |
| 16 | 8.8 | 6.73 | 7.8 (>12) |
| 20 | 10.8 | — | — |

### 4.3 Upwind saturation

- **VPP:** upwind VMG reaches 97% of its 16 kn value by 11 kn. It rises only 0.18 kn from 10 to 16 kn (D1).
- **Pennanen (2015) Laser CFD thesis:** the light-wind range "up to approximately eleven knots of true wind speed … correlates to the maximum boat speed. Above this wind speed the boat speed does not increase at all or very little" ([Aaltodoc](https://aaltodoc.aalto.fi/items/15f6598c-2b28-4e86-94f8-7fe7adf84f84)).
- **ILCA 6 measured:** the plateau is at 6–7 m/s (11.7–13.6 kn) (D8).
- **Recommendation:** saturate upwind BSP at **11–12 kn TWS**, then allow a slow rise of about 0.05 kn per kn of wind.

### 4.4 Planing onset and speed jump

- **Race data (D5):** from the 8–12 kn band to the >12 kn band, downwind VMG rises 4.7 to 7.8 (+66%) and reach VMG 5.8 to 9.1 (+57%). Upwind rises only 3.2 to 3.7 (+16%).
- **setcourses (D7), Laser Full reach speed:** 6.7 (8–12), 8.6 (12–15), 10.0 (15+).
- **Hand-drawn polar (D4):** best reach 7.5 at 13.5 kn, 12.0 at 19 kn and 15.5 at 25 kn.
- **Measured at 12 kn (D2):** the reach already reaches 8.2 kn, which is semi-planing. There is no step within the 12 kn curve itself.
- **Recommendation:** planing onset on a reach (90–135°) at **~12 kn TWS**, and on a run at **~13–14 kn**.
  - Reach speed rises from about 8 kn (12 kn TWS) to about 9 (14), 10 (16) and 12.5 (20).
  - Run speed rises from about 6.7 (12) to 7.8 (14), 8.8 (16) and 10.8 (20).
  - The race-data jump suggests the game can make this a visible step: +1 to 1.5 kn over about 2 kn of TWS. It doesn't need to be a smooth ramp.

---

## 5. Sailing by the lee

| Claim | Value | Source | Trust |
|---|---|---|---|
| Boom angle past square when by the lee | light air 35–40°, stronger air ~20°, heavy air ≤5° | drLaser editor on [SailingForums](https://sailingforums.com/threads/downwind-laser-sailing.58/) | Low (forum; search excerpt) |
| Heading by the lee in light air | 25–45° by the lee | Self-described top-15 light-air ILCA Worlds sailor on [Reddit](https://www.reddit.com/r/dinghysailing/comments/1npp5ql/low_wind_lesson_in_a_laser_be_awkward/) | Low (unverified; search excerpt) |
| Moderate-wind reverse flow | boom about 70–80° to the heading | [Laser Training Manual §7.2](https://www.callalajuniorsailingschool.org/Laser_manual.pdf) | Medium (coaching) |
| Speed gain | "a slight speed increase … with a heading above or below 180 degrees". But for Lasers the extra distance "is seldom compensated by the extra speed" | same | Medium |
| Wind-tunnel test, ILCA 7 MkII, AWS 4 m/s | Best sheet angle is 90° at AWA 150–190°. Peak drive at AWA 190° is **lower** than at 170°: "very little support" for negative (by-the-lee) sailing | [Magnander & Larsson 2023, J. Sailing Technology](https://doi.org/10.5957/jst/2023.8.7.118) ([full text](https://research.chalmers.se/publication/546299/file/546299_Fulltext.pdf)) | High (primary; light wind, upright, no waves) |
| Stability | By the lee is safer in a breeze, because the sail's heeling force opposes the hiking sailor | Laser Training Manual Fig 13; [Peckover, Improper Course](http://www.impropercourse.com/2014/04/sailing-in-middle-of-fleet-sailing.html) | Medium |
| Use in racing | Tactical (lateral movement to reach puffs and waves without gybing) more than raw speed | [SailZing primer](https://sailzing.com/sailing-by-the-lee-a-primer/); [ILCA, Emmett](https://ilcasailing.org/downwind-in-lasers/) | Medium |

No dataset measures Laser speed by the lee against a broad reach.

**Recommendation (judgement):**

- Mirror the polar past 180°, so speed at 180 + x equals speed at 180 − x.
- Apply a 0–3% penalty.
- Allow up to about 30° by the lee in light air and about 15° above 15 kn before a forced gybe.

This gives by the lee its tactical value without making it a speed exploit, which fits the wind-tunnel result.

---

## 6. Manoeuvres, acceleration, coasting and leeway

### 6.1 Tacks

| Quantity | Value | Conditions | Source |
|---|---|---|---|
| Heading change through a tack | 69–91° (median ~80°) | ILCA 7, one elite male, 9.2 m/s (17.9 kn) station wind | [Semb et al. 2025, Table 2](https://www.mdpi.com/2076-3417/15/15/8629) |
| Entry / exit speed | 2.1–2.7 / 1.7–2.6 m/s (4.1–5.2 / 3.3–5.1 kn) | same | same |
| Time from starting the tack to 80% of entry speed | 6.5–8.7 s (mean ~7.5 s) | same | same |
| Mean VMG over the 10 s window centred on the tack | 1.3–1.8 m/s (2.5–3.5 kn) | same | same |
| Minimum speed in a tack | ~45–50% of entry speed | Laser Radial, 13 sailors, 6 kn and 10 kn | [J-STAGE jcoaching 27](https://www.jstage.jst.go.jp/article/jcoaching/27/1/27_23/_article/-char/en), Figs 4 and 7 (read by eye) |
| Tack time (speed below 90% of entry and back above it) | ~4.3 s roll vs ~7.2 s flat (light air) | same | same, Fig 5 (read by eye) |
| Recovery to entry speed | ~10–20 s. Some flat tacks had not recovered at +20 s | same | same |
| Roll-tack advantage in mean speed through the tack | +5.3% (6 kn), +2.8% (10 kn) | same | same (abstract) |
| Roll vs flat tack | Roll gains more than one boat length | Laser, on-water data | [Schutt & Williamson, APS DFD 2015 abstract](https://absimage.aps.org/image/DFD15/MWS_DFD15-2015-001997.pdf) |
| Loss per tack, roll-tacking dinghy | "an average of maybe one length per tack". In flat light air, "zero loss of distance" | Generic dinghies | [Speed & Smarts #155](https://speedandsmarts.com/images/pdfs/currentissues/Speed__Smarts_Issue_155.pdf) |

**Derived (not measured):**

- **Semb, ~18 kn.** The steady VPP VMG at 16–18 kn is about 3.8 kn (1.95 m/s). The in-tack mean VMG is 1.3–1.8 m/s. Over the 10 s window that is a deficit of 1.5–6.5 m, or **0.4–1.5 boat lengths** (4.2 m), plus recovery after the window.
- **Turn rate.** No source reports it directly. If about 80° of heading change happens in 3–4 s, the rate is about **20–27°/s** (judgement).

**Recommendation for the seed:**

- Speed-loss curve: drop to 50% of entry speed over about 2 s, then recover to 80% by about 7 s and to 100% by 12–15 s.
- Net cost: about 1 boat length in medium air and about 0.5 in light flat water with a good roll tack.
- Heavy air: roll tacks don't apply ("when it's windy … don't roll at all", Speed & Smarts #155).

### 6.2 Gybes

No measured Laser gybe loss was found. Here is what does exist:

- Roll-gybing is described and characterised on the water with GPS and IMU, but the abstract gives no number ([Morris & Williamson, APS DFD 2019](https://absimage.aps.org/image/DFD19/MWS_DFD19-2019-002305.pdf)).
- Race data show ~28–54 downwind manoeuvres per race (D5), so a gybe must be cheap or the fleet would stop gybing.
- "Losing a quarter of a boatlength less than your opponent in each gybe" is Ed Baird's framing, quoted by [ChartedSails](https://www.chartedsails.com/blog/learn-from-sailing-data-downwind-technique). That analysis uses J/70 data, not a Laser.

**Judgement:** a gybe costs about a quarter to half a boat length in medium air. In a planing breeze, a missed gybe costs much more because the boat comes off the plane.

### 6.3 Coasting head to wind (shooting)

- "a light boat like a Laser might shoot only half a boat length" ([Sailing World, Finishing Techniques](https://www.sailingworld.com/how-to/finishing-techniques/)).
- For centreboard dinghies, "begin the shoot at one-half boatlength from the finish" ([Sailing World, Shoot to the Finish](https://www.sailingworld.com/how-to/shoot-to-the-finish/)).

Both are search excerpts. **Seed:** about 2 m of carry from close-hauled speed to near-stopped, meaning a strong deceleration once head to wind.

### 6.4 Acceleration from near-stopped (starts)

- Flow over the sail "perhaps requir[es] 3 or 4 seconds" to settle after each change of sail shape. Accelerating needs fuller sails and wider boom angles ([Laser Training Manual §4.4.4](https://www.callalajuniorsailingschool.org/Laser_manual.pdf)). The author is unconfirmed; the manual cites Anderson (1982).
- The tack data above are the best proxy. From about 50% of target speed, the boat reaches 80% in about 5 s and 90–100% in about 10–15 s (Semb; J-STAGE jcoaching).
- No standing-start (0 kn) measurement was found.
- **Seed (judgement):** time constant τ ≈ 4 s in medium air, v(t) = v_target · (1 − e^(−t/τ)). Use a longer τ (5–6 s) in light air, when the sail must be fuller, and in a breeze, when the sailor is depowering.

### 6.5 Leeway (brief)

- Pennanen's Laser CFD fixes leeway (yaw) per boat speed from tank data and foil theory. The representative validation case is 4 kn BSP, 0° heel and **5° yaw**. Leeway grows slightly with heel ([Aaltodoc](https://aaltodoc.aalto.fi/items/15f6598c-2b28-4e86-94f8-7fe7adf84f84)).
- Generic figure: "most racing boats sail upwind in medium breeze with 3-5 degrees of leeway" ([SailZing](https://sailzing.com/understand-leeway-to-improve-upwind-performance/), search excerpt).
- **Seed (judgement):** 4–5° close-hauled at low speed, 3° at full upwind speed, falling linearly to 0° at TWA 150°+.

---

## 7. Suggested seed polar (BSP in knots)

### Values

| TWA \ TWS | 6 | 8 | 10 | 12 | 14 | 16 | 20 |
|---|---|---|---|---|---|---|---|
| 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| 30 | 2.4 | 3.0 | 3.3 | 3.4 | 3.5 | 3.5 | 3.6 |
| 35 | 3.0 | 3.8 | 4.2 | 4.3 | 4.4 | 4.4 | 4.5 |
| 40 | 3.4 | 4.3 | 4.7 | 4.9 | 5.0 | 5.0 | 5.1 |
| 45 | 3.7 | 4.6 | 5.1 | 5.3 | 5.3 | 5.4 | 5.5 |
| 52 | 4.0 | 4.9 | 5.5 | 5.8 | 6.0 | 6.1 | 5.9 |
| 60 | 4.3 | 5.2 | 5.9 | 6.3 | 6.5 | 6.7 | 6.5 |
| 75 | 4.8 | 5.6 | 6.4 | 7.0 | 7.3 | 7.6 | 8.5 |
| 90 | 5.4 | 6.0 | 6.7 | 7.4 | 8.2 | 8.9 | 10.8 |
| 110 | 5.2 | 5.9 | 6.8 | 7.9 | 9.1 | 10.3 | 12.6 |
| 135 | 5.0 | 5.7 | 6.7 | 7.9 | 9.0 | 10.1 | 12.3 |
| 150 | 4.7 | 5.5 | 6.4 | 7.4 | 8.4 | 9.5 | 11.6 |
| 165 | 4.4 | 5.3 | 6.1 | 6.8 | 7.9 | 9.0 | 11.0 |
| 180 | 4.1 | 5.1 | 6.0 | 6.7 | 7.8 | 8.8 | 10.8 |

Resulting best VMG, checked by script over these rows:

- **Upwind:** 2.62 (6 kn), 3.29 (8), 3.62 (10), 3.75 (12), 3.79 (14), 3.83 (16), 3.91 (20), at 40–45°. This matches D1 within 0.05 kn.
- **Downwind:** 4.25 at 165° (6 kn), then 180° for 8 kn and up.

### Provenance

Codes:

- **V**: Day VPP (D1).
- **V~**: VPP 9 kn curve shape scaled to the VPP 8 kn optimum.
- **M**: Binns/Bethwaite measured (D2/D3).
- **b**: hand-drawn polar (D4).
- **iA→B**: linear interpolation in TWS between columns A and B.
- **t**: linear interpolation in TWA between neighbouring rows of the same source.
- **J**: judgement.

| TWA \ TWS | 6 | 8 | 10 | 12 | 14 | 16 | 20 |
|---|---|---|---|---|---|---|---|
| 0 | J | J | J | J | J | J | J |
| 30, 35 | J | J | J | J | J | J | J |
| 40 | J | V~ | V | M (= V) | V | V | b (F6) |
| 45 | V | V~ | V | M (= V) | V | V | J (VPP plateau) |
| 52 | M (+D8) | V~ | V | M | i M12→b19 | i M12→b19 | J |
| 60 | t | V~ | V | M | i M12→b19 | i M12→b19 | J |
| 75 | t | t | i M9→M12 | M | i M12→b19 | i M12→b19 | i b19→b25 |
| 90, 135, 180 | M | i M6→M9 | i M9→M12 | M | i M12→b19 | i M12→b19 | i b19→b25 |
| 110, 150, 165 | t (M) | i M6→M9 | i M9→M12 (9 kn: t) | M | i M12→b19 | i M12→b19 | i b19→b25 |

Notes on the choices:

- **Row 0 is 0 and rows 30–35 are a no-go ramp.** They are 0.70× and 0.88× the 40° value. The ratio follows the shape of the D4 curves near 30°, and it keeps the VMG optimum at 40–45°.
- **The 6 kn upwind cells are held down on purpose.** The 40° cell at 6 kn is kept below the VPP's optimum VMG. The 52° cell uses Bethwaite's close-hauled 4.0 and the ILCA 6 measurement of 4.0–4.1 at 52–53° in 5.8 kn.
- **Off-wind cells use measured data, not the VPP.** Race downwind VMG in the 8–12 kn band (4.7) is higher than the VPP's boat speed at 10 kn (4.55), and the VPP can't surf. For a calmer flat-water variant, scale the 150–180° rows at 6–12 kn toward the VPP column in §2.2 (about −25%).
- **14 and 16 kn interpolate from Binns 12 kn toward F5 (19 kn), skipping F4 (13.5 kn).** F4 sits below both the 12 kn measured reach and the race reach VMG above 12 kn. The interpolated 110° values (9.1, 10.3) match race reach VMG (9.1–9.5) and setcourses (8.6–10.0).
- **The 20 kn 52° and 60° cells are reduced from D4's values** (6.45 and 7.0, judgement). Otherwise the upwind optimum would move to 52°, contradicting both the VPP and D8 (43–46°).
- **For TWA over 180° (by the lee),** mirror the polar with a 0–3% penalty (§5).

---

## Sources

Primary and peer-reviewed:

- [Day 2017, Performance prediction for sailing dinghies (Ocean Eng.)](https://strathprints.strath.ac.uk/59980/1/Day_OE_2017_Performance_prediction_for_sailing_dinghies.pdf)
- [Pan & Sun 2022, Heliyon (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9719898/)
- [Caraballo et al. 2021, Appl. Sci.](https://doi.org/10.3390/app11010264)
- [Semb et al. 2025, Appl. Sci. 15:8629](https://www.mdpi.com/2076-3417/15/15/8629)
- [ILCA 6 upwind wind-speed/velocity curves, Sports Performance Research 18 (2026)](https://www.jstage.jst.go.jp/article/rjsp/18/0/18_2369/_article/-char/en)
- [GPS tacking evaluation, Laser Radial, Japan J. Coaching 27](https://www.jstage.jst.go.jp/article/jcoaching/27/1/27_23/_article/-char/en)
- [Magnander & Larsson 2023, J. Sailing Technology](https://doi.org/10.5957/jst/2023.8.7.118)
- [Pennanen 2015, Aalto MSc thesis](https://aaltodoc.aalto.fi/items/15f6598c-2b28-4e86-94f8-7fe7adf84f84)
- [Schutt & Williamson, APS DFD 2015](https://absimage.aps.org/image/DFD15/MWS_DFD15-2015-001997.pdf)
- [Morris & Williamson, APS DFD 2019](https://absimage.aps.org/image/DFD19/MWS_DFD19-2019-002305.pdf)

Coaching and practitioner:

- [Laser Training Manual (callala mirror)](https://www.callalajuniorsailingschool.org/Laser_manual.pdf)
- [ILCA, Downwind in Lasers (Emmett)](https://ilcasailing.org/downwind-in-lasers/)
- [Speed & Smarts #155](https://speedandsmarts.com/images/pdfs/currentissues/Speed__Smarts_Issue_155.pdf)
- [Sailing World, Finishing Techniques](https://www.sailingworld.com/how-to/finishing-techniques/)
- [Sailing World, Shoot to the Finish](https://www.sailingworld.com/how-to/shoot-to-the-finish/)
- [SailZing, by-the-lee primer](https://sailzing.com/sailing-by-the-lee-a-primer/)
- [SailZing, leeway](https://sailzing.com/understand-leeway-to-improve-upwind-performance/)
- [Peckover, Improper Course](http://www.impropercourse.com/2014/04/sailing-in-middle-of-fleet-sailing.html)
- [setcourses.com speed table](https://www.setcourses.com/Dinghy-Speed-Leg-Length.pdf)
- [ChartedSails, downwind technique](https://www.chartedsails.com/blog/learn-from-sailing-data-downwind-technique)

Forums and unattributed:

- [SailingForums, Laser speeds (Bethwaite points)](https://sailingforums.com/threads/laser-speeds.175/)
- [SailingForums, downwind Laser sailing](https://sailingforums.com/threads/downwind-laser-sailing.58/)
- [Reddit r/dinghysailing](https://www.reddit.com/r/dinghysailing/comments/1npp5ql/low_wind_lesson_in_a_laser_be_awkward/)
- [Hand-drawn Laser polar via Metaverse Sailing](https://metaversesailing.wordpress.com/wp-content/uploads/2013/02/laserpolar-via-btinternet-and-laser-one.png)

## Gaps

1. **No measured ILCA 7 polar above 12 kn.** All 14–20 kn off-wind cells rest on an unattributed hand-drawn chart (D4), cross-checked only against race VMG bands.
2. **Binns 2002 measured data only through Day's figures.** The original paper (HPYD 2002) wasn't retrieved, so measurement method, sea state and sailor weight are unknown. The Bethwaite graph (notmd.com) is dead, with no Wayback copy.
3. **No measured Laser gybe loss.** Speed-through-gybe curves weren't found. IB-Sailing SailViewer reports, which might have them, are blocked by Cloudflare.
4. **No quantified speed by the lee versus a broad reach.** The only primary test is light-wind, upright and wind-tunnel only, and it shows no gain. The coaching angles are forum and search-excerpt level.
5. **Turn rate, standing-start acceleration and coasting distance are not measured.** The values here are derived from tack time series or rules of thumb.
6. **Laser-specific leeway values are not published** in the sources found. Pennanen's per-speed yaw values are in a figure that wasn't extracted.
7. **The digitised figures carry reading error.** Day and D4 were digitised by pixel colour, about ±0.05 kn. D8 and the jcoaching tack curves were read by eye, about ±0.1 kn.
8. **Wind is measured differently across datasets.** Height and method vary (VPP true wind, motorboat anemometer, shore station for Semb, race-committee wind for D5), so TWS columns aren't strictly comparable.
9. **Not checked:** the Zattoni ILCA 6 upwind paper (IEEE 2024), and the Magnander & Larsson Zenodo coefficient dataset ([doi:10.5281/zenodo.7905074](https://doi.org/10.5281/zenodo.7905074)). The latter could feed a proper downwind VPP including AWA 190°.
