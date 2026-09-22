# Wind and current visual conventions

Research for wayfinder ticket [04](../wayfinder/tickets/04-wind-and-current-visual-conventions.md). It feeds the information-design ticket ([14](../wayfinder/tickets/14-on-water-information-design.md)) and the art-direction ticket ([21](../wayfinder/tickets/21-art-direction-audio-haptics.md)).

**Question.** How do broadcast graphics, tactical sailing apps and sailing games show wind direction, wind strength, shifts, puffs and lulls, wind shadow, laylines, boundaries and tidal current? Which of these read at phone size and at a glance mid-race, and which are colour-blind safe?

**Method.** I used first-party sources where they exist: vendor manuals (Expedition, Vakaros Atlas 2, OpenCPN), vendor help centres (PredictWind, SailRacer, Virtual Regatta), rightsholder sites (SailGP, America's Cup), and trade press that quotes the graphics teams. Some sources could not be fetched: B&G's own blog (403), the Virtual Regatta Inshore help centre (403) and BusinessDesk (paywall). Claims from those sources are marked *secondary*. I did not download any images or videos. The URLs are given so the prototype team can open them.

---

## 1. What exists today, by source

### 1.1 Broadcast: America's Cup LiveLine (2013) and SailGP LiveLineFX

Stan Honey's LiveLine was built for the 34th America's Cup and later carried into SailGP. It overlays geo-registered graphics on helicopter video.

- **Ladder lines** are lines at right angles to the wind, 100 m apart, "creating a 'ladder' that leads to the next gate or mark". They show who is ahead in wind terms, not in straight-line distance. Source: [IEEE Spectrum, *The Augmented Reality America's Cup*](https://spectrum.ieee.org/the-augmented-reality-americas-cup). SailGP describes them as the most precise indication of who is winning ([TVBEurope](https://www.tvbeurope.com/live-production/sailgps-livelinefx-charts-a-new-course-in-on-screen-graphics)).
- **Laylines** are drawn in **yellow** ([IEEE Spectrum](https://spectrum.ieee.org/the-augmented-reality-americas-cup)).
- **Mark zones.** Yellow polygons mark the three-boat-length zone around each gate buoy, which is where the rounding rules apply ([IEEE Spectrum](https://spectrum.ieee.org/the-augmented-reality-americas-cup)).
- **Course boundaries** are lines along the outer limits of the course. SailGP now also draws a "3D LiveLine boundary" ([IEEE Spectrum](https://spectrum.ieee.org/the-augmented-reality-americas-cup); [TVBEurope](https://www.tvbeurope.com/live-production/sailgps-livelinefx-charts-a-new-course-in-on-screen-graphics)).
- **Wind direction** is an **arrow on a compass display** in a corner. It is not drawn on the water ([IEEE Spectrum](https://spectrum.ieee.org/the-augmented-reality-americas-cup)). SailGP adds AR wind-direction indicators and a graphic for the best point to hit the start line ([TVBEurope](https://www.tvbeurope.com/live-production/sailgps-livelinefx-charts-a-new-course-in-on-screen-graphics); [SailGP: How LiveLineFX graphics…](https://sailgp.com/news/23/watch-liveline-graphics-boundaries-ladder-lines-sail-racing/), which has an embedded video).
- **Boat tracks** are coloured per boat, with name and speed labels that travel with each boat ([IEEE Spectrum](https://spectrum.ieee.org/the-augmented-reality-americas-cup)).
- **Tiered information.** Newcomers get leader, speed and gap. Enthusiasts get deeper data such as foiling height. The aim is "no barriers to entry for any viewer" ([TVBEurope](https://www.tvbeurope.com/live-production/sailgps-livelinefx-charts-a-new-course-in-on-screen-graphics)).
- **Mobile.** The SailGP app puts overlays and boundary lines on phone screens and in AR tabletop and XR viewers. The XR viewer has a 3D mini-map that shows wind direction ([Sports Video Group 2025](https://www.sportsvideo.org/2025/03/21/sailgps-2025-season-to-be-most-technologically-advanced-in-sailing-history/); [SailGP RaceScape XR, App Store](https://apps.apple.com/us/app/sailgp-racescape-xr/id6742781005); [SailGP app](https://sailgp.com/about/sailgpapp/)).

**Takeaway.** Two decades of broadcast practice keep wind direction off the water: a single compass arrow is enough for spectators. What goes on the water is geometry: ladder lines, laylines, zones and boundaries. Ladder lines are the one device designed for novices to read at a glance.

### 1.2 Broadcast: America's Cup 37 (2024), Virtual Eye and WindSight IQ

- Capgemini's **WindSight IQ** uses shore-based LiDAR to measure a live wind field, refreshed every second ([Sports Video Group](https://www.sportsvideo.org/2024/10/18/live-from-the-37th-americas-cup-how-this-years-coverage-found-the-holy-grail-of-seeing-the-wind/)).
- **Encoding.** The water is coloured "like a thermal imaging camera". **Everything above and below the *current average* wind speed is coloured**, and **arrows** on top show direction ([YACHT](https://www.yacht.de/en/regatta/america-s-cup/america-s-cup-visible-wind-for-the-first-time-how-windsight-iq-is-revolutionising-sailing/)). SVG describes **blue areas** marking where the wind gives an advantage ([Sports Video Group](https://www.sportsvideo.org/2024/10/18/live-from-the-37th-americas-cup-how-this-years-coverage-found-the-holy-grail-of-seeing-the-wind/)). The scale is **relative (a diverging scale around the mean)**, not absolute knots. That is the key design choice to borrow for puffs and lulls.
- **Design stance.** The graphics "have to be easy to understand, it shouldn't need much explanation". The rendering adapts to overcast or sunny water ([YACHT](https://www.yacht.de/en/regatta/america-s-cup/america-s-cup-visible-wind-for-the-first-time-how-windsight-iq-is-revolutionising-sailing/)).
- **Ghost boat.** A simulated optimal-path boat is drawn in AR ([Sports Video Group](https://www.sportsvideo.org/2024/10/18/live-from-the-37th-americas-cup-how-this-years-coverage-found-the-holy-grail-of-seeing-the-wind/)).
- **Wind shadow and covers could be shown but are not.** Reporting on the system says turbulence and covers *could* be visualised with WindSight IQ but this is not done ([Sailing Scuttlebutt](https://www.sailingscuttlebutt.com/2024/08/22/new-technology-for-sailing-broadcast/), *secondary*).
- **Example footage:** [36th AC Day 7 Virtual Eye](https://www.americascup.com/video/1254_36TH-AMERICA-S-CUP-DAY-7-VIRTUAL-EYE) (a full 3D race recreation) and [americascup.com/innovation-and-technology](https://www.americascup.com/innovation-and-technology).

### 1.3 Tactical software and instruments

**Expedition** (a navigation and racing PC app). Source: [manual PDF, expeditionmarine.com](https://www.expeditionmarine.com/downloads/documents/Expedition.pdf).
- **Laylines** run from the active mark. There are three variants. *Layline bounds* are the extreme laylines over the last N minutes, a fan that shows the oscillation range. *Laylines from boat* start at the boat. *Laylines using predicted tides* are **curved** to account for the tidal current model. In the manual's example, "solid lines are the laylines based on the measured current and the thin lines are laylines based on the tidal current model".
- **Wind strength.** You can contour wind speed because it "will depict the hot and cold spots of wind velocity more obviously than standard wind barbs". There is also *shading* and a *fade colours* option ("brighter colours at larger values"). Colour modes are a single colour, red-to-blue, **greyscale** or the Beaufort scale. Arrows or barbs are available for vectors, and there is an animated wind-flow layer.
- **Shifts.** A StripChart shows TWD over time, used to spot oscillating versus persistent shifts ([Sailing World](https://www.sailingworld.com/gear/expedition-tactical-routing-software/); [Interstate Sailing](http://interstatesailing.com/strip_chart)).
- *Layline mode* strips out chart clutter once racing starts (manual). That is a useful precedent for a race-time information mode.

**SailRacer** (a phone app, the closest analogue for phone-size legibility). Source: [docs: On the course](http://www.sailracer.net/docs/application/on-the-course/).
- **Shift bar** on top of the compass rose. The middle line is the 6-minute average heading, with **red and green bars** for the port and starboard tacks. The bar width is the maximum shift over 6 minutes ([image](http://www.sailracer.net/docs/wp-content/uploads/2014/10/course_shift-300x187.png)).
- **Laylines** are solid when computed from polars or tack angles and **dashed when adjusted for current** ([image](http://www.sailracer.net/docs/wp-content/uploads/2014/10/laylines-300x187.png), [current laylines image](http://www.sailracer.net/docs/wp-content/uploads/2014/10/currentlaylines-300x187.png)).
- **Marks** use red for port roundings, green for starboard and yellow for gates ([image](http://www.sailracer.net/docs/wp-content/uploads/2014/10/course_mark-300x187.png)).
- **Wind graphs** over 6 minutes and 1 hour, with a thin curve for wind speed ([image](http://www.sailracer.net/docs/wp-content/uploads/2014/10/windgraph2-300x187.png)).
- The stated design goal is that efficiency, laylines and shifts can be "captured in a splash of a second" ([sailracer.net](https://sailracer.net/)).
- **Colour-blind risk.** Port red and starboard green is the nautical convention, but it is the classic deuteranopia confusion pair. It is safe only because position and labels carry the same meaning.

**Vakaros Atlas 2** (a dinghy instrument, 4.4-inch 320×240 transflective display). Source: [Atlas 2 User Manual rev. 2022-11](https://images.bucher-walt.ch/pdf_tech/fr/Atlas_2_User_Manual_6.pdf).
- The heading widget shows a **lift/header indicator in degrees plus a trend graph**, relative to port and starboard *reference angles*. The reference angles are captured by sailing a short upwind leg.
- A **row of 7 RGB LEDs** can be assigned to shift tracking, the start timer, distance to line or time to burn. This is peripheral-vision display: a light you can read without looking at the numbers. One user found the lift/header LEDs "far more helpful than expected" ([Sailing Anarchy thread](https://forums.sailinganarchy.com/threads/vakaros.206533/page-32), *secondary*).
- A graphical start screen shows the boat relative to the line.

**B&G SailSteer** (chartplotter), *secondary* because B&G's blog returned 403 ([B&G blog](https://www.bandg.com/blog/racepanel-series-with-mark-chisnell-part-5-sailsteer/); [PBO test](https://www.pbo.co.uk/gear/sailing-chartplotters-exclusive-first-test-21854)).
- One compass-rose screen shows true and apparent wind, heading, laylines (**solid red and green**), optional **dotted historical laylines** showing recent shift extremes, and **tide as a blue arrow with a number** in the centre.

**Windy** (weather map).
- Wind speed is a **colour field**: blue for light, green to red for more, purple for extreme. Direction is shown by **animated particles**. Particles move faster and have longer tails where it is windier, and the speeds are deliberately exaggerated so movement is visible ([Windy Community: idea for wind visualisation](https://community.windy.com/topic/10917/idea-for-wind-visualisation); [Wind speed colour](https://community.windy.com/topic/87/wind-speed-colour)).
- Users report that particles alone make speed hard to read, and that animation drains battery on phones ([Disable particle animation…](https://community.windy.com/topic/8459/disable-particle-animation-but-show-wind-direction)).
- **Colour-blind.** There is no colour-blind mode. Staff reply that users can build their own scale, and a colour-blind user worked around it with a single-hue scale ([Color Blind users](https://community.windy.com/topic/31476/color-blind-users)). Custom scales are not available in the phone app ([Windy Community](https://community.windy.com/topic/20432/change-wind-strength-color-settings)).

**PredictWind / PredictCurrent.**
- Currents are drawn as a **colour gradient for speed** with **black arrows or streamlines** (user's choice) for direction, at 100 m, 400 m or 4 km resolution ([Tidal Currents in the PredictWind App](https://help.predictwind.com/en/articles/10972099-tidal-currents-in-the-predictwind-app)). An animated example: [ForecastCurrents.gif](https://downloads.intercomcdn.com/i/o/smve6uws/1445396814/3c947d82e5101dfac60fae932f84/ForecastCurrents.gif).

**OpenCPN.**
- The built-in display draws current stations as **orange diamonds**. Zoomed in, they become **arrows whose size scales with rate** ("the bigger the arrow, the more current"), in a single colour, with an optional number beside each arrow. It only handles reversing currents, not rotary ones ([OpenCPN manual: Tides and Currents](https://opencpn.org/wiki/dokuwiki/doku.php?id=opencpn%3Amanual_basic%3Achart_panel%3Achart_panel_options%3Atides_currents)).
- The oTCurrent plugin adds **colour by speed range**, solid or outline arrows, and optional rate and direction text ([oTCurrent manual](https://opencpn-manuals.github.io/main/otcurrent/index.html)).

**Paper convention: Admiralty tidal stream atlases.**
- Arrows are **longer and thicker for faster streams**, with a pair of numbers for neap and spring rates in tenths of a knot (for example, "15,30") ([Wikipedia: Tidal atlas](https://en.wikipedia.org/wiki/Tidal_atlas); [Admiralty](https://www.admiralty.co.uk/publications/miscellaneous-tidal-publications/admiralty-tidal-stream-atlases); [sailingissues.com](https://sailingissues.com/navcourse8.html)).
- This is the convention sailors already know for current: **thickness and length, not hue**. It is colour-blind safe by construction.

**Meteorological convention: wind barbs.**
- The shaft points to where the wind comes from. A long feather is 10 kn, a short one 5 kn and a pennant 50 kn ([Oklahoma Mesonet: Reading wind barbs](https://www.mesonet.org/images/site/Wind%20Barb%20Feb%202012.pdf); [NOAA JetStream](https://www.noaa.gov/jetstream/upper-air-charts/common-features-of-constant-pressure-charts)).
- Barbs are precise and colour-free but have to be counted. They are too fine to read at a glance on a phone mid-race.

### 1.4 Games

- **Virtual Regatta Inshore** (iOS and Android, the direct competitor). It models wind shifts, gusts and lulls, and wind shadow. Players say the shadow makes it "far easier to see if you're in a clean lane". Laylines are "drawn from your TWA". A PRO interface adds a racing compass and a wind-variation indicator ([App Store](https://apps.apple.com/us/app/inshore-by-virtual-regatta/id1182301199); [VR Inshore help, section index](https://vrinshore.zendesk.com/hc/en-us/sections/360003685199-Playing-Virtual-Regatta-Inshore)). The help pages that describe the HUD returned 403, so the exact visual forms are unverified. The store screenshots are the thing to review.
- **Sail the Wind** (a web board game). The wind arrow sits in a corner. **Darker squares are puffs and lighter squares are lulls.** Each boat drops a shadow token one square downwind ([rules](https://konstantint.github.io/sail-the-wind/rules.html)). This is the lightness convention in its simplest form.
- **eSail** (PC simulator). Stronger wind shows as **patches of water with less reflection** (ripples), which are easier to spot from a distance. The effect fades above about 25 kn ([eSail: Wind](https://www.esailyachtsimulator.com/the-world-of-esail/wind/)). This is the physical cue real sailors read ("dark water = pressure").
- **Yacht Racing Game** (iOS). It has an explicit **"Blanket Cone"**: speed drops when you are to leeward of another boat ([App Store](https://apps.apple.com/us/app/yacht-racing-game/id1244722434)).
- **cWind** (iOS). A user review asks for "darker water for wind puffs" ([game-solver summary](https://game-solver.com/cwind/), *secondary*). Players expect the real-world convention.

### 1.5 The current Regatta prototype (baseline to react to)

From the code in this repo:
- **Wind direction:** a grid of faint arrows (alpha 0.14) that rotate with the wind (`Regatta/Game/WaterNode.swift`).
- **Puffs** are radial-gradient discs tinted `Palette.gust`, a dark navy darker than the water, with alpha up to 0.55. **Lulls** are **white** discs (`Regatta/Game/GameScene.swift`, `updatePuffs`). This already follows "dark water = more wind".
- **Wind shadow:** a black cone at alpha 0.05 per boat (`Regatta/Game/BoatNode.swift`). The HUD wind gauge turns **orange** when you are in shadow (`Regatta/UI/HUDView.swift`).
- **Laylines:** a dashed white line at alpha 0.22 from the next mark (`GameScene.updateLaylines`).
- **Shift:** the HUD shows the shift in degrees relative to the course axis.
- **No current or boundary rendering yet.** The boat palette includes red and green pairs that are not CVD safe (`Regatta/Game/Palette.swift`). That belongs to another ticket, but any wind and current colours must not collide with it.

---

## 2. Legibility at phone size, mid-race

Criteria: a portrait phone viewport, a glance of under half a second, the player's eyes mostly on their own boat and the nearest rivals.

| Representation | Glanceable on a phone? | Why |
|---|---|---|
| Single wind arrow or compass in the HUD (LiveLine, Sail the Wind) | **Yes** | One fixed place and one shape. Every source converges on it. |
| Field of arrows or streaks on the water (prototype, Windy particles) | **Partly** | Good for direction in peripheral vision. Speed-by-length is hard to read (Windy users). Animation costs battery. |
| Wind barbs | **No** | Feathers must be counted, and they are too fine at 3–6 mm on screen. |
| Diverging relative pressure shading, darker or brighter than average (WindSight IQ, eSail, Sail the Wind) | **Yes** | Area marks read in peripheral vision. The relative scale needs no legend. It matches real-world "dark water". |
| Absolute rainbow speed field (Windy default) | **No** | Needs a legend, and it is not CVD safe. |
| Numeric lift/header in degrees (Atlas, prototype HUD) | **Partly** | Precise but has to be read. Best paired with a non-numeric cue. |
| Shift bar or LED lift/header (SailRacer, Atlas LEDs) | **Yes** | Direction and magnitude read peripherally. |
| Shift history strip chart (Expedition, SailRacer 6 min / 1 h) | **No** mid-race | Too dense. Fine for a pause or post-race screen. |
| Laylines from the mark (LiveLine yellow, SailRacer, prototype) | **Yes**, if contrast is sufficient | The prototype's alpha 0.22 dashed white will vanish in glare. Broadcast uses bold yellow. |
| Layline "bounds" fan (Expedition, B&G dotted history) | **Partly** | Useful, but it doubles the line count. Could be a pro or advanced toggle. |
| Ladder lines (LiveLine) | **Yes** | Good for "am I gaining?". Risk of clutter on a small screen, so it may need thinning. |
| Wind-shadow cone (Yacht Racing Game, VR Inshore) | **Yes**, if visible | The prototype's alpha 0.05 black cone is effectively invisible. |
| Current as sized arrows (Admiralty, OpenCPN) | **Yes** | Thickness and length encode rate with no colour needed. |
| Current as colour field + streamlines (PredictWind) | **Partly** | Competes with the wind shading for the same channel (water colour). |
| Boundary lines (LiveLine, SailGP 3D boundary) | **Yes** | A line plus an edge treatment. |

## 3. Colour-blind safety

- The principle: never rely on hue alone. Apple's HIG says to avoid relying solely on colour to differentiate objects or convey information ([Apple HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color)).
- **Unsafe conventions found:**
  - Red and green port/starboard laylines (B&G) and shift bars (SailRacer).
  - Windy's rainbow speed scale.
  - PredictWind's colour gradients (hue-based).
  - The prototype's orange "in shadow" state, which is hue-only on white text. Orange and white differ in luminance, but the meaning is carried only by colour.
- **Safe by construction:**
  - Lightness-only encodings: eSail's dark water, Sail the Wind's darker and lighter squares, and Expedition's greyscale option.
  - Size and thickness: Admiralty and OpenCPN current arrows.
  - Line style: SailRacer and Expedition use solid versus dashed or thin lines for current-adjusted laylines.
  - Position and shape: the LiveLine compass arrow and ladder lines.
- **Palettes to draw from if hue is needed:** Okabe–Ito ([Okabe & Ito, Color Universal Design](https://jfly.uni-koeln.de/color/); summary: [easystats](https://easystats.github.io/see/reference/scale_color_okabeito.html)). For continuous or diverging fields, use perceptually uniform maps such as viridis or cividis ([viridis vignette](https://cran.r-project.org/web/packages/viridis/vignettes/intro-to-viridis.html)). A blue↔orange diverging pair survives all three common colour-vision deficiencies. Red↔green does not.

---

## 4. Recommended candidate representations for the prototype

Each quantity gets a primary candidate and an alternative to A/B test. The rule is that each quantity owns one visual channel, so they do not fight.

| Quantity | Channel it owns | Primary candidate | Alternative to test | Evidence |
|---|---|---|---|---|
| **Wind direction** | Orientation of fine texture on the water, plus one HUD arrow | Keep the faint streak field on the water, aligned and slowly drifting downwind. Add **one bold HUD wind arrow** at a fixed place (top of screen, pointing *downwind* on the upwind-up course view). | Animated particles (Windy-style), capped in count for battery | LiveLine compass; Windy; prototype |
| **Wind strength (absolute)** | HUD number | **Knots number beside the HUD arrow.** No absolute colour field. | Streak length or speed proportional to TWS | Windy speed-by-length is hard to read |
| **Puffs / lulls** | **Water lightness, relative to the course average** | **Darker water = more pressure, lighter or glassier = less**, on a diverging lightness scale around the mean (WindSight IQ's relative scale in eSail's dark-water visual language). Add a subtle ripple texture inside puffs so the cue survives for users with low contrast sensitivity. | Blue↔orange diverging tint (CVD safe) on top of the lightness change | WindSight IQ; eSail; Sail the Wind; cWind review |
| **Shifts (lift / header)** | HUD shape + position | **Shift needle or bar** on the HUD compass: the offset from the tack's reference heading, with **▲ lift / ▼ header glyphs** and a signed degree number. On the water, the streak field rotating is the secondary cue. | An edge "LED strip" along the top of the screen, fed by shift magnitude (Atlas-style peripheral cue) | SailRacer; Atlas 2; Expedition bounds |
| **Wind shadow** | Area texture behind boats | **Visible cone** (a much stronger tint than the prototype's alpha 0.05) using **lightness plus a hatched or streaked texture**. When the player is inside a cone, the cone edge brightens and a haptic plays. Not a colour change alone. | Cone shown only for boats within about 5 lengths, to limit clutter | Yacht Racing Game; VR Inshore; the idea that WindSight IQ "could" show covers |
| **Laylines** | Bold lines from the mark | **Two bold high-contrast lines** (a single colour such as broadcast yellow `#F0E442`, not red/green) from the next mark. **Dashed when current-adjusted**, solid when not. Brighter when the player is within about 2 lengths of a layline. | Fan of layline bounds from the last N minutes (Expedition), as a toggle | LiveLine; SailRacer; Expedition; B&G |
| **Ladder lines** (position vs rivals) | Thin lines across the course | Optional: **3–5 thin lines at right angles to the wind** near the player, each 100 m (or N boat lengths) apart, fading with distance | Off by default, shown in the spectate or finished view | LiveLine / SailGP |
| **Boundaries** | Edge treatment | **Solid line plus a hatched out-of-bounds band** beyond it. The band is patterned, not coloured, so it reads without hue. The out-of-bounds warning adds a HUD icon. | 3D-style extruded wall (SailGP 3D boundary) | LiveLine / SailGP boundary |
| **Tidal current** | **Arrow size and thickness**, separate from water tone | **Sparse field of chunky arrows** (Admiralty style) whose **thickness and length scale with rate**, in a neutral light tone, drifting slowly. Plus a **HUD current arrow with a knots value** at the boat (B&G SailSteer style). | PredictWind-style streamlines, only if they do not collide with the puff lightness channel | Admiralty atlases; OpenCPN; B&G; PredictWind |
| **Shift/wind history** | Not shown mid-race | Keep out of the race view. Offer a strip chart on pause or post-race. | — | Expedition StripChart; SailRacer graphs |

**Guardrails for ticket 14:**
- Wind strength and current must not both use water colour. Give puffs the lightness of the water. Give current discrete arrows.
- Every hue-coded state also needs a shape, pattern, glyph or position cue. That covers shadow, lift and header, laylines and out-of-bounds.
- Reserve the red and green hue pair for mark rounding side if at all (SailRacer and nautical convention), and always pair it with a side-of-mark glyph.
- Keep absolute numbers (TWS, current rate, shift in degrees) in a fixed HUD cluster. Show relative information on the water.
- Test every candidate in a deuteranopia and protanopia simulator, and in greyscale. If it fails in greyscale, it does not rely on lightness enough.

## 5. Open items for the prototype team

- Pull screenshots from these for side-by-side review: the VR Inshore App Store gallery, the SailGP LiveLine video, and the AC37 WindSight IQ broadcast clips. I only verified their text descriptions here.
- Confirm how strong the puff shading can be before it hides the boats and marks, especially in sunlight at full brightness.
- Decide whether ladder lines are worth the clutter in a 16-boat fleet on a phone.
