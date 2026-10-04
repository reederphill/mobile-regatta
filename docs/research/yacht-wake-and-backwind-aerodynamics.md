---
question: What do primary sources say about the wake (Wind shadow) of a sailing yacht (reach, width, deficit and turbulence decay, advection, deflection toward the centreline) and about Backwind on a boat to windward and astern (smooth deflection versus turbulence, sign, extent, scaling), and is there anything quantitative for dinghies, skiffs or fleet and match racing?
date: 2026-10-03
---

# Yacht wake and backwind aerodynamics

Research to ground the trail-of-turbulence model (#376) for the game's **Wind shadow** and **Backwind**, and to check three working hypotheses (a to c below). Terms follow [`CONTEXT.md`](../../CONTEXT.md). AWA is apparent wind angle, TWA true wind angle, h mast height, Lb boat length.

## TL;DR

- **The quantitative primary literature is thin.** The only openly readable sources I could retrieve and read in full were two conference papers from the University of Auckland Yacht Research Unit: [Richards et al. 2012](https://people.eng.unimelb.edu.au/imarusic/proceedings/18/279%20-%20Richards.pdf) (wind tunnel, two yachts) and [Norris and Durand 2016](https://people.eng.unimelb.edu.au/imarusic/proceedings/20/647%20Paper.pdf) (transient CFD, opposite tacks). Marchaj's books and the Chesapeake 2013 version of Richards were not retrievable. Everything attributed to Marchaj, Hooper, Caponnetto and Eiffel below is **second-hand through Richards et al. 2012**, and is marked so.
- **Wake direction:** the shadow lies along the **apparent** wind, not the true wind, then sits a few degrees further **astern** (about 5 degrees close-hauled, about 9 degrees on a spinnaker reach) because of lift on the sails. The big swing from true wind toward astern is boat-speed advection, not flow turning.
- **Reach:** a deficit that "can be felt for up to ten boat lengths" is Marchaj's statement, quoted by Richards. No measured decay curve with distance was found.
- **Backwind** is a real, mostly potential-flow effect (upwash from the other yacht's sails, a header for the boat to windward). Measured only for yachts passing on opposite tacks, where it is small (about 1 degree of AWA, drive loss gone by about 1 Lb) in a CFD model that the authors say does not match experience.
- **No decay-with-distance, stability, twist, dinghy, skiff or fleet-race data** was found in a primary source.

## 1. Wake of one yacht

### Direction: along the apparent wind

[Richards et al. 2012](https://people.eng.unimelb.edu.au/imarusic/proceedings/18/279%20-%20Richards.pdf) say outright that a common diagram (Johnson, "Racing Basics") puts the blanketing zone along the true wind, and that this is wrong: "while the wake is carried downwind the movement of the yacht means that it also drops behind", so "the blanketing zone should therefore be aligned with the apparent wind". Their wind tunnel data back this. With two similar models at AWA 20 degrees and 25 degrees heel (mast h = 2.25 m), the line of lowest drive force on a second yacht runs approximately along the apparent wind (their Fig. 4, Fig. 7).

The same paper reports a downwind case (AWA 60 degrees, TWA 145 degrees, asymmetric spinnaker): the apparent wind is then 85 degrees from the true wind, so "the main affected region lies across the true wind rather than in-line with it". They warn that race animations showing downwind dirty air in line with the true wind are wrong, and that only a flat-plate, drag-driven boat dead downwind (AWA 180 degrees, the Eiffel plate data in Marchaj, second-hand) would line up with the true wind. A fast yacht's AWA is usually under 90 degrees even downwind, so lift drives it and "makes it more like the upwind situation".

### Deflection toward the centreline: small, and extra to the apparent-wind swing

Marchaj, as quoted by Richards et al., says the close-hauled wake "is deflected away from the line of the apparent toward the stern". Richards measured how much:

- Upwind (AWA 20 degrees): the centre of the negative band is "a few degrees off the direct line", about **5 degrees**, "deflected slightly by the lift generated on the sails".
- Downwind (AWA 60 degrees): about **9 degrees**.

So the deflection toward the stern is real, but it is a correction of 5 to 9 degrees on top of the apparent-wind line. It is not the main swing.

### Reach and width: only drive-force footprints

No source gave a velocity-deficit decay law. What exists:

- **Hooper's J-class wind tunnel data, via Marchaj via Richards** (both models at AWA 40 degrees, 15 degrees heel): the lowest drive on the affected yacht, down to 0 to 10% of free-air drive, lay along the apparent wind line downstream. Almost all downwind positions lost drive, returning to nearly 100% "one boat length either side of the centreline". That suggests a footprint of roughly 2 Lb across, but the downwind distance this applied to is not stated in the retrieved text.
- **Caponnetto 1996 vortex lattice, via Richards** (IACC yachts, AWA 25 degrees, no heel): the worst direction for the key boat is 22 degrees from the bow, almost along the apparent wind. The drive ratio (windward boat to leeward key boat) is 4.8 at a distance of 0.5h, 2.6 at 1h and 2.0 at 2h. At 1h the key boat loses 60% of its drive while the other gains 4%. Interference falls with distance, but only three radii were reported.
- **Richards' wind tunnel, mast heights**: Figure 4 and Figure 7 give drive-force contours in multiples of h, but only as graphics. Their conclusion is that in both upwind and downwind cases drive is "significantly reduced in a region either side of a line slightly aft of the apparent wind direction".
- **Marchaj, via Richards**: "the influence of the wind deflection and turbulence behind a yacht can be felt for up to ten boat lengths". This is one sentence of a secondary quote, with no stated threshold for "felt".

### Deficit and turbulence

- **Close-hauled, two yachts about 3h apart** (cobra probe, 1/3 mast height): the upstream yacht leaves a clear low-speed region, and the downstream boat would see weaker flow "effectively 4 degrees further away from the true wind direction". Richards link the direction change to the strong vortex shed from the **masthead** of the upstream yacht.
- **Downwind, spinnaker, AWA 60 degrees** (Fig. 9, 1/3 mast height): the speed deficit is similar in shape to, but weaker than, the drive-force loss, since force goes roughly as speed squared and also depends on direction. The wind direction is adversely changed by **over 30 degrees** in places. Turbulence intensity exceeds **40%** in places.
- **CFD of AC33-type yachts** ([Norris and Durand 2016](https://people.eng.unimelb.edu.au/imarusic/proceedings/20/647%20Paper.pdf)): the velocity contours at 1/8 mast height show a wake behind each yacht's sails, but "the decrease in the velocity in the wakes is not large". The authors suspect poor mesh resolution and a clean, mast-less, rigging-less model, and say a larger wake "would be expected" to hurt the leeward yacht more. Their results "do not agree with experience". Treat their wake strength as an underestimate.

### Advection

The only direct statement is Richards': the wake is carried by the true wind while the boat moves on, so in the boat's frame it lies along the apparent wind. In a steady course this is a straight line in the boat's frame. For a turning boat the sources do not say. The mechanism (a wake that is a property of the air, left behind) follows from it, and Spenkuch et al.'s lifting-line model uses it: the abstract says wake vortex elements are "convected into the wake" and "move in accordance with the local wind" plus induced velocities ([Spenkuch, Turnock, Scarponi, Shenoi 2011, J. Mar. Sci. Technol. 16:115-128](https://eprints.soton.ac.uk/178977); I read only the abstract via search results, not the paper).

### Not found

- No measured decay of deficit or turbulence with distance in boat lengths, no width growth law.
- **Atmospheric stability:** no yacht source. I did not find a yacht-specific measurement, and I did not pull general wake-flow literature.
- **Sail twist:** Richards' twisted-flow tunnel exists, but the upwind two-yacht tests moved the twisting vanes aside and used a nearly uniform profile; the downwind ones also lacked the twist. No sail-twist effect on the wake is reported.

## 2. Backwind on a boat to windward and astern

The quantitative sources are few and none measured the exact lee-bow geometry in a same-tack, in-line pass with a turbulence split.

- **Mechanism, smooth deflection.** Norris and Durand attribute the effects on a passing yacht to "changes in apparent wind direction due to upwash from the other yacht" plus the low-speed wake. Upwash from the leeward yacht **decreases the AWA of the windward yacht** (a header). That header "would be countered in practice by steering further away from the wind". Upwash from the windward yacht **increases** the AWA of the leeward yacht (a lift), and the leeward yacht also sails in a faster region to leeward of the windward yacht.
- **Size and range (CFD, opposite tacks, AWA 18 degrees).** The drive loss on the windward yacht is slight at small separations and is "negligible" by about 1 Lb of closest approach (Fig. 9: "rapidly goes to zero by Δ = 1"). At Δ = 4 Lb the leeward yacht's response is still present, but smaller. The apparent-wind swings in their Fig. 8 sit within a plotted range of 17.4 to 19.2 degrees about 18, so they are about 1 degree or less in that model. The windward yacht's header is a bound, instantaneous field effect: it appears as the yachts pass, without a trail.
- **Sign.** The windward yacht gets a **header and a slowdown** from the leeward yacht in the CFD. That fits the usual idea of Backwind, but note again the model underpredicts the wake.
- **Lee-bow position.** Richards' upwind tunnel found "a small positive interference region ahead of the bow" and, for the key yacht in the "safe leeward position", a drive ratio over 1.0 from directly astern to 30 degrees windward of astern. Marchaj's "safe leeward position", via Richards, is the Hooper result: a gain of about 20% with the two models in line across the apparent wind and the affected one 0.6 Lb to leeward. The affected yacht in the "hopeless position" (to windward) is Marchaj's phrase, quoted by Richards, with no number.
- **Scaling with loading or speed, and the dead run.** No source states how the effect scales with sail loading, speed or AWA, or that it vanishes on a run. Richards only note that at AWA 60 degrees the wake is already lift-driven, and that an AWA near 180 degrees is the exception. The idea that Backwind is absent when running is plausible but **unsupported by anything I read**.
- **Smooth versus turbulent split.** Richards gives wind direction change (over 30 degrees) and turbulence (over 40%) side by side only for the downwind wake. No source separates "potential-flow deflection" from "turbulence" for the lee-bow geometry. The masthead vortex is the identified source of the direction change.

## 3. Dinghies, skiffs, match and fleet racing

No primary source with quantitative wind shadow or cover data was found for ILCA, 49er or similar classes. The searches turned up dinghy sail wind-tunnel work (a 1/16 scale Laser, the Chalmers ILCA 7 downwind sail tests) but these measure sail forces, not wakes. For fleet racing, Spenkuch et al.'s wake model is built for the Robo-Race simulator (abstract only), and the abstract states two upwind race case studies but gives no numbers I could read. The Spenkuch thesis (Southampton 2014) and the Marino et al. 2017 Strathclyde paper on two-yacht aerodynamic and hydrodynamic interaction were not retrievable. The existing [`49er-skiff-polars-and-handling.md`](49er-skiff-polars-and-handling.md) already notes a skiff's apparent wind in the downwind groove is 50 to 65 degrees, which, by Richards, means the shadow trails well to the side of the true wind.

## Verdicts on the working hypotheses

**(a) The wake advects with the true wind and spreads and decays with age: confirmed in direction, unquantified in decay.** Richards states the advection argument and shows the resulting apparent-wind alignment. Spreading and decay with age are physically sensible and used by Spenkuch's model, but no measured decay law was found. "Ten boat lengths" (Marchaj) is the only reach figure, second-hand.

**(b) Backwind is mostly smooth deflection (header plus slowing), bound to the boat with no memory, scales with sail loading, 1 to 3 Lb: partly supported.**
- Supported: upwash and header, and a short range (windward-boat drive loss gone by about 1 Lb in CFD).
- Unsupported: "scales with sail loading" and "vanishes when running" have no source. "No memory" is implied by the upwash explanation, but never tested.
- Refine: the header is the leeward boat's masthead and sail upwash. Richards measured 4 degrees of direction change 3h behind a yacht, but that is the wake region, not the lee-bow region.
- Caveat: the one CFD result (Norris and Durand) underpredicts wake strength by the authors' own account.

**(c) The shadow axis swings part of the way from downwind toward astern because sails turn the flow: refined.** Most of the swing from the true wind is the apparent-wind alignment (boat motion), not turning of the flow. Flow turning adds a further **5 degrees close-hauled and about 9 degrees on a spinnaker reach** toward the stern, relative to the apparent wind line. If the game's cone axis sits only part way between true wind and astern with no apparent-wind term, it lacks the main effect.

## What this means for a trail-of-turbulence model (#376)

- **Anchor each trail point to the true wind.** Release shadow puffs or segments from the sails and let them drift with the true wind while the boat moves on. In the boat's frame a steady course then gives a trail along the apparent wind without special-casing (Richards).
- **Add the small extra:** rotate the near-boat axis a few degrees astern of the apparent wind (about 5 degrees upwind, about 9 degrees on a reach) and let it fade, if felt feedback needs it.
- **Reach is a tuning value.** The only anchor is "up to ten boat lengths" (Marchaj, second-hand). Pick a sensible fade distance and a width of about 2 Lb at the footprint (Hooper, second-hand), and make both debug sliders per the fun-before-realism stance. Mark them as not measured.
- **Keep Backwind separate from the trail.** It is a bound upwash field (header plus slowing) around the boat, with no memory, short-ranged (about 1 Lb of lateral separation in the only CFD) and strongest close-hauled and reaching. This agrees with the current glossary text. Its scaling with speed and its absence when running are model choices, not findings.
- **Downwind is a hazard, not a rule.** A downwind shadow can carry a large header (over 30 degrees) and turbulence over 40% (Richards, spinnaker, AWA 60 degrees). A trail on a run or reach should still lie along the apparent wind, not the true wind.
- **Not available:** no data for skiffs or dinghies, stability or twist. Do not present any value for them as researched.
