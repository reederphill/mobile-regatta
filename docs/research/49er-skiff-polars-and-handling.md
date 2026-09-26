---
question: What published 49er (and comparable asymmetric-spinnaker skiff — 49erFX, 29er, RS800, Musto Skiff) polars and handling numbers (VMG targets and angles, spinnaker groove and hoist/drop angles, planing thresholds and speed jump, tack and gybe loss, acceleration, coasting, turning, wind shadow, execution skills) exist to seed a v1.0 skiff class at 6 to 20 kn?
date: 2026-09-26
---

# 49er-style skiff polars and handling numbers

Research to seed the polar and handling model for a v1.0 boat class modelled on the 49er: a two-person 4.9 m skiff with twin trapezes, racks ("wings") and an asymmetric spinnaker (gennaker). Terms follow [`CONTEXT.md`](../../CONTEXT.md): polar, VMG, tack, gybe, sailing by the lee, groove. TWS is true wind speed, TWA true wind angle, AWA/AWS apparent wind angle/speed, BSP boat speed. Speeds are in knots unless marked. "Kite" means the gennaker.

Where 49er data is missing, 49erFX (same hull, smaller rig), 29er (Bethwaite's smaller skiff) and Musto Skiff coaching are used and marked as such. No usable RS800 data was found beyond its handicap.

## TL;DR

- **No published 49er polar table exists.** Nobody publishes a TWA × TWS grid. What exists:
  - **Race GPS** from the 2018 World Cup at Hyères: leg speed and leg VMG for the 49er in two wind bands and the 49erFX in three ([Gutiérrez-Manzanedo et al. 2025, *J. Navigation*](https://www.cambridge.org/core/journals/journal-of-navigation/article/gps-to-assess-an-olympic-regatta-49er-and-49erfx-classes/4336D8F027A475ED8F02CA438DC2A54B)).
  - **The class's race-officer course-time table**, giving upwind and run VMG in four wind bands ([49er class, DCJ v10, 2019](http://web.archive.org/web/20260213074636/https://49er.org/wp-content/uploads/2020/04/49er-speed-chart-1.pdf)).
  - **Measured GPS scatter polars at "7, 10 and 12 kn"** and full-scale **tow-test drag curves**, plus the designer's **theoretical polars at 6, 9 and 12 kn**, all in a 2007 internship report supervised by Julian Bethwaite ([Watin 2007](https://9eronline.com/library/49er%20Performance%20Enhancement%20Report%20by%20Simon%20Watin.pdf)).
  - A low-trust trainer-game polar (Tactical Sailing), manufacturer and class claims, and coaching.
- **The sources disagree by up to 50%.** The designer's polars and Watin's measurements sit 20–50% above race and race-officer numbers, most in light air. The seed polar sits between them: it matches race VMG once the ILCA precedent's race-to-polar factor is applied (×1.13 upwind, ×1.25 downwind).
- **Upwind:** best TWA **~45°** from 6 to 20 kn, widening to ~52° at 4 and 25 kn. Seed VMG **3.75 (6 kn), 4.67 (8), 5.59 (10), 6.08 (12), 6.43 (14), 6.65 (16), 6.79 (20)**. BSP plateaus at **9–10 kn** from about 16 kn (class: "upwind at 9–10 knots").
- **Downwind (kite up):** the groove moves **deeper as the wind builds**, from **135° at 4 kn to 140–145° at 6–8 kn, ~150° at 10–12 kn, ~155° at 14–16 kn and 160–165° at 20–25 kn**. Seed VMG **5.75 (6), 8.27 (8), 10.2 (10), 12.0 (12), 13.2 (14), 14.3 (16), 16.0 (20)**. So downwind VMG is about equal to TWS from 8 kn and nearly twice upwind VMG. Race legs give effective angles of 129–138° because they include gybes and lulls.
- **Planing:** the rig is fully powered at **~8 kn TWS** (Watin). The hull changes from displacement to planing at **6–8 kn BSP** with an almost "humpless" drag curve. Downwind, several sources put the step at **~8 kn TWS** (FX coaching; race VMG +56% from the 0–8 to the 8–12 kn band). Upwind the rise is smooth. Downwind there is a real **on/off-the-plane hysteresis**, and it comes from the apparent wind, not the hull (§4.4).
- **Spinnaker:** usable from about **110–120° TWA** down to ~165°. Hoist on the bear-away at the windward mark (squared away or by the lee while the kite goes up). Drop with a 1–3 s sharp bear-away or by gybing ([Ovington 49er manual](https://www.ussailing.org/wp-content/uploads/2020/08/49er-owner-manual.pdf)).
- **Manoeuvres:**
  - **Gybe:** measured at **8–10 m lost** (1.6–2 lengths), back to full speed **~12 s** after starting it (US 49er squad data). A slow "VMG" gybe loses 2 m less than a fast "question mark" gybe.
  - **Tack:** no measured 49er tack loss. A drag-based sketch gives 3–12 m. The seed is **~8–12 m**.
  - **Acceleration:** on a bear-away, BSP doubles from 9–11 kn in 5–7 s, which gives τ ≈ 2.5 s.
  - **Coasting head to wind** (derived from tow-test drag): half speed in ~3 s and ~10 m.
- **Wind shadow:** no skiff measurement. The shadow is cast along the **apparent** wind. In a skiff's downwind groove the AWA is 50–65°, so the shadow trails well out to the side, not straight downwind.

---

## 1. Datasets found

| # | Dataset | Kind | Coverage | Trust | Notes |
|---|---|---|---|---|---|
| S1 | Gutiérrez-Manzanedo, Caraballo et al. (2025), *J. Navigation* 78 | Measured (race GPS, TracTrac 5 Hz via SAP) | 2018 World Cup Hyères. 49er: 8 races, 5.5–11.6 kn, bands 0–8 and 8–12. 49erFX: 12 races, 4.4–12.8 kn, bands 0–8, 8–12 and 12–15. Leg mean speed, leg VMG, distance and manoeuvres, upwind and downwind | **High** for leg VMG. Not a polar | 39 crews (78 sailors). Values are in bar charts (Figs 3–4), read by eye to about ±0.2 kn. [Cambridge](https://www.cambridge.org/core/journals/journal-of-navigation/article/gps-to-assess-an-olympic-regatta-49er-and-49erfx-classes/4336D8F027A475ED8F02CA438DC2A54B), doi:10.1017/S0373463325101355 |
| S2 | 49er class race-officer "Sailing course times" table | Rule of thumb, published by the class | Upwind and run minutes per NM in 5–8, 8–12, 12–15 and 15+ kn | **Medium** | "DCJ version 10 dated March 2019". The live link 404s, so it was read from the [Wayback copy](http://web.archive.org/web/20260213074636/https://49er.org/wp-content/uploads/2020/04/49er-speed-chart-1.pdf) |
| S3 | Watin (2007), *49er performance enhancement*, internship report at Bethwaite Design, supervised by Julian Bethwaite | Measured: on-board GPS every 2 s, wind by hand anemometer and compass with a feather from a RIB. Also full-scale tow tests | Scatter polars at "7, 10, 12 kn" for the standard rig and two carbon prototype rigs, club and pro crews, 150 vs 175 kg crews. Hull drag 4–18 kn | **Medium** for shape and ratios. **Low-medium** for absolute speed vs TWS | [PDF](https://9eronline.com/library/49er%20Performance%20Enhancement%20Report%20by%20Simon%20Watin.pdf). Digitised by pixel colour (§2.3), about ±0.5 kn and ±5°. It doesn't always say whether a chart is the "average" or the "gust" polar |
| S4 | Bethwaite Design "Theoretical 49er speed polars" (in S3, PDF p. 35) | Modelled (designer's prediction) | 6, 9 and 12 kn, 45–180° | **Medium-low** | Watin: they "tendency to overestimate boat speed for a standard rig", recalibrated "by a scale factor of approximately 10 %" (PDF p. 46). Digitised by eye, ±0.5 kn |
| S5 | Ovington *49er Owner's Manual* (US Sailing special edition) | Manufacturer and designer coaching | Tack, gybe, bear-away, hoist and drop technique. A few numbers | **Medium** | [PDF](https://www.ussailing.org/wp-content/uploads/2020/08/49er-owner-manual.pdf) |
| S6 | Class and manufacturer specs and claims | Primary, but marketing | Dimensions, weights, sail areas, "upwind at 9–10 knots", "controllable over 20 knots", top speed ~25 kn | **Medium** | [49er.org design elements](https://49er.org/design-elements/), [49er.org FX](https://49er.org/49erfx/), [Mackay 49er](https://mackayboats.com/index.cfm/boats/49er/), [Mackay FX development](https://mackayboats.com/index.cfm/news/fx-technical-development/) |
| S7 | McBride Racing / Racing Alpha, US 49er squad gybe analysis (2020) | Measured (coach's GPS/IMU analytics) | One pair of gybes: loss in metres and time to full speed | **Medium** (one example, conditions not stated) | [McBride.Racing](http://mcbrideracing.com/racing-alpha/2020/11/19/49er-squad-gybing-improvements) |
| S8 | World Sailing / class RRS 42 guides for 49er and 49erFX (2014, 2022) | Rules guidance | What pumping, sculling and rocking is allowed, and when breaches happen | **High** | [2022 (Wayback)](http://web.archive.org/web/20260213075645/https://49er.org/wp-content/uploads/2024/03/2022-03-RRS-42-Guide-49er-49erFX.pdf), [2014](https://www.sailing.org/tools/documents/Rule4249er2014-%5B16132%5D.pdf) |
| S9 | Lindsay, "A data-driven race-winning formula", *Sailing World* | Measured (SAP tracking, every 49erFX race 2016–2021), regression | Only sample rows are shown: downwind-leg VMG and gybe speed loss | **Low-medium** (samples, no wind) | [Sailing World](https://www.sailingworld.com/how-to/a-data-driven-race-winning-formula/) |
| S10 | Tactical Sailing "49er Polardiagrams – Butterflies" | Trainer game. Says it is "based on practical experience of professional sailors based on a velocity prediction program" | 5–25 kn, 0–180° | **Low** | [Page](https://www.tacticalsailing.com/en/games-tips/boats), [image](https://www.tacticalsailing.com/fileadmin/files/spiele-tipps/boats/49er_all_kn_01.png). Read by eye for downwind only. Its upwind lobe (about 6–8 kn BSP at 25 kn TWS) is implausibly slow |
| S11 | RYA Portsmouth Yardstick 2025 | Club-racing handicap (elapsed-time ratio) | 49er 697, RS800 799, Musto Skiff 834, 29er 900, ILCA 7 1104 | **Medium** as a cross-check of average speed | [Main list](https://britishsailingteam.rya.org.uk/media/vc0bdum2/py_list_2025-1.pdf). The 49er is on the [limited-data list](https://britishsailingteam.rya.org.uk/media/5m4e1iyw/limited-data_pn_list_2025-1.pdf) ("number is for new rig", 2018) |
| S12 | Skiff coaching: 29er Owner's Rigging Manual, 29er Coaching Manual, 29er Best Practice Guide, Julian Bethwaite's *Skiff Tips*, Musto Skiff User's Manual, Reineke on FX modes | Coaching | Planing cues, gybe technique, heel, modes | **Medium-low** | [29er rigging](https://www.29erkv.de/downloads/29er_rigging_manual.pdf), [29er coaching](https://www.dinghyshop.dk/userfiles/file/tuningguides/29er_coaching_manual.pdf), [29er best practice](https://www.29er.org.uk/29ermedia/docs/29er%20Best%20Practice%20Guide-v1.pdf), [Skiff Tips](https://aus9ers.com.au/wp-content/uploads/2023/04/skiff-tips.pdf), [Musto Skiff manual](https://mustoskiff.com/wp-content/uploads/2020/09/160629-Musto-Skiff-Users-Manual.pdf), [Reineke, *Sailing World*](https://www.sailingworld.com/how-to/how-to-find-your-speed-mode/) |

Rejected or not usable:

- **Bethwaite's *High Performance Sailing* (2nd ed.)** and ***Higher Performance Sailing***. A 2004 forum answer says "all of the appropriate 49er information is included" ([boatdesign.net](https://www.boatdesign.net/threads/australian-18-or-49er-polars.5288/)), but neither book is online. This is the biggest unread source.
- **The R3-class SKIFF VPP** (IEEE 2020). It is a different boat and only the abstract is visible ([ResearchGate](https://www.researchgate.net/publication/344398484_Development_of_a_Velocity_Prediction_Program_for_a_High_Performance_Eco_Sustainable_SKIFF_Sailing_Yacht)).
- **Paris 2024 and Tokyo 2020 tracking.** No published per-leg speeds were found.
- **SailGP** is not a comparable boat. **RS800 and Musto Skiff polars:** none found. There are no ORC or qtVlm skiff polars.
- **Forum speed claims.** They are kept only as low-trust colour (§2.6).

---

## 2. Per-dataset numbers

### 2.1 Race GPS, Hyères 2018 (S1)

Read by eye from Figs 3 (FX) and 4 (49er), about ±0.2 kn. Values are per-leg means. The "effective angle" is acos(VMG / mean speed). It **includes** manoeuvres, lulls and tactics, so it is wider than the true groove.

| Class, band | Upwind speed | Upwind VMG | Effective upwind TWA | Downwind speed | Downwind VMG | Effective downwind TWA | Manoeuvres per leg (up / down) |
|---|---|---|---|---|---|---|---|
| 49er, 0–8 kn | 6.15 | 3.7 | 53° | 8.4 | 5.3 | 129° | 3.7 / 2.55 |
| 49er, 8–12 kn | 7.9 | 4.9 | 52° | 11.5 | 8.25 | 136° | 3.0 / 2.85 |
| FX, 0–8 kn | 5.4 | 3.3 | 52° | 7.7 | 5.15 | 132° | 3.3 / 2.7 |
| FX, 8–12 kn | 7.0 | 4.3 | 52° | 9.8 | 6.75 | 134° | 3.2 / 2.8 |
| FX, 12–15 kn | 8.4 | 5.05 | 53° | 12.3 | 9.2 | 138° | 3.0 / 2.5 |

- Mean leg distance sailed was 1,930 m and 2,230 m upwind, and 1,850 m and 1,930 m downwind (49er, 0–8 and 8–12 kn).
- The paper does not give the mean wind within each band. The 49er races ran in 5.5–11.6 kn (S1 §2.2), so the 0–8 band is closer to 6–7 kn than 4 kn.
- 49er vs FX in the 8–12 band: +14% upwind VMG and +22% downwind VMG.

### 2.2 Class race-officer table (S2)

Converted from minutes per NM (60 / minutes).

| Band | 5–8 kn | 8–12 kn | 12–15 kn | 15+ kn |
|---|---|---|---|---|
| Upwind VMG | 4.0 | 5.0 | 6.0 | 6.0 |
| Run VMG | 6.0 | 8.6 | 10.0 | 10.0 |

- It agrees with S1 in the 8–12 band (4.9 and 8.25).
- It is flat from 12–15 to 15+ kn. Racing speed in a breeze is limited by control, not by the polar. At Marseille 2019, for example, only 4 of 14 49ers finished a 20–25 kn race ([49er.org](https://49er.org/everything-but-standard-sailing/)).
- Against setcourses.com's Laser Full table (ILCA write-up, D7), the 49er is 1.33–1.6× faster upwind and 1.5–1.7× faster downwind.

### 2.3 Watin measured scatter polars (S3)

Digitised by pixel colour: median radius per 5° bin, with the ring scale read from each chart's labels. Accuracy is about ±0.5 kn and ±5°. The same standard-rig 12 kn data appear in two charts, and they differ by up to 0.6 kn, which shows the reading error. "TWS" is Watin's measurement, about 1–2 m above the water from a RIB (see §3).

| Chart (PDF page) | TWS | 45° | 60° | 90° | 120–130° | 140° | 145° | 150° | 155° | 160° |
|---|---|---|---|---|---|---|---|---|---|---|
| Standard rig, club crews (p. 42 left) | 12 | 9.1 | 9.9 | 11.4 | 8.5–10.2 | 12.6 | 13.9 | 15.4 | 16.6 | 17.0 |
| Standard rig, club crews (p. 42 right) | 12 | 9.7 | 10.9 | 11.6 | 10.3–12.5 | 14.9 | 16.4 | 16.8 | 16.8 | — |
| Southern Spars carbon rig, club (p. 42 left) | 12 | 10.5 | 11.6 | 11.6 | 12.7 | 16.0 | 17.3 | 17.6 | 17.1 | 16.2 |
| SS rig, skilled, light crew 150 kg (p. 44) | 12 | 10.3 | — | — | — | 13.9 | 15.1 | 15.6 | 16.0 | 16.3 |
| SS rig, skilled, heavy crew 175 kg (p. 44) | 12 | 11.2 | — | 15.0 | — | 13.4 | 15.5 | 17.3 | 17.6 | 14.6 |
| Standard rig, club crews (p. 43) | 10 | 8.5 | 8.9 | — | 12.8 (130°) | 13.7 | 14.1 | 14.3 | 13.9 | — |
| Standard rig (recalibration chart, p. 46) | 10 | 9.4 | 10.4 | — | — | — | — | 15.8 | 16.1 | 16.4 |
| CST carbon rig, Australian Olympic team (p. 45) | 10 | 10.3 | 10.4 | — | — | 15.4 | 15.7 | — | — | — |
| CST rig, club light crew (p. 45) | 10 | 8.3 | 9.1 | — | 10.7 (130°) | 11.8 | 12.0 | 12.1 | 12.0 | 11.7 |
| CST rig, club heavy crew (p. 45) | 10 | 9.0 | 9.6 | 10.8 | 11.4 | 13.9 | 14.4 | 14.0 | 13.5 | 13.0 |
| CST rig summary (p. 52) | 10 | 9.6 | 10.7 | 13.0 | 14.8 | 16.2 | 16.3 | 15.5 | 15.0 | — |
| CST rig summary (p. 52) | 7 | 8.0 | ~8.1 | ~8.1 | 8.1 | 8.8 | 9.6 | 10.1 | 10.2 | 10.3 |

What the charts show:

- **Best downwind VMG is at 145–160°** in the 10–12 kn charts. The standard rig at 12 kn is still improving at 160–165°, so its optimum is at or beyond the deepest points recorded.
- **There is a hole at 100–115°** in the standard-rig charts (5.7–6.8 kn at 105–115°, 12 kn). The crews were bearing away between two-sail reaching and the kite. This is the same feature as the "spinnaker hook" in S4.
- **Crew skill is worth about 20–25%.** At 10 kn on the same rig, the Olympic team made 10.3 at 45° and 15.7 at 145°. The club light crew made 8.3 and 12.0 (p. 45).
- **Crew weight is worth ~15% above the design wind:** "a speed advantage of 15% for the heavy crew through all the tack range" (175 vs 150 kg, 12 kn, p. 44).
- **Design wind is ~8 kn:** "around 8 knots for a 49er compared to 15 knots for a 'classical' Olympic dinghy like the 470" (p. 31).

### 2.4 Bethwaite theoretical polars (S4)

Read by eye from the p. 35 chart (23.1 px per knot), ±0.5 kn. The curves start at the 45° reference line, which they cross at about 49°.

| TWS | Upwind BSP (~49°) | 90° | Kite "hook" tip (best downwind VMG) | Downwind VMG |
|---|---|---|---|---|
| 6 | 7.6 | 11.8 | 12.2 at ~140° | 9.3 |
| 9 | 9.6 | 13.5 | 14.1 at ~149° | 12.1 |
| 12 | 11.0 | 15.1 | 17.2 at ~155° | 15.6 |

- The chart labels a V-shaped **"spinnaker hook"** at 120–160°. Speed drops as the boat bears away on two sails, then jumps once the kite fills.
- Watin says it overestimates the standard rig by ~10%, "though there is a good correlation … at the crucial wind angles, when tacking up- and downwind" (p. 46).
- The best-VMG angle moves deeper with wind: **140° → 149° → 155°**.

### 2.5 Manufacturer, class and coaching numbers (S5, S6, S12)

| Claim | Value | Source |
|---|---|---|
| LOA, LWL, beam | 4.90 m (4.995 m per Mackay), 4.80 m, 2.90 m over the racks | S5 p. 3; [Mackay](https://mackayboats.com/index.cfm/boats/49er/) |
| Weights | Hull 94 kg, rigged 125 kg, crew 145–165 kg. The tow tests used a "design sailing weight of 290 kgs" | Mackay; S3 p. 13 |
| Sail area | 21.2 m² upwind, 38 m² downwind (S5). Mackay lists main 16.1 and jib 5.1, but also "spinnaker 21.2 m²", which looks like a copy of the upwind total. FX: main 13.8, jib 5.8, gennaker 25.1, mast 7.5 m | S5; Mackay; [49er.org FX](https://49er.org/49erfx/) |
| Mast | 8.22 m standard (2007), 8.37 m carbon | S3 p. 30, 44 |
| Upwind speed | Bow stays "directionally stable while moving upwind at 9–10 knots" | [49er.org design elements](https://49er.org/design-elements/) |
| Control | "controllable over 20 knots" | same |
| Top speed | "reaches speeds of 25 knots" (49er). FX "around 25 knots" (search excerpt) | Mackay; World Sailing FX page via search excerpt |
| Tack heading change | "pick a spot 90 degrees to the initial heading" | S5 §5.3 |
| Bear-away at the windward mark (20+ kn) | "boat speed coming into a top mark is probably 9–11 knots … well executed bear away will take 5–7 seconds at the end of which the 49er will be moving at double the entry speed" | S5 §5.5 |
| FX mode crossover | "At around 8 knots, or when both skipper and crew are fully trapping", low mode becomes favourable downwind. A 1–2 kn puff flips the mode | [Reineke](https://www.sailingworld.com/how-to/how-to-find-your-speed-mode/) |
| Mode width (keelboats, generic) | Slow modes are 3–5° from the VMG angle. Fast modes are "sometimes as much as 10 degrees" | [Horton & Powlison, *Sailing World*](https://www.sailingworld.com/how-to/the-mechanics-of-mode/) |
| 29er planing cue | "When there is enough breeze to trapeze upwind, there is plenty of wind to trapeze and plane downwind. If you're not planing, head up a bit or ease the spinnaker sheet" | [29er rigging manual](https://www.29erkv.de/downloads/29er_rigging_manual.pdf) |
| Heel | "+/- 5 degrees is acceptable, +/- 10 degrees is only just tolerable" | [Julian Bethwaite, *Skiff Tips*](https://aus9ers.com.au/wp-content/uploads/2023/04/skiff-tips.pdf) |

### 2.6 Low-trust numbers (S9, S10, forums)

| Claim | Value | Source | Trust |
|---|---|---|---|
| FX downwind-leg VMG, sample rows | 12.59, 13.59, 8.56 kn (wind not shown) | S9 | Low-medium |
| FX gybe speed loss, sample rows | 2.43, 1.96, 1.54 kn | S9 | Low-medium |
| Tactical Sailing peak downwind BSP | ~3.8 at 127° (5 kn), 10.4 at ~141° (10), 15.0 at ~141° (15), 17.3 at ~152° (20), 19.8 at ~159° (25) | S10, read by eye | Low |
| Tactical Sailing beam reach | 4.3 (5), 7.1 (10), 10.9 (15), 14.1 (25) | S10 | Low |
| "49er rarely exceeds 20 kts downwind, but easily does 15 kts in 15 kts of wind" | — | [16ft skiff forum](https://www.tapatalk.com/groups/16ftskiffs/how-fast-does-your-skiff-go-t300.html) (search excerpt, 403) | Low |
| The 49er is a "true upwind planing" boat. 49ers and A-class cats do "10–12 knots upwind in 10+" | — | [Sailing Anarchy](https://forums.sailinganarchy.com/threads/what-is-the-secret-of-upwind-planing.176174/) (search excerpt) | Low |
| "In planing conditions skiff tacks can be … 2 seconds faster without a roll tack" | — | [Sailing Anarchy, 29er roll tacks](https://forums.sailinganarchy.com/threads/29er-roll-gybes-and-roll-tacks.134001/) (search excerpt) | Low |

### 2.7 Handicap cross-check (S11)

PY is an elapsed-time ratio. The 49er (697) is **1.58×** the ILCA 7 (1104) over a typical club course. The RS800 (799) is 1.38×, the Musto Skiff (834) 1.32× and the 29er (900) 1.23×.

The seed polar in §7 gives a course-speed ratio over the ILCA seed of **1.40 (6 kn), 1.49 (8), 1.60 (10), 1.68 (12), 1.70 (14–16), 1.66 (20)**, for equal upwind and downwind legs at best VMG (checked by script). That fits PY at club-typical 8–12 kn.

---

## 3. Disagreements side by side (about 10–12 kn TWS)

| Quantity | Race GPS 49er, 8–12 (S1) | Class table, 8–12 (S2) | Watin "10 kn" | Watin "12 kn" | Bethwaite theory, 9 / 12 kn | Tactical Sailing, 10 / 15 kn | **Seed, 10 / 12 kn** |
|---|---|---|---|---|---|---|---|
| Upwind BSP (~45°) | 7.9 (leg mean) | — | 8.3–10.3 | 9.1–11.2 | 9.6 / 11.0 | not legible | **7.9 / 8.6** |
| Upwind VMG | 4.9 | 5.0 | 5.9–7.3 | 6.4–7.9 | ~6.3 / ~7.2 | — | **5.6 / 6.1** |
| Beam reach (90°) | — | — | 10.8–13.0 | 11.4–15.0 | 13.5 / 15.1 | 7.1 / 10.9 | **11.0 / 11.8** |
| Downwind VMG | 8.25 | 8.6 | 10.5–13.4 | 13.9–16.0 | 12.1 / 15.6 | ~8.1 / ~11.7 | **10.2 / 12.0** |
| Best downwind TWA | 136° effective (lossy) | — | 145–155° | 150–165° | 149° / 155° | ~141° | **150° / 153°** |

- **Upwind:** the class claim (9–10 kn in a breeze), Watin and the designer agree with each other. Race leg VMG is ~25–35% lower.
- **Downwind:** the spread is up to 1.6×. In light air (6–7 kn), the designer and Watin put downwind VMG **above** TWS (9.2–9.3). Race data put it at ~0.8× TWS (5.3).

Why S3 and S4 probably read high:

1. **Wind height.** Watin's wind was read on a RIB with a hand anemometer. With a standard log profile over open water (z₀ ≈ 0.0002 m), 10 m wind is 1.17–1.21× the wind at 1.5–2 m. So Watin's "10 kn" is probably 11.5–12 kn at race-committee height (derived).
2. **"Gust" polars.** Watin built some polars by pairing "the highest speed for each wind angle" with the gust speed, and doesn't always say which chart is which (p. 39).
3. **Flat water** in a protected bay of Sydney Harbour (p. 14), and straight-line sailing with no manoeuvres.
4. **Rig era.** Watin's standard rig is the 2007 alloy/carbon rig. S1 (2018) is the post-2017 rig (PY note "new rig", 2018).

Why S1 and S2 read low: leg averages include tacks and gybes (2.5–3.7 per leg), roundings, hoists and drops, lulls that drop the boat off the plane, and tactical sailing off the groove. The ILCA precedent (ILCA write-up §2.5) had race VMG ~12% below the polar upwind and ~22% below it downwind.

**Seed choice.** The seed takes race and class-table VMG × **1.13 upwind** and × **1.25 downwind**, the ILCA precedent's race-to-polar factors. It uses S3 and S4 for **shape** (angles, the kite hook, the reach), and caps absolute speeds below S3.

---

## 4. Derived targets

### 4.1 Upwind VMG targets

| TWS | Target TWA | Target BSP | Target VMG | Evidence |
|---|---|---|---|---|
| 4 | ~52° | 4.5 | 2.77 | Judgement. Light air sails wider, like ILCA D8 |
| 6 | 45° | 5.3 | 3.75 | S1 0–8 band 3.7 × 1.13 ≈ 4.2 at ~6.5–7 kn. S2 4.0 |
| 8 | 45° | 6.6 | 4.67 | Interpolated |
| 10 | 45° | 7.9 | 5.59 | S1 8–12 band 4.9 × 1.13 = 5.5. S2 5.0 × 1.13 = 5.65 |
| 12 | 45° | 8.6 | 6.08 | Between S1 and S3 (Watin "10 kn", wind-corrected to ~12: 8.3–10.3) |
| 14 | 45° | 9.1 | 6.43 | FX 12–15 band 5.05 × 1.14 (49er vs FX) × 1.13 = 6.5. S2 6.0 × 1.13 = 6.8 |
| 16 | 45–46° | 9.4 | 6.65 | Class: "upwind at 9–10 knots" |
| 20 | 45–48° | 9.6 | 6.8 | Plateau (S2 is flat above 12–15) |
| 25 | ~52° | 11.2 at 52° | 6.9 | Judgement: sail wider to depower. S6 "controllable over 20 knots" |

- **Tacking angle.** S5's 90° heading change fits a ~45° TWA with a little leeway. Watin's test protocol sailed "around 45° (upwind tack) and 150° (downwind tack, with spinnaker)" (p. 35).
- **Saturation.** BSP gains only ~0.3 kn per knot of wind above 12 kn, and upwind VMG is ~95% of its 20 kn value by 14 kn. That is later than the ILCA, which saturates at 11–12 kn, even though the rig is fully powered at ~8 kn. The trapeze crew's righting moment keeps buying speed.

### 4.2 Downwind VMG targets and the groove

| TWS | Groove TWA | BSP | VMG | VMG / TWS | AWA at the groove (derived) |
|---|---|---|---|---|---|
| 4 | 135° | 5.1 | 3.61 | 0.90 | 51° |
| 6 | 140° | 7.5 | 5.75 | 0.96 | 53° |
| 8 | 142–145° | 10.1 | 8.27 | 1.03 | 52° |
| 10 | 150° | 11.8 | 10.2 | 1.02 | 58° |
| 12 | 150–155° | 13.2–13.8 | 12.0 | 1.00 | 63° |
| 14 | 155° | 14.6 | 13.2 | 0.95 | ~70° |
| 16 | 155° | 15.8 | 14.3 | 0.90 | 79° |
| 20 | ~160° | 16.6–17.6 | 16.0 | 0.80 | ~100° |
| 25 | 165° | 17.6 | 17.0 | 0.68 | ~135° |

- **The groove moves deeper with wind.** S4 gives 140/149/155° at 6/9/12 kn. S3 gives 145–165° at 10–12 kn. Coaching agrees: "If a boat is hit by a gust, she needs to bear away! If running into a lull, she needs to luff!" ([RRS 42 guide](http://web.archive.org/web/20260213075645/https://49er.org/wp-content/uploads/2024/03/2022-03-RRS-42-Guide-49er-49erFX.pdf)). The Musto Skiff manual says the same ("When a gust comes – bear away under it … In the lulls, luff up a little to keep the speed on and the apparent wind strength up").
- **This matches the expected ~135–155° band from 4 to 16 kn** and goes deeper in a breeze, where a 49er can't hold a high angle with the kite up. (The same guide's "in strong gusts 49ers keep sailing on a close-hauled course as they can't bear away" is about the windward mark, not the run.)
- **The groove is flat.** In the seed, best VMG at 12 kn is within 0.1 kn (1%) over 145–155°. Speed-vs-VMG modes are about ±5–10° (S12, keelboat source).
- **AWA stays at 50–65° from 4 to 12 kn.** At BSP ≈ TWS and TWA ≈ 145–155°, the apparent wind is only 6–8 kn. This is apparent-wind sailing. It matters for the shadow (§5) and for the planing hysteresis (§4.4).

### 4.3 Where the spinnaker goes up and down

| Item | Value | Source |
|---|---|---|
| Kite useful from | ~110–120° TWA (the kite "hook" in S4 at 120–160°; the S3 hole at 100–115° where crews bear away between two-sail and kite modes). In light air, possibly from ~90–100° | S3, S4; lower bound is judgement |
| Kite limit going deep | The 49er kite "begins to collapse from the back" when bearing away significantly. The FX kite is "much flatter and flies further off the boat" | [49er.org FX](https://49er.org/49erfx/) |
| Windward set (hoist) | Bear away. By "1st spreader" be "running dead down wind … it even helps to run by the lee". Hold square or by the lee "until the head of the spinnaker is about a meter from the tip", then round up to course | S5 §5.6 |
| Leeward set | Keep bearing away "but not to the same extent". The skipper stays on the wire in 12 kn | S5 §5.6 |
| Gybe set | Bear-away continued into a gybe, with the kite at the top as the boom crosses | S5 §5.6 |
| After the hoist | "set the spinnaker first then get the crew out … the boat will move very quickly to high VMGs" | S5 §5.6 |
| Windward drop | Crew pulls the retrieval line while the skipper does a "momentarily (1–3 secs) bearaway, quite sharply" | S5 §5.7 |
| Drop options | "gybe drop always the fastest, the windward drop the safest but the leeward drop the cleanest" | S5 §5.7 |
| Hoist and drop duration | **Not measured.** Judgement: 3–5 s each, during which the boat sails on two sails | — |

**Seed (judgement):**

- Kite allowed at TWA ≥ 110° and forced down below ~100°.
- Hoist on the bear-away, passing through 150–180°. Drop from the groove with a brief bear-away.
- The polar's 110–180° rows assume the kite is up. The 0–90° rows assume two sails.

### 4.4 Planing onset, speed jump and hysteresis

**Thresholds:**

| Mode | Onset | Evidence |
|---|---|---|
| Hull | Displacement → planing at **6–8 kn BSP** ("forced mode … between 6 and 8 kts for a 49er"). Drag has "a very small drag 'hump' around 7 knots" and is otherwise "humpless" (Frank Bethwaite, 1996). Hull speed of a 16 ft hull ≈ 5.4 kn | S3 pp. 18, 24–25 |
| Rig | Fully powered ("design wind") at **~8 kn TWS** | S3 p. 31 |
| Downwind with kite | **~8 kn TWS**: FX low-mode crossover at "around 8 knots, or when both … fully trapping". FX "will begin to plane" above 8 kn. 29er: enough to trapeze upwind means planing downwind | Reineke; Roble/Shea via search excerpt (site 522); 29er manual |
| Reaching | ~6–7 kn TWS. Seed BSP at 110° is 7.8 at 6 kn and 10.4 at 8 | Derived from the hull threshold |
| Upwind | BSP passes 7–8 kn at ~8–10 kn TWS. 49ers are described as upwind-planing | Seed; SA forum (low) |

**The speed jump:**

- **Race VMG, 49er, 0–8 → 8–12 kn band:** downwind +56% (5.3 → 8.25), upwind +32% (3.7 → 4.9).
- **FX:** downwind +31% then +36%; upwind +30% then +17% (S1).
- **Class table:** run +43% (6.0 → 8.6), then +16% and 0% (S2).
- **Seed:** the steepest downwind step is **6 → 8 kn: best VMG 5.75 → 8.27 (+2.5 kn, +44%)**. The reach (110°) goes 7.8 → 10.4. Upwind rises ~0.65 kn of BSP per knot from 6 to 10 kn, with no step. The ILCA's step is at 12–14 kn, so the skiff's planing arrives 4–6 kn earlier.

**What drops a skiff off the plane:**

- **Lulls**, unless the boat luffs to rebuild apparent wind (RRS 42 guide; Musto manual).
- **A fast, tight gybe.** The "question mark" gybe loses more because the kite fills late (S7). A smooth gybe drops a 29er "off a plane for a second or two, if at all" (29er manual).
- **Heel beyond ±5–10°** (*Skiff Tips*).
- **Nose-diving in waves**, and a slow bear-away arc in a breeze ("heavy bowdown trim / nose diving … capsize", S5).
- **Wind shadow.** Not measured, but it cuts AWS.

**Hysteresis (derived from the seed and apparent-wind geometry):**

- At 8 kn TWS and 145° on the plane (10.1 kn), AWA is 52° and AWS 5.8 kn. The kite is fed from forward.
- At the same heading off the plane (6 kn), AWA swings to **97°**. The kite sits behind the main and the boat can't accelerate. It has to head up to ~125° (AWA 78°, AWS 6.7) to re-plane.
- At 12 kn TWS and 153°, AWA is 63° on the plane (13.5 kn) but **124°** off it (7 kn).

So the same TWA can hold two stable speeds, and getting back on the plane costs height. That is the "head up to get going, then bear away" cue in every skiff source above. The hull drag curve has almost no hump, so upwind a plain speed ramp is enough.

---

## 5. Wind shadow of a skiff

**Nothing skiff-specific is published.** What exists:

| Claim | Value | Source | Trust |
|---|---|---|---|
| Shadow direction | Position "in line with her apparent wind". The shadow follows the apparent wind, not the true wind | [Speed & Smarts, Covering Downwind](https://www.speedandsmarts.com/toolbox/articles2/articles/covering-downwind) | Medium (coaching) |
| Shadow reach, generic dinghy | "within four or five boatlengths" to hurt the boat ahead | same | Medium |
| Loss to the downstream yacht | "significant loss in drive force, due to a decrease in the velocity of the wind and an adverse change in the apparent wind angle" (wind tunnel, two yacht models; upwind at AWA 20°, asymmetric at 60°, symmetric at 120°) | [Richards et al., Univ. of Auckland YRU](https://www.researchgate.net/publication/260753324_A_Wind_Tunnel_Study_Of_The_Interaction_Between_Two_Sailing_Yachts) (abstract via search; full text 403) | High, but no numbers retrieved |
| Existing repo guidance | Obstacle wake is greatest at 2–5 heights and significant to 10H (windbreak proxy) | [wind-and-current physics research §4](wind-and-current-physics-for-realtime-sim.md) | Medium (land proxy) |

**Derived for the skiff:**

- **Direction.** A disturbed air parcel drifts with the true wind while the boat moves on. Relative to the boat, the trail points along the **apparent-wind** direction.
  - Upwind (AWA ~25°) that is nearly the ILCA-style cone behind and to leeward.
  - Downwind in the groove (AWA 50–65° at 4–12 kn, §4.2), the cone points **~115–130° off the bow to leeward**: broad on the leeward quarter, not astern.
  - So a skiff's downwind shadow hits boats **abeam-to-leeward and behind**, not the boat dead downwind. It swings aft as the wind builds and AWA moves aft (80–100° at 16–20 kn).
- **Size.** The mast is 8.2–8.4 m (S3), against the ILCA's ~6.5 m (not sourced here). Upwind sail area is 21 m² and the kite 38 m² (S5). On the "N heights" rule the shadow is ~1.3× the ILCA's in length. In boat lengths it is about the same (4–5 lengths ≈ 20–25 m).
- **Downwind strength.** AWS is only 6–8 kn in the groove. A shadow that cuts AWS by a given fraction also pushes AWA aft. It can therefore flip a boat into the off-the-plane state (§4.4), which makes skiff shadow **more punishing downwind** than a simple speed-fraction loss. This is judgement and needs tuning.

---

## 6. Manoeuvres, acceleration, coasting and turning

### 6.1 Tacks

| Quantity | Value | Source |
|---|---|---|
| Heading change | ~90° | S5 §5.3 |
| Turn-rate profile | "the rate of turn at the start of the tack should be substantially slower than at the end". Maximum "about 70% of the way through" | S5 §5.3 |
| Speed loss vs a 470 | The 49er "will slow down at a greater rate" (rig drag), with "a greater distance to cover during the tack" | S5 §5.3 |
| After the tack | "49ers lose speed badly" | RRS 42 guide 2022 |
| Jib | Eased 100 mm (normal) to 200 mm ("fresh to frightening") before the tack, and "should not be re trimmed in until the boat is 'almost up to speed'" | S5 §5.3 |
| Technique | "Crew first" is fastest. "Skipper first" is "the survival technique" | S5 §5.3 |
| Tacks per upwind leg (racing) | 3.0–3.7 | S1 |

No measured 49er tack loss was found.

**Derived sketch**:

- Inputs:
  - Watin's minimum hull drag: ~20 kgf at 8 kn, 26 at 10, 32 at 12 (S3 p. 25).
  - +10% for foils.
  - Windage CdA 1.5 m² on the flogging rig and crew (judgement).
  - Mass 290 kg + 10% added mass.
  - A 2.5–4 s turn through 90°, then recovery with τ 2.5–4 s.
- Result: minimum speed 45–60% of entry, and a loss of **3–5 m (fast turn) to 7–9 m (4 s turn)** at 10–12 kn. At 16 kn: 5–12 m.
- This is a lower bound, because it ignores crew crossing time and the eased jib.

**Seed:**

- **~10 m (2 lengths)** in medium air, 6–8 m in light air, 10–14 m in 16+ kn.
- A tack costs about as much as a gybe (§6.2), unlike the ILCA, where a tack costs 2–4× a gybe.

### 6.2 Gybes and staying on the plane

| Quantity | Value | Source |
|---|---|---|
| Loss per gybe, 49er | **8 m** for a slow-turn "VMG" gybe vs **10 m** for a fast-turn "question mark" gybe | S7 |
| Back to full speed | "12 seconds beyond the start of each gybe, the boat has returned to full speed in both cases" | S7 |
| Exit position | A fast turn ends "almost dead-downwind of the starting position". A slow turn ends "nicely bow out on port" | S7 |
| Speed loss, FX | 1.5–2.4 kn (three sample boats) | S9 |
| When to gybe | "just after having accelerated in a gust or running down the face of a wave … the boat will have the greatest speed" | S5 §5.4 |
| Exit | "bear away quite sharply, so as to neutralise the turning and heeling moments". Without speed a gybe "is usually rather 'wet'" | S5 §5.4 |
| Staying on the plane (29er) | Smooth gybe: "the 29er will only drop off a plane for a second or two, if at all". In 20+ kn, "it is advantageous to be planing when going into a gybe" | 29er rigging manual |
| Gybes per downwind leg | 2.5–2.9 | S1 |

**Seed:**

- 8 m (1.6 lengths) for a good gybe, 10–12 m for a poor one, and full speed by ~12 s.
- A gybe entered off the plane, or into a lull, costs roughly an extra 5–10 m. That is judgement: it is the time to re-plane at τ ≈ 2.5 s after heading up (§4.4).

### 6.3 Acceleration

- **Bear-away (S5):** 9–11 kn → double in 5–7 s. Fitting v(t) = v_t − (v_t − v₀)·e^(−t/τ) with v_t ≈ 1.9–2.1 × v₀ gives **τ ≈ 2.2–2.8 s** (derived). Compare the ILCA seed's τ ≈ 4 s.
- **Gybe recovery (S7):** full speed 12 s after the start. Once the kite fills, that fits τ ≈ 2.5–3 s.
- **From near-stopped (starts):**
  - No measurement.
  - The class RRS 42 guide explains that a 49er bearing away "from almost stopping situation … needs to push out the boom", then pump to re-invert the fully battened main.
  - The "small and vertical rudder" needs "forceful and repeated movements to change her course". Sculling is allowed by class rule if it doesn't propel the boat.
  - **Seed (judgement):** a 2–3 s "unstick" delay with poor turning authority, then τ ≈ 3 s. Light air is slower: the 29er's crew sits forward of the shrouds until ~10 kn to keep the transom out (*Skiff Tips*).

### 6.4 Coasting head to wind

- No measurement.
- **Derived** from the drag sketch in §6.1, head to wind from 8.6 kn in 12 kn TWS: **75% of entry speed in 1.3 s (5 m), 50% in 3.3 s (10 m), 25% in 7 s (16 m)**. It is ~20 m before nearly stopped.
- From 6.6 kn in 8 kn: 50% in 4.5 s (11 m).
- **Seed:** ~2 lengths to half speed. That is longer than the ILCA's half a length, because the skiff is twice the all-up mass (290 kg) and faster on entry. It is shorter per knot of entry speed, because of the big rig's windage.

### 6.5 Turning

- No direct measurement.
- **Derived:**
  - **Bear-away:** ~100° (45° → ~150°) in 5–7 s, which averages **15–20°/s**, in 20+ kn (S5). The manual warns it is "almost impossible to do it too fast", and a slow arc capsizes.
  - **Tack:** 90° in ~3 s averages **~30°/s**, peaking at ~70% through (judgement).
- **Low speed:** turning authority is poor. It needs sculling (RRS 42 guide).
- **Seed:** turn rate ∝ speed up to ~30°/s at planing speed, with a floor of ~5°/s near stopped (judgement).

---

## 7. Execution skills and what they're worth

| Skill | Worth | Source |
|---|---|---|
| Crew skill overall (same rig, 10 kn) | Olympic vs club light crew: 10.3 vs 8.3 upwind (−20%), 15.7 vs 12.0 downwind (−24%) | S3 p. 45 |
| Crew weight above the design wind | +15% "through all the tack range" (175 vs 150 kg) | S3 p. 44 |
| Gybe technique | Slow "VMG" gybe 8 m vs fast turn 10 m: 2 m per gybe, ×2.5–3 gybes per leg ≈ 5–6 m per leg, plus better exit position | S7, S1 |
| Kite set order | "set the spinnaker first then get the crew out … the boat will move very quickly to high VMGs". Getting on the wire first gives "an aggravated round up and slowing" | S5 §5.6 |
| Bear-away in a breeze | Fast and positive. A slow arc gives nose-diving and a capsize ("twilight zone") | S5 §5.5 |
| Gust and lull steering downwind | Bear away in gusts, luff in lulls. This is the downwind groove skill | RRS 42 guide; Musto manual |
| Mode switching | A 1–2 kn puff flips high mode to low mode (FX) | Reineke |
| Heel control | ±5° is acceptable. At 15° "the reason you are at the back of the fleet is very obvious" | *Skiff Tips* |
| Roll tacks | Not a skiff skill in the ILCA sense. Heel to windward "will have rig drag assisting the rotation of the tack". Crew-first is the fastest tack. Forum: skiff tacks are 2 s faster *without* a roll when planing (low trust) | S5 §5.3; SA forum |
| Pumping | RRS 42 applies. Off the wind, 42.3(c) allows one pull per gust or wave to start planing or surfing, never on a beat. Class rule changes 42.3(j) to allow sculling that doesn't propel. Repeated main pumps are allowed only to re-invert battens. Breaches "occur in the 4–8 knot wind range". Rocking to get going after the gate is prohibited | [RRS 42 guide 2022](http://web.archive.org/web/20260213075645/https://49er.org/wp-content/uploads/2024/03/2022-03-RRS-42-Guide-49er-49erFX.pdf); [2014](https://www.sailing.org/tools/documents/Rule4249er2014-%5B16132%5D.pdf) |

**For #220/#222 (judgement):**

- The biggest levers are the **downwind groove and plane-keeping** (±20% of downwind speed), **gybe quality** (~2 m each) and **the kite set** (a bad hoist leaves the boat off the plane for several seconds).
- Pumping is worth something only in 4–8 kn and shouldn't be a speed source.

---

## 8. Suggested seed polar (BSP in knots)

### Values

Rows 120, 140, 145 and 155 are added to the ILCA shape because the downwind groove falls between 135 and 165. With linear interpolation in TWA, the best-VMG angle can only land on a row.

| TWA \ TWS | 0 | 4 | 6 | 8 | 10 | 12 | 14 | 16 | 20 | 25 |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| 30 | 0.0 | 1.8 | 2.6 | 3.3 | 3.9 | 4.2 | 4.5 | 4.6 | 4.7 | 4.7 |
| 35 | 0.0 | 2.5 | 3.8 | 4.8 | 5.6 | 6.1 | 6.4 | 6.6 | 6.7 | 6.7 |
| 40 | 0.0 | 3.2 | 4.7 | 5.9 | 6.9 | 7.5 | 7.9 | 8.2 | 8.3 | 8.3 |
| 45 | 0.0 | 3.8 | 5.3 | 6.6 | 7.9 | 8.6 | 9.1 | 9.4 | 9.6 | 9.6 |
| 52 | 0.0 | 4.5 | 6.0 | 7.4 | 8.8 | 9.6 | 10.2 | 10.6 | 11.0 | 11.2 |
| 60 | 0.0 | 5.0 | 6.7 | 8.4 | 9.8 | 10.8 | 11.5 | 12.1 | 12.9 | 13.4 |
| 75 | 0.0 | 5.3 | 7.2 | 9.1 | 10.6 | 11.6 | 12.4 | 13.1 | 14.3 | 15.3 |
| 90 | 0.0 | 5.4 | 7.5 | 9.5 | 11.0 | 11.8 | 12.8 | 13.7 | 15.2 | 16.5 |
| 110 | 0.0 | 5.4 | 7.8 | 10.4 | 12.4 | 13.9 | 15.1 | 16.2 | 17.8 | 19.0 |
| 120 | 0.0 | 5.5 | 8.0 | 10.8 | 12.8 | 14.4 | 15.6 | 16.8 | 18.3 | 19.4 |
| 135 | 0.0 | 5.1 | 7.9 | 10.9 | 12.8 | 14.8 | 16.0 | 17.1 | 18.6 | 19.5 |
| 140 | 0.0 | 4.6 | 7.5 | 10.7 | 12.6 | 14.6 | 15.9 | 17.0 | 18.5 | 19.3 |
| 145 | 0.0 | 4.2 | 6.9 | 10.1 | 12.3 | 14.2 | 15.6 | 16.8 | 18.3 | 19.1 |
| 150 | 0.0 | 3.8 | 6.2 | 9.2 | 11.8 | 13.8 | 15.2 | 16.3 | 17.9 | 18.7 |
| 155 | 0.0 | 3.5 | 5.6 | 8.3 | 11.0 | 13.2 | 14.6 | 15.8 | 17.6 | 18.3 |
| 165 | 0.0 | 3.1 | 4.9 | 7.0 | 8.9 | 11.6 | 13.1 | 14.6 | 16.6 | 17.6 |
| 180 | 0.0 | 2.8 | 4.2 | 5.6 | 7.0 | 8.4 | 10.0 | 11.5 | 13.0 | 15.0 |

Resulting best VMG, checked by script over the rows and over 1° linear interpolation in TWA:

| TWS | 4 | 6 | 8 | 10 | 12 | 14 | 16 | 20 | 25 |
|---|---|---|---|---|---|---|---|---|---|
| Upwind VMG @ TWA | 2.77 @ 52° | 3.75 @ 45° | 4.67 @ 45° | 5.59 @ 45° | 6.08 @ 45° | 6.43 @ 45° | 6.65 @ 45–46° | 6.79 @ 45° (6.83 @ 48° interp.) | 6.90 @ 52° (6.91 @ 54°) |
| Downwind VMG @ TWA | 3.61 @ 135° | 5.75 @ 140° | 8.27 @ 145° | 10.22 @ 150° | 11.96 @ 155° (11.98 @ 153°) | 13.23 @ 155° | 14.32 @ 155° | 16.03 @ 165° (16.07 @ 161°) | 17.00 @ 165° |
| Max BSP @ TWA | 5.5 @ 120° | 8.0 @ 120° | 10.9 @ 135° | 12.8 @ 120–135° | 14.8 @ 135° | 16.0 @ 135° | 17.1 @ 135° | 18.6 @ 135° | 19.5 @ 135° |

Every row is non-decreasing in TWS. Rows 30–45 are held flat from 20 to 25 kn (depowered).

### Provenance

Codes:

- **R**: race GPS leg VMG (S1) × 1.13 upwind or × 1.25 downwind.
- **C**: class race-officer table (S2), same factors.
- **W**: Watin measured (S3), used for shape and as an upper bound, with his TWS read as ~1.2× low.
- **B**: Bethwaite theoretical (S4), −10%, used for shape and angles.
- **M**: class or manufacturer claim (S6).
- **P**: PY cross-check (S11).
- **J**: judgement.

| TWA \ TWS | 0 | 4 | 6 | 8 | 10 | 12 | 14 | 16 | 20 | 25 |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | J | J | J | J | J | J | J | J | J | J |
| 30, 35, 40 | J | J | J | J | J | J | J | J | J | J |
| 45 | J | J (extrapolated) | R, C | R/C interpolated | R, C | R/W | R (FX × 1.14), C | M | M, C | J |
| 52 | J | J | J | J | J | J | J | J | J | J |
| 60, 75 | J | J | J | W shape | W | W | W → M | W → M | J | J |
| 90 | J | J | J | W, B shape | W | W | W, S10 | W, S10 | J, M | J, M |
| 110, 120 | J | J | J | B, W | W, B | W, B | W → J | J | J | J, M |
| 135–155 | J | R shape, J | R, C, B angle | R/C step, B angle | R, C, W angle | R, W angle | R (FX), C, B angle | C, B angle | C, J | J |
| 165, 180 | J | J | J | J | J, W | W, B | J | J | J | J, S10 |

Notes on the choices:

- **Row 0 is 0, and rows 30–40 are a no-go ramp** (0.5×, 0.72× and 0.88× of the 45° row). This keeps the upwind optimum at 45° from 6 to 20 kn.
- **The 52° row is set just below the 45° row's VMG.** It wins at 4 and 25 kn, where real boats sail wider (ILCA D8 precedent, and depowering in a breeze).
- **The downwind rows are built backwards from the groove VMG targets in §4.2.** The groove angle follows S4 and S3 (deeper with wind), not the race effective angles, which include losses. Peak BSP sits at 120–135°, where S3 and S4 put the fastest kite reaching.
- **The 90° row is two sails.** Two-sail reaching tops out near the S3 values (11–12 kn at 10–12 kn TWS). The kite rows (110 and deeper) take over from 110°. This reproduces S4's "hook" as a flat 90–110° segment, not a dip, so the autohelm doesn't find a false groove. If the spinnaker becomes a player input (#222), give 110–180° a two-sail variant at about 0.6–0.7× (S3's 105–115° values are ~0.5× the kite speeds).
- **In breeze, speeds stay under 20 kn** (forum: "rarely exceeds 20 kts downwind"). Gust peaks of ~25 kn (M) are above the steady polar on purpose.
- **By the lee (TWA > 180°):** no skiff data. An asymmetric kite collapses from behind (§4.3), so mirror with a **heavy penalty** (judgement: −10% per 5° by the lee, kite collapses past ~10°). By the lee is only used transiently during a windward hoist (S5).
- **Planing step:** 6 → 8 kn is the steepest downwind step (+2.5 kn VMG). If planing becomes a state (#245), the polar values at 8+ kn are the **on-plane** values. The off-plane branch at the same TWS is roughly the 6 kn column scaled by TWS (judgement).

---

## Sources

Primary and peer-reviewed:

- [Gutiérrez-Manzanedo et al. 2025, GPS to assess an Olympic regatta: 49er and 49erFX classes, *J. Navigation* 78](https://www.cambridge.org/core/journals/journal-of-navigation/article/gps-to-assess-an-olympic-regatta-49er-and-49erfx-classes/4336D8F027A475ED8F02CA438DC2A54B)
- [Watin 2007, *49er performance enhancement*, Bethwaite Design internship report (incl. Bethwaite Design theoretical polars and tow-test drag)](https://9eronline.com/library/49er%20Performance%20Enhancement%20Report%20by%20Simon%20Watin.pdf)
- [49er class, Sailing course times (race-officer table), DCJ v10, March 2019 (Wayback)](http://web.archive.org/web/20260213074636/https://49er.org/wp-content/uploads/2020/04/49er-speed-chart-1.pdf)
- [RRS 42 Guide 49er/49erFX, March 2022 (Wayback)](http://web.archive.org/web/20260213075645/https://49er.org/wp-content/uploads/2024/03/2022-03-RRS-42-Guide-49er-49erFX.pdf) and [2014 edition](https://www.sailing.org/tools/documents/Rule4249er2014-%5B16132%5D.pdf)
- [RYA Portsmouth Yardstick 2025](https://britishsailingteam.rya.org.uk/media/vc0bdum2/py_list_2025-1.pdf) and [limited-data list](https://britishsailingteam.rya.org.uk/media/5m4e1iyw/limited-data_pn_list_2025-1.pdf)
- [Richards et al., A wind tunnel study of the interaction between two sailing yachts (abstract only)](https://www.researchgate.net/publication/260753324_A_Wind_Tunnel_Study_Of_The_Interaction_Between_Two_Sailing_Yachts)

Manufacturer and class:

- [Ovington 49er Owner's Manual (US Sailing edition)](https://www.ussailing.org/wp-content/uploads/2020/08/49er-owner-manual.pdf)
- [49er.org, Design elements](https://49er.org/design-elements/)
- [49er.org, 49erFX](https://49er.org/49erfx/)
- [Mackay Boats, 49er](https://mackayboats.com/index.cfm/boats/49er/)
- [Mackay Boats, FX technical development](https://mackayboats.com/index.cfm/news/fx-technical-development/)
- [Musto Skiff User's Manual (Ovington)](https://mustoskiff.com/wp-content/uploads/2020/09/160629-Musto-Skiff-Users-Manual.pdf)
- [29er Owner's Rigging Manual](https://www.29erkv.de/downloads/29er_rigging_manual.pdf)
- [29er Coaching Manual](https://www.dinghyshop.dk/userfiles/file/tuningguides/29er_coaching_manual.pdf)
- [29er Best Practice Guide (UK class)](https://www.29er.org.uk/29ermedia/docs/29er%20Best%20Practice%20Guide-v1.pdf)
- [Julian Bethwaite, *Skiff Tips*](https://aus9ers.com.au/wp-content/uploads/2023/04/skiff-tips.pdf)

Coaching and analytics:

- [McBride Racing, 49er Squad Gybing Improvements](http://mcbrideracing.com/racing-alpha/2020/11/19/49er-squad-gybing-improvements)
- [Lindsay, A data-driven race-winning formula, *Sailing World*](https://www.sailingworld.com/how-to/a-data-driven-race-winning-formula/)
- [Reineke, How to find your speed mode, *Sailing World*](https://www.sailingworld.com/how-to/how-to-find-your-speed-mode/)
- [Horton & Powlison, The mechanics of mode, *Sailing World*](https://www.sailingworld.com/how-to/the-mechanics-of-mode/)
- [Speed & Smarts, Covering downwind](https://www.speedandsmarts.com/toolbox/articles2/articles/covering-downwind)
- [49er.org, Everything but standard sailing (Marseille 2019)](https://49er.org/everything-but-standard-sailing/)

Games, forums and unattributed:

- [Tactical Sailing, boats (49er polar image)](https://www.tacticalsailing.com/en/games-tips/boats)
- [boatdesign.net, Australian 18 or 49er polars](https://www.boatdesign.net/threads/australian-18-or-49er-polars.5288/)
- [16ft skiffs forum, How fast does your skiff go (403; search excerpt)](https://www.tapatalk.com/groups/16ftskiffs/how-fast-does-your-skiff-go-t300.html)
- [Sailing Anarchy, secret of upwind planing (search excerpt)](https://forums.sailinganarchy.com/threads/what-is-the-secret-of-upwind-planing.176174/)
- [Sailing Anarchy, 29er roll gybes and roll tacks (search excerpt)](https://forums.sailinganarchy.com/threads/29er-roll-gybes-and-roll-tacks.134001/)

## Gaps

1. **No 49er polar table exists, and the sources disagree by up to 1.6× downwind in light air.** The seed hangs on a race-to-polar factor borrowed from the ILCA write-up (×1.13 / ×1.25). Bethwaite's *High Performance Sailing* (2nd ed.), which reportedly has the 49er data, wasn't retrieved.
2. **Watin's wind is suspect.** It was read by hand from a RIB, is sometimes paired with gusts, and its direction came from a compass and feather. It is also a 2007 rig. The ×1.2 height correction is a hypothesis, not a measurement.
3. **Race data stop at 12 kn for the 49er and 15 kn for the FX.** Nothing measured covers 16–25 kn except the flat class table (control-limited) and FX sample rows without wind. The 16–25 kn columns are judgement plus M.
4. **No measured 49er tack loss, turn rate, standing-start acceleration or coasting.** The values in §6 are derived from tow-test drag, a manual's bear-away timing and one coach's gybe pair.
5. **No hoist or drop durations, and no measured kite-up threshold angle.** The 110–120° boundary comes from the shape of the designer's polar and a hole in Watin's scatter.
6. **No skiff wind-shadow measurement.** The direction (along the apparent wind) is sound. The length and strength are borrowed.
7. **No skiff by-the-lee data.** The penalty is judgement.
8. **Comparable classes add little.** No RS800, Musto Skiff or 29er polars were found, only handicaps and coaching. S1's mean wind per band is not reported.
9. **Digitising error.** S1 bar charts ±0.2 kn; S3 scatter ±0.5 kn and ±5°; S4 and S10 ±0.5 kn by eye.
10. **Not checked:** the 2025 study's supplementary data (if any); Paris 2024 SAP/World Sailing tracking archives (sapsailing.com), which could give per-leg speeds by wind for the current rig; and the full text of the Auckland YRU yacht-interaction paper.
