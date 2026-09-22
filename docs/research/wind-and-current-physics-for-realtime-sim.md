---
ticket: docs/wayfinder/tickets/06-wind-and-current-physics-for-realtime-sim.md
question: What lightweight, real-time-friendly models exist for wind shifts, puffs and lulls, shoreline and land effects, tidal current across a venue and over a cycle, and wind against tide, and how do other sailing sims approximate them?
date: 2026-09-22
---

# Wind, current and shoreline physics for a real-time sim

Research for wayfinder ticket 06. It feeds the wind-model and current-model design tickets. Terms follow [`CONTEXT.md`](../../CONTEXT.md): puff and lull, wind shift, lift and header, current, venue.

## TL;DR

- Real-world numbers exist for everything the game needs. The most useful ones come from Bethwaite, Walker and Dellenbaugh (coaching), NOAA and Bowditch (tides), and USDA windbreak research (shadow behind land). The numbers are summarised in the parameter table in section 8.
- **Every effect can be a pure function `wind(x, y, t)` / `current(x, y, t)`**: a sum of sines for fleet-wide shifts, advected coherent noise or hash-seeded puffs for puffs and lulls, a precomputed coarse grid (or distance-to-shore field) for terrain effects, and a sinusoid times a static spatial pattern for tidal current. None of these needs a fluid solver.
- **Cost doesn't matter for boats.** A deliberately heavy sample (3 sines, 3 octaves of noise, 16 puffs, a bilinear grid lookup and 24 shoreline segments) measured **~127 ns per sample** on an Apple M1 (benchmark in section 9). 20 boats at 60 Hz is 1,200 samples/s, or about **0.15 ms of CPU per second**. The real budget is **drawing** the wind on the water (thousands of samples per frame) and **determinism** between client and server.
- **The most important design constraint is that the model is stateless and seeded.** It should be a pure function of `(seed, t, position)`, so client prediction and the authoritative server agree without streaming wind state. The current `WindField` keeps a mutable puff list that depends on RNG draw order, which works against this.
- **No commercial sim publishes its inshore model.** Sailaway drives wind from real GRIB weather data and has no local terrain wind. VR Inshore shows puffs, shifts and boat wind shadow, but its internals aren't public. eSail documents shifts veering 15 to 20° in gusts, terrain bending within a few hundred metres of shore, and funnelling between islands. The only inspectable sim found is open-source True Wind, which uses advected elongated noise puffs, sine oscillations and a land-shelter recovery term. Its code agrees with the structure recommended here.

---

## 1. Oscillating and persistent wind shifts

### Real-world values

| Quantity | Value | Source |
|---|---|---|
| Oscillation period (convective rolls) | ~3 min in heavy air to 10+ min in light-medium air | Bethwaite and Walker, summarised by [SailZing](https://sailzing.com/spectrum-of-the-wind/) |
| Oscillation amplitude (full range) | ~5° light-medium air, up to 40° heavy air | same |
| Rolls form when | wind > ~8 kn | same |
| Walker's working definition of "oscillating" | shifts of at least 15 to 20°, back and forth at least every 3 to 8 min | Walker, *The Sailor's Wind*, via [search summary of Walker](https://archive.org/details/sailorswind00walk) |
| Sea-breeze short-phase oscillation | ±5 to 7° every 2 to 3 min | [Yachting World](https://www.yachtingworld.com/homepage/understanding-and-making-the-most-of-sea-breezes-163811) |
| Sea-breeze long-phase oscillation | up to 40°, period 15 to 20 min (Rio example) | same |
| Persistent sea-breeze veer | ~5°/h (southern US) to ~10°/h (northern US) | [Dellenbaugh, Speed & Smarts](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/upwind-strategy); [Ed Adams, Sailing World](https://www.sailingworld.com/how-to/four-ways-to-win-the-offshore-breeze-game/) |
| Backdoor sea breeze | arrives in pulses of 10 to 15° rather than a smooth veer | Ed Adams, same |
| Oscillating-persistent | oscillation around a mean that itself drifts one way | Walker, via Speed & Smarts |
| Wind speed "quick peaks" | ±7% every 6 to 12 s | Bethwaite via SailZing |

Classification (Dellenbaugh): in an oscillating breeze, the close-hauled headings swing between upper and lower limits. In a persistent breeze, they drift steadily one way. Racers log headings every 1 to 2 min for about an hour to tell which it is. So a game can offer both regimes as tunable venue or race parameters, and tacticians will recognise them.

### Model: sum of sines plus a ramp (closed form)

```
θ(t) = θ0
     + A1·sin(2π t/T1 + φ1) + A2·sin(2π t/T2 + φ2)   // oscillation; T2/T1 irrational-ish so it never looks periodic
     + A3·sin(2π t/T3 + φ3)                           // optional slow "long phase"
     + ω_p · t                                        // persistent veer/back, rad/s (0 for pure oscillating)
     + Σ steps: Δk · smoothstep((t - tk)/τk)          // optional discrete persistent pulses (backdoor breeze)
```

- Real-time defaults (unscaled): T1 = 240 to 480 s, A1 = 5 to 10°, T2 ≈ 0.37·T1, A2 ≈ 0.5·A1. Persistent ω_p = 5 to 10°/h in a real sea breeze, which is too slow to notice in a short game race (see time compression below).
- **Time compression is a design decision, not a physics one.** A real race is 45 to 60 min, while a mobile race is likely 5 to 10 min. To keep the tactical texture ("two or three shifts per beat"), periods have to scale by roughly race-length ratio (e.g. real 4 to 8 min becomes 60 to 120 s in-game) while amplitudes stay real (5 to 20°). The existing `Wind.swift` does this already (7° at 90 s plus 4° at 37 s). A persistent shift over a compressed race has to be exaggerated similarly (e.g. 10 to 20° over the race rather than per hour).
- Alternative: 1-D coherent noise (value or Perlin noise in t) instead of sines. It's less predictable, but players can't learn a rhythm, and rhythm is part of real oscillating-shift tactics. Sines with 2 or 3 incommensurate periods are the standard trick, and they're cheapest.
- Spatial variation of shifts (left/right side of the course getting the shift first) can be a phase that depends on position: `φ(x,y) = k · (p · d̂_wind) / c_adv`, so a shift *arrives* from upwind at advection speed c_adv, plus a small cross-course term. This is what makes "sail towards the next shift" meaningful.

Cost: 2 to 4 `sin` calls per sample, about tens of ns.

---

## 2. Puffs and lulls: size, speed, lifetime, fan-out

### Real-world values

| Quantity | Value | Source |
|---|---|---|
| Coverage | the surface is roughly 50% gust, 50% lull at any time | Bethwaite via [SailZing](https://sailzing.com/spectrum-of-the-wind/) |
| Gust size | 100 to 200 m across the wind at 10 to 12 kn; about double at 20 kn | same |
| Gust repetition at a point | ~60 s average | same |
| Gust lifetime on the water | 2 to 4 min | same |
| Gust strength | +30 to 40% over mean | same |
| "Surges and fades" (larger scale) | +10 to 20%, 500 to 2,000 m on small waters (1 to 5 km on Sydney Harbour), last 2 to 12 min, drift at ~¼ wind speed | same |
| Gust direction | NH gusts veer (clockwise), SH gusts back. eSail docs cite 15 to 20° | [eSail wind page](https://www.esailyachtsimulator.com/the-world-of-esail/wind/) |
| Counter-evidence on gust direction | Met Office boundary-layer data (Brettle) found gust direction changes roughly normally distributed around zero | [Dagley, Sailing World](https://www.sailingworld.com/how-to/mysteries-of-the-shoreline-wind/) |
| Physical cause of veer | surface wind is backed from the wind aloft by friction (~10° over sea, ~30° over land), so air mixed down from aloft arrives veered (NH) | [PSU METEO 3](https://courses.ems.psu.edu/meteo3/node/2226); [ATPL surface-wind rules](https://www.examcopilot.com/subjects/meteorology/wind/surface-wind-calculations) |
| Fan-out | a mixing puff descends and spreads from its centre in a fan. Boats right of centre get a leftward shift and boats left of centre get a rightward one (downwind-looking). It shows as a half-moon shape advancing downwind | [Sailing World, "Understanding how puffs work"](https://www.sailingworld.com/how-to/understanding-how-puffs-work/) |
| Header or lift on entry | puff crossing your bow tends to header you, and crossing behind tends to lift you | [Dellenbaugh](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/upwind-strategy) |
| Puff track | often at a slight angle to the mean wind, steered by the wind aloft or geography | Sailing World (puffs) |

The veer rule is contested (Walker and eSail say gusts veer, and Brettle's data shows no bias). A game can reasonably pick a small mean veer (0 to 5°) plus the geometric fan-out, which *is* agreed on.

### Model A: explicit puff "particles" (Lagrangian), like the current `WindField`

Each puff is a disc or ellipse with centre `c(t) = c0 + v_adv·(t − t0)`, radii `(a_along, a_cross)`, strength `s(t) = S·sin(π·age/L)` (fade in and out), and falloff `f = (1 − d²)²` for `d < 1`.

Add **fan-out** as a divergent direction field inside the puff, which is cheap and gives the correct lift and header geometry:

```
r = p − c                                 // vector from puff centre
radial = r / max(|r|, ε)
fan    = β · f(d) · (radial · ŵ⊥)          // ŵ⊥ = unit cross-wind vector
Δθ     = fan · γ_max                       // γ_max ≈ 10–15° at the puff's edge
Δv     = S · f(d)
```

In words, the wind inside the puff points slightly *outwards* from its centre. A boat on the right half sees a shift one way and on the left half the other way. This is a standard radial-outflow (downburst) shape, and ~10 extra flops.

Suggested parameters (real, before any time compression): cross-wind diameter 100 to 200 m (scale with wind speed), along-wind 1.5× cross (True Wind uses ~260 m by 170 m noise scales), strength +30% gust and −20% lull, lifetime 120 to 240 s, spawn rate chosen for ~50% coverage, advection 0.7 to 1.0× mean wind for gusts and ~0.25× for large surges and fades.

The current code uses 35 to 90 m radius, 40 to 90 s life and 0.35× drift. That's compressed or small relative to Bethwaite's numbers. This may be right for a phone-sized course, but it should be an explicit scaling choice in the wind ticket.

**Making it stateless:** don't keep a mutable array that depends on RNG draw order. Instead, divide space-time into cells (e.g. a spawn cell of 200 m × 200 m × one lifetime, in the frame moving with the mean wind). Each cell hashes `(seed, i, j, k)` to decide whether it holds a puff and where. To sample at `(p, t)`, visit the 3×3 (×2 in time) neighbouring cells. That makes ~18 hash evaluations plus ≤ ~4 live puffs per sample, and it's a pure function. The approach is the same as Worley or cellular noise.

### Model B: advected coherent noise (Eulerian)

```
q = R(θ_mean) · (p − v_adv·t)            // advect with mean wind
n = Σ_o a_o · noise(q.x/Lx_o, q.y/Ly_o, t/τ_o)   // 2–3 octaves; Lx ≈ 1.5·Ly for elongation
speed = U · (1 + g·shape(n))              // shape: asymmetric, puffs sharper than lulls
dir   = θ + κ·g·n                          // puffs veer slightly
```

True Wind (open source) does exactly this: `noise2(along/260, cross/170, …)`, advected at 0.9× mean wind, with asymmetric shaping (`n>0 ? 1.35n : 0.75n`), amplitude 0.42, and a puff veer of ~7° × strength ([env.js](https://raw.githubusercontent.com/hclivess/truewind/main/js/env.js)). Noise can't express fan-out directly. The gradient of the noise field (simplex noise gives it analytically, per [Gustavson](https://cgvr.cs.uni-bremen.de/teaching/cg_literatur/simplexnoise.pdf)) can supply a divergent direction perturbation: `Δθ ∝ ∇n · ŵ⊥`.

**Choosing:** Model A gives discrete, readable puffs that a player can see coming and call, which suits an accessible sim and matches the glossary's "patch moving down the course". Model B looks more natural and is trivially stateless. A hybrid is common: B at low amplitude as background texture, plus A for the tactically meaningful puffs.

---

## 3. Shoreline effects: bending, acceleration, convergence and divergence

### What the sources say

- **Corner effect (headlands):** wind accelerates and bends around headlands and island ends. Sailor-facing guides cite ~30° of bending and speeds up to about double locally ([sailing-around.com](https://sailing-around.com/reading-the-wind/)). This is a secondary source, and no Met Office figure was found. eSail models directional change "within several hundred metres of shore" and funnelling between islands ([eSail](https://www.esailyachtsimulator.com/the-world-of-esail/wind/)).
- **Coastal convergence and divergence:** friction over land backs and slows the wind relative to over the sea (crossing angle ~30° over land vs ~10° over sea, per [PSU METEO 3](https://courses.ems.psu.edu/meteo3/node/2226)). When wind blows roughly *along* a coast, this piles air up on one side (convergence: stronger) and spreads it on the other (divergence: lighter). NH rule of thumb: convergence (more wind) where the land is on your **left** looking downwind, and divergence where land is to your right facing upwind ([Sailing World, Dagley](https://www.sailingworld.com/how-to/mysteries-of-the-shoreline-wind/); [EUMETrain coastal convergence](https://resources.eumetrain.org/satmanu/CMs/CoConv/print.htm)). Onshore wind generally converges at the coast and offshore wind diverges.
- **Refraction towards perpendicular:** an offshore breeze tends to bend towards crossing the shore at 90° as it leaves (Watts 1965; Melges, Dellenbaugh). Dellenbaugh says wind "blows more perpendicularly off the shore", with less wind and more shiftiness close in ([Speed & Smarts](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/upwind-strategy)).
- **The direction of shoreline bending is disputed.** Dagley lists four incompatible expert theories (towards perpendicular, left, right, or depends on sea temperature), and notes met studies only resolve tens of miles, not the couple of miles a racecourse covers ([Sailing World](https://www.sailingworld.com/how-to/mysteries-of-the-shoreline-wind/)). **Implication:** the venue designer should author shoreline effects per venue rather than derive them from one "physics" rule. That also suits fictional venues.
- Speed-up on leaving land: roughness drops from z0 ≈ 0.01 to 3 m over land to ≈ 0.0002 to 0.002 m over water. Wind speeds up offshore and, in NH, veers as it speeds up ([roughness figures](https://www.sciencedirect.com/science/article/abs/pii/S0167610504000819), [tdgil](https://tdgil.com/impact-of-the-land-on-the-wind/)).

### Model: distance-to-shore field plus authored modifiers, baked to a grid

Precompute per venue, offline or at load:

1. A **signed distance field** `D(p)` to the coastline (negative on land) and its gradient `n̂(p)` (outward shore normal). Bake it into a 2-D grid, e.g. 10 to 25 m cells. A 2 × 3 km venue at 20 m cells is 100 × 150 = 15k cells.
2. For the venue's handful of **prevailing wind directions** (e.g. every 15°, or only the few the venue uses), bake a **terrain modifier grid** `M_θ(p) = (speedFactor, Δdirection)`:
   - **Refraction near an offshore shore:** `Δθ = −k_r · e^{−D/L_r} · angle(ŵ, n̂)`, which pulls the wind towards the shore normal, with L_r ≈ 200 to 500 m and k_r ≈ 0.3 to 0.5.
   - **Convergence and divergence along a shore:** `speedFactor += ±k_c · e^{−D/L_c} · (ŵ · t̂)`, with sign by which side the land is (NH rule above), k_c ≈ 0.1 to 0.2 and L_c ≈ 300 to 1,000 m.
   - **Corner or headland jet:** an authored Gaussian blob at each headland tip, with speed ×1.2 to 1.5 (up to ×2 on a steep headland) and Δθ of up to ~30° following the coast curvature, radius ≈ a few hundred metres.
   - **Wind shadow from land (lee):** see section 4.
3. At run time: `wind = base(t) ⊕ puffs ⊕ bilinear(M_θ nearest two directions, p)`. For shifting wind, interpolate between the two baked directions bracketing the current mean direction.

A cheaper alternative is to skip baking and evaluate a handful of **authored analytic features** (headland blobs, shoreline polylines with an effect band). At <30 features this is well under 1 µs per sample (section 9). Baking only helps if features get numerous or you want an artist-painted map.

Heavier options (not recommended for runtime): a potential-flow solve (Laplace equation around the coastline) or a 2-D shallow CFD run offline to *generate* `M_θ` for authoring reference. Potential flow gives correct-looking acceleration around headlands and in gaps between islands (funnelling), and costs nothing at runtime once baked.

---

## 4. Wind shadow and lee from land

### Real-world values (windbreak research is the best-quantified proxy)

| Zone (downwind of an obstacle of height H) | Effect | Source |
|---|---|---|
| 2H to 5H | greatest reduction | [USU Extension windbreak fact sheet](https://extension.usu.edu/forestry/publications/utah-forest-facts/005-windbreak-benefits-and-design); [USDA NRCS](https://www.nrcs.usda.gov/sites/default/files/2022-10/using_windbreak_for_odor_mgmt_0.pdf) |
| up to 10H | practical, still-significant reduction | same |
| up to 30H | measurable reduction | same |
| upwind 2H to 5H | measurable reduction ahead of the obstacle | same |

Other references: True Wind's design note is that land upwind shelters the wind, and it recovers "over roughly a kilometre of open water" ([True Wind README](https://github.com/hclivess/truewind)). Ed Adams notes an artificial "wind wedge" off a shoreline can extend a mile or more offshore ([Sailing World](https://www.sailingworld.com/how-to/four-ways-to-win-the-offshore-breeze-game/)). Dellenbaugh says there is less wind and it's "squirrelly" near a windward shore.

Porosity matters: a dense solid obstacle (cliff, buildings) gives a deeper deficit and a recirculation bubble just behind it. A porous one (trees) gives a shallower but longer shelter ([USDA density rules of thumb](https://www.fs.usda.gov/nac/assets/documents/agroforestrynotes/an36w03.pdf)).

### Model: upwind ray-march fetch, baked

For each water cell and baked wind direction, march upwind to find the nearest land and its authored height `H` (and porosity). Then:

```
x = distance downwind from the land edge (m);  X = x / H
deficit(X) = d_max · exp(−X / X_e)            // d_max ≈ 0.6–0.8 for solid, 0.3–0.5 porous; X_e ≈ 8–10
speedFactor = 1 − deficit(X)                   // ≈ 20% residual deficit by 10H, ~5% by 30H with X_e≈10
gustiness  += k_t · exp(−X / 15)              // shelter zone is also more turbulent/shifty
Δθ         += ±random-but-seeded shift amplitude scaled by the same envelope
```

`d_max · exp(−X/10)` with d_max = 0.7 gives ≈ 0.26 at 10H and ≈ 0.035 at 30H, which matches the 10H/30H bands above. For a 20 m tree line, that's shelter out to ~200 m and a trace to 600 m. For a 50 m bluff, it's ~500 m and ~1.5 km, consistent with True Wind's "~1 km recovery". Bake it into the same grid as section 3. Per sample at runtime it's one bilinear lookup.

---

## 5. Tidal current across a venue and over a cycle

### Real-world values

| Quantity | Value | Source |
|---|---|---|
| Dominant period (semidiurnal, M2) | 12 h 25 min (two peaks per 24 h 50 min) | [NOAA harmonic constituents](https://tidesandcurrents.noaa.gov/about_harmonic_constituents.html) |
| Full prediction | `h = H0 + Σ f·H·cos(a·t + (V0+u) − κ)`, the sum of up to 37 cosines | same |
| Reversing (rectilinear) vs rotary | rivers and estuaries reverse. Open coast rotates through the compass | [NOAA currents tutorial](https://oceanservice.noaa.gov/education/tutorial_currents/02tidal1.html); [Blue Water Sailing](https://www.bwsailing.com/cc/2015/07/understanding-rotary-currents/) |
| Slack | seconds to several minutes, roughly near high or low water (varies by site) | NOAA tutorial |
| Spring vs neap | stronger at new and full moon, weaker at quarters | NOAA tutorial |
| Speed through the cycle | 50/90 rule: 0, 50, 90, 100, 90, 50, 0% of max at each hour from slack. That is a sine: sin 30° = 0.5, sin 60° = 0.87 | [Starpath / Burch](http://davidburchnavigation.blogspot.com/2012/03/starpath-50-90-rule.html); [Waterproof Charts](https://waterproofcharts.com/rules-of-thumb-for-tides-5090-thirds-twelfths/); Bowditch ch. 11 (Table 3 of the tidal current tables interpolates on the same curve) |
| Across the venue | strongest in deep water or channels, weaker in shallows and near shore (bottom friction) | [Dellenbaugh, "Current"](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/current); [PBO](https://www.pbo.co.uk/seamanship/nav-in-a-nutshell-coping-with-currents-27019) |
| Turn of tide | **changes first along the shore, later mid-channel**. E.g. SF Bay at 1 to 2 kn ebb near shore while mid-bay still floods at 2 to 3 kn | Dellenbaugh, "Current" |
| Headlands | current strongest around prominent points and in narrow openings, with back eddies on the down-current side of islands, shoals and points | Dellenbaugh; [PBO tidal races](https://www.pbo.co.uk/seamanship/tidal-races-overfalls-and-headlands-how-to-prepare-for-challenging-waters-96455) |
| Typical inshore rates | 1 to 3 kn in major waterways (0.5 to 1.5 m/s) | Dellenbaugh |
| Eddy regime | shallow tidal wakes are governed by KC = U0·T/D and a stability number S. S ≳ 0.1 gives a steady recirculation bubble, 0.06 to 0.1 an unsteady bubble, ≲ 0.06 vortex shedding | [arXiv 1902.00222](https://arxiv.org/abs/1902.00222); see also Wolanski et al. 1984 ([JGR](https://agupubs.onlinelibrary.wiley.com/doi/10.1029/JC089iC06p10553)), Signell & Geyer 1991 ([JGR](https://agupubs.onlinelibrary.wiley.com/doi/abs/10.1029/90jc02029)) |
| Depth dependence | Manning: `V = (1/n)·R^{2/3}·S^{1/2}`. For the same surface slope, speed ∝ depth^{2/3} | [Manning equation](https://en.wikipedia.org/wiki/Robert_Manning_(engineer)); [h2ometrics](https://h2ometrics.com/manning-equation/) |

### Model: separable pattern × tide phase, with per-cell phase lead

```
current(p, t) = Σ_modes  P_m(p) · A_m · sin(ω t + φ_m − δ(p))       // usually 1 mode (M2) is enough
ω       = 2π / (12.42 h · timeScale)
P_m(p)  = baked 2-D vector field (flood direction and relative magnitude); ebb = −P for reversing,
          or use two orthogonal patterns in quadrature for rotary: P_a·cos(ωt) + P_b·sin(ωt)
δ(p)    = phase lead in shallows: δ = δ_max · (1 − depthNorm(p)),  δ_max ≈ 15–45 min of tide (scaled)
```

**Building `P(p)` for a fictional venue** (offline, cheap):

1. Author a depth map (coarse grid, or channel polylines with widths and depths).
2. Magnitude ∝ `h^{2/3}` (Manning), normalised so the channel centre is 1.0.
3. Direction: follow the channel axis, or the gradient of a stream function. For a no-crossing-the-shore guarantee, solve a 2-D potential-flow or stream-function Laplace problem once, weighted by depth (`∇·(h u) = 0`). This handles speed-up through gaps and around points by continuity (speed ∝ 1/width).
4. **Headland eddies:** in shallow racing waters with a sizeable headland, friction dominates (large S), so a **steady recirculation bubble** is the realistic regime. Model it as an authored Rankine vortex on the down-current side, whose strength follows the tide: `u_eddy = Γ(t)/(2π r)` outside the core radius `r_c` and solid-body rotation inside. `Γ(t) ∝ max(0, sign-matched tide(t))` so the eddy only appears on the side downstream of the current and flips sides when the tide turns. Radius ≈ 0.5 to 1× headland length. Recirculation speed ≈ 20 to 40% of the free-stream current.
5. Bake to a grid (20 to 50 m cells is plenty for current), then bilinear sample at runtime.

**Over one race:** a 10 min in-game race without time compression spans ~1.3% of an M2 cycle, so current is nearly constant. That's fine as a "this race's tide", but the *turn* of the tide (shore-first) is one of the best tactical features. To show it in a short race, start the race near slack and compress tide time, e.g. timeScale so that slack-to-max takes 5 to 15 minutes. The wind design ticket and current ticket need to agree on a single game-time scale.

---

## 6. Wind against tide and effects on boat speed

Two separable effects:

1. **Kinematic (exact, and it must be in the sim):** a boat's sails and foils work relative to the *water*. The "sailing wind" a boat feels is `w_sail = w_true_over_ground − c` (current vector `c`). Boat velocity through water comes from the polar at `(|w_sail|, angle)`, and ground velocity = `v_through_water + c`. So wind against tide *increases* the wind the boat sails in, and wind with tide decreases it. A cross-current also rotates the sailing wind, so a current gradient across the course produces apparent shifts and velocity changes. Dellenbaugh calls this current-generated wind ([Speed & Smarts, "Current"](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/current)). Cost: one vector subtraction. This also gives current "lee-bowing" effects for free.
2. **Sea state (approximate):** an opposing current shortens and steepens wind waves, since frequency is conserved while phase speed relative to ground drops. Waves can grow sharply and break near headlands, bars and entrances ([Canadian Hydrographic Service, tidal phenomena](https://tides.gc.ca/en/tidal-phenomena); [PredictWind glossary](https://www.predictwind.com/glossary/w/wind-against-current); [PBO tide races](https://www.pbo.co.uk/seamanship/tidal-races-overfalls-and-headlands-how-to-prepare-for-challenging-waters-96455)). No source gives a dinghy speed-loss number. A reasonable game model is a **chop penalty** on upwind VMG:

```
opp   = max(0, −ŵ · c) / c_ref              // opposing-current component, c_ref ≈ 1 m/s
chop  = clamp(k_w · |w| · opp, 0, 1)         // more wind × more opposing current = worse chop
speedFactor_upwind = 1 − chop · (0.05 … 0.12) // mild; also raise helm noise / reduce pointing
```

That's cheap. It's a tunable rather than physics, and it can be restricted to authored "tide race" zones so it stays readable.

---

## 7. How other sims approximate these

| Sim | Wind source and model | Local and terrain effects | Current | Source and confidence |
|---|---|---|---|---|
| **Sailaway** (Orbcreation) | Real-world weather GRIBs (GFS-like), regionally averaged. Players report offline mode lacks gusts and shifts, and some describe speed and direction as regular sine waves | Not local. Players note it's "modelled regionally … not locally" | Not documented | Steam discussions ([1](https://steamcommunity.com/app/552920/discussions/0/1495615865224372851/), [2](https://steamcommunity.com/app/552920/discussions/0/2132869574255107043/)). Player reports, no dev write-up found |
| **Virtual Regatta Inshore** | Scripted race wind with puffs, lulls and shifts shown on the "course radar" (windsocks, shading). Boat wind shadow is shown as a cone and is long on fast boats (Nacra) | Not documented | Not documented | [App Store listing](https://apps.apple.com/us/app/virtual-regatta-inshore/id1182301199), [NW Yachting](https://www.nwyachting.com/virtual-racers/). Forum and help pages returned 403. Internals unpublished |
| **VR Offshore** | GRIB (NOAA GFS) interpolated in space and time | n/a (ocean scale) | none | [VR help center "Wind variations"](https://virtualregatta.zendesk.com/hc/en-us/articles/115001602954-Wind-variations) (403 during research; known from the title/listing only) |
| **eSail** | Variable speed and direction. Gusts veer (NH) 15 to 20°. Moving pressure systems. Patchy sea-breeze puffs | Bending around islands and headlands within several hundred metres of shore, and funnelling between islands | not addressed | [eSail wind page](https://www.esailyachtsimulator.com/the-world-of-esail/wind/) (developer docs) |
| **Tactical Sailing** (trainer) | Preset wind "fields" in grids from 1×1 to 8×8 cells, with lulls, puffs, oscillating and persistent shifts. Polar-driven boats | grid-authored | n/a | [tacticalsailing.com](https://www.tacticalsailing.com/en/games-tips/spiel-gegen-den-wind) |
| **SAILSHIFT** (trainer) | 4 preset shift patterns plus manual direction | none | none | [itch.io devlog](https://xgl100.itch.io/sailshift/devlog/587813/tutorial) |
| **SailX / board games** | Discrete shifts and a one-cell wind shadow per boat | none | none | [Sail the Wind rules](https://konstantint.github.io/sail-the-wind/rules.html). Minimal |
| **True Wind** (open source, browser) | Two sines (T1 180 to 300 s, T2 60 to 110 s, amplitude 8°) plus spatial noise. Puffs are advected elongated noise (260 m × 170 m) at 0.9× wind, +42% amplitude, ~7° veer | Land shelter recovering over ~1 km | Static field with a tanh cross-gradient (±25% over 400 m), no tide cycle | [README](https://github.com/hclivess/truewind), [env.js](https://raw.githubusercontent.com/hclivess/truewind/main/js/env.js). Hobby project, but readable code |

**Takeaway:** the commercial inshore titles show the *effects* (visible puffs, shifts, shadow cones) without publishing or apparently simulating terrain physics. Trainers use authored grids. The one inspectable sim uses the same toolkit recommended here. There's no evidence any mobile sailing game models tidal-current eddies or shore-first tide turns, which could set Regatta apart.

---

## 8. Consolidated parameter table (real-world, before time compression)

| Parameter | Suggested default | Range | Basis |
|---|---|---|---|
| Oscillation period T1 | 300 s | 180 to 600 s (heavy to light air) | Bethwaite, Walker |
| Oscillation amplitude (± half-range) | 6° | 3 to 20° | Bethwaite, Walker, YW |
| Secondary period T2 | 0.37·T1 | — | incommensurate, anti-periodic |
| Persistent veer (sea breeze) | 7°/h | 5 to 10°/h, or 10 to 15° pulses | Dellenbaugh, Adams |
| Puff cross-wind size | 150 m @ 11 kn, ∝ wind speed | 100 to 400 m | Bethwaite |
| Puff along-wind size | 1.5 × cross | 1 to 2 × | True Wind, "elongated" |
| Puff strength | +30% | +20 to 40% | Bethwaite |
| Lull strength | −20% | −10 to −30% | inferred (50/50 coverage) |
| Puff lifetime | 180 s | 120 to 240 s | Bethwaite |
| Puff advection | 0.8 × mean wind | 0.7 to 1.0 (gusts), 0.25 (surges) | True Wind, Bethwaite |
| Puff fan-out edge shift | ±10° | 5 to 15° | geometric, coaching |
| Puff mean veer (NH) | +3° | 0 to 15° | contested (Walker/eSail vs Brettle) |
| Quick speed jitter | ±7%, 6 to 12 s | — | Bethwaite |
| Shore refraction band | 300 m | 200 to 500 m | Dellenbaugh, eSail |
| Headland corner speed-up | ×1.3 | ×1.2 to 2.0 | secondary sources |
| Headland corner bend | 20° | up to 30° | secondary sources |
| Convergence/divergence | ±15% | ±10 to 20% | EUMETrain, coaching (magnitude a judgement) |
| Land shadow | `0.7·exp(−x/(10H))` | d_max 0.3 to 0.8 | USDA windbreak 2 to 5H / 10H / 30H |
| Max tidal current | 0.75 m/s (1.5 kn) | 0.25 to 1.5 m/s | Dellenbaugh |
| Tide curve | `sin` from slack (50/90 rule) | — | NOAA, Bowditch |
| Shallows speed | ∝ depth^{2/3} | — | Manning |
| Shore phase lead | 30 min real | 15 to 60 min | Dellenbaugh (SF Bay) |
| Headland eddy speed | 0.3 × free stream | 0.2 to 0.4 | judgement (regime from arXiv 1902.00222) |
| Chop penalty upwind | 8% at full chop | 5 to 12% | judgement, no source |

"Judgement" rows are not sourced numbers. Tune them in playtests.

---

## 9. Cost and determinism

### Measured cost

A deliberately heavy sample function (a throwaway, uncommitted benchmark, compiled `swiftc -O` on an Apple M1): 3 sines, 3 octaves of hashed value noise with advection, 16 puff discs, one bilinear 64×64 grid lookup, brute-force distance to 24 shoreline segments. Result: **127 ns per sample**.

| Scenario | Samples/s | CPU |
|---|---|---|
| 20 boats × 60 Hz, one wind plus one current sample each | ~2,400 | ~0.3 ms/s (0.03% of a core) |
| Same, plus 4 extra samples per boat for sail/hull extent or lookahead | ~6,000 | ~0.8 ms/s |
| Boat-to-boat wind shadow (cone test for every ordered pair) | 380 pairs × 60 = 22.8k tests/s | trivial (~tens of µs/s) |
| **Wind visualisation**: 32×56 grid of arrows or puff shading per frame at 60 fps | ~107k/s | ~14 ms/s (1.4% of a core). Sample at 10 to 15 Hz and interpolate, or evaluate on the GPU in a shader |
| Server: 500 concurrent races × 20 boats × 60 Hz | 1.2M/s | ~0.15 core |

Older iPhones (A12 or A13) are perhaps 1.5 to 2.5× slower than the M1 per core, but that's still negligible for the sim. **Cost doesn't limit model choice.** Pick for readability and determinism.

### Determinism requirements (the actual constraint)

- **Pure function of `(seed, t, p)`.** Server-authoritative netcode (per the map's framing) means clients predict locally and reconcile. If wind and current are pure functions of seed and sim time, the server sends only the seed and venue ID, and clients never need a wind snapshot. The current `WindField` mutates a puff array with RNG draws in `step()`, so a late-joining client or a rollback has to replay every step. The hashed-cell puff scheme (section 2) removes that.
- **Floating-point parity.** `sin`, `exp` and `pow` from Darwin libm and glibc aren't guaranteed bit-identical. If the server runs Linux x86 and clients run ARM iOS, results can differ in the last ulp and diverge through the boat integrator. Options: (a) the server is the only authority and clients just correct toward server state (the usual choice, where tiny divergence is harmless), or (b) implement your own polynomial `sin`/`exp` and avoid FMA contraction differences, or use fixed-point for the sim core. Decide in the netcode ticket. The wind model should avoid chaotic dependence on its own previous state, so a sample error never compounds.
- **Baked grids** must be generated deterministically (same code, same float order) or shipped as data files, so client and server read identical bytes.

---

## 10. Recommended composition (input to the wind and current tickets)

```
wind(p, t):
  θ   = θ0 + oscillation(t, phase(p)) + persistent(t)             // §1: 2–3 sines + ramp/pulses
  U   = U0 · (1 + jitter(t))                                       // ±7%, 6–12 s
  (s_t, dθ_t, gust_t) = bilinear(terrainGrid[θ bracket], p)        // §3–4 baked: refraction, convergence, corners, land shadow
  (s_p, dθ_p) = puffs(seed, p, t)                                  // §2: hashed-cell puffs with fan-out (+ optional low-amp noise)
  return polar(U · s_t · (1 + s_p), θ + dθ_t + dθ_p)

current(p, t):
  τ = tidePhase(t) − lead(p)                                       // §5: sine, shore-first turn
  return P(p) · Cmax · sin(τ) + eddies(p, τ)                        // baked pattern × scalar + authored Rankine eddies

boat:
  w_sail = wind(p,t) − current(p,t) − shadowFromOtherBoats(p)      // §6 kinematics
  v_water = polar(w_sail) · (1 − chop(w, c))                         // §6 sea-state penalty
  p += (v_water + current(p,t)) · dt
```

Open design questions this research raises for the downstream tickets:

1. **Game-time scale:** one factor for wind periods, puff lifetimes and tide phase, or separate ones?
2. **Shoreline bending rule:** authored per venue (recommended, given the expert disagreement) or a global rule?
3. **Puff visibility:** discrete, readable puffs (Model A) vs natural noise (Model B) vs a hybrid.
4. **Stateless wind:** adopt the hashed-cell puff scheme so the netcode ticket can rely on `(seed, t)` only.
5. **Current scope in v1.0:** a uniform-but-tidal current, or full spatial patterns with shore-first turns and eddies (a possible differentiator, since no competitor documents it).

## Sources

Meteorology and oceanography: [NOAA currents tutorial](https://oceanservice.noaa.gov/education/tutorial_currents/02tidal1.html) · [NOAA harmonic constituents](https://tidesandcurrents.noaa.gov/about_harmonic_constituents.html) · [Bowditch ch. 11](https://thenauticalalmanac.com/2024_Bowditch-_American_Practical_Navigator/Volume_2/09_Volume_2_Calculations_For_Navigation/Chapter_11_Tide_And_Current_Predictions.pdf) · [PSU METEO 3 surface wind](https://courses.ems.psu.edu/meteo3/node/2226) · [UBC ATSC 113 local winds](https://www.eoas.ubc.ca/courses/atsc113/sailing/met_concepts/10-met-local-conditions/10a-local-winds/) · [EUMETrain coastal convergence](https://resources.eumetrain.org/satmanu/CMs/CoConv/print.htm) · [Canadian Hydrographic Service](https://tides.gc.ca/en/tidal-phenomena) · [arXiv 1902.00222 shallow oscillatory wakes](https://arxiv.org/abs/1902.00222) · [Wolanski 1984](https://agupubs.onlinelibrary.wiley.com/doi/10.1029/JC089iC06p10553) · [Signell & Geyer 1991](https://agupubs.onlinelibrary.wiley.com/doi/abs/10.1029/90jc02029) · [USU windbreaks](https://extension.usu.edu/forestry/publications/utah-forest-facts/005-windbreak-benefits-and-design) · [USDA NRCS windbreak sheet](https://www.nrcs.usda.gov/sites/default/files/2022-10/using_windbreak_for_odor_mgmt_0.pdf) · [USDA windbreak density](https://www.fs.usda.gov/nac/assets/documents/agroforestrynotes/an36w03.pdf) · [Gustavson, Simplex noise demystified](https://cgvr.cs.uni-bremen.de/teaching/cg_literatur/simplexnoise.pdf)

Coaching literature: [SailZing on Bethwaite's spectrum of the wind](https://sailzing.com/spectrum-of-the-wind/) · [Speed & Smarts upwind strategy](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/upwind-strategy) · [Speed & Smarts current](https://www.speedandsmarts.com/toolbox/articles2/the-smart-course/current) · [Sailing World, how puffs work](https://www.sailingworld.com/how-to/understanding-how-puffs-work/) · [Sailing World, shoreline wind (Dagley)](https://www.sailingworld.com/how-to/mysteries-of-the-shoreline-wind/) · [Sailing World, offshore breeze (Adams)](https://www.sailingworld.com/how-to/four-ways-to-win-the-offshore-breeze-game/) · [Yachting World, sea breezes](https://www.yachtingworld.com/homepage/understanding-and-making-the-most-of-sea-breezes-163811) · [Starpath 50-90 rule](http://davidburchnavigation.blogspot.com/2012/03/starpath-50-90-rule.html) · [PBO currents](https://www.pbo.co.uk/seamanship/nav-in-a-nutshell-coping-with-currents-27019)

Sims: [eSail wind](https://www.esailyachtsimulator.com/the-world-of-esail/wind/) · [Sailaway Steam discussion](https://steamcommunity.com/app/552920/discussions/0/1495615865224372851/) · [VR Inshore App Store](https://apps.apple.com/us/app/virtual-regatta-inshore/id1182301199) · [Tactical Sailing](https://www.tacticalsailing.com/en/games-tips/spiel-gegen-den-wind) · [SAILSHIFT](https://xgl100.itch.io/sailshift/devlog/587813/tutorial) · [True Wind](https://github.com/hclivess/truewind)

Gaps: the VR Inshore and VR help-centre pages returned HTTP 403, so VR's internals come from store and press descriptions only. Headland corner speed-up figures come from secondary sailing guides, since no Met Office number was found. The chop penalty and eddy strength are unsourced judgement values.
