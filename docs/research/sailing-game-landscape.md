# Sailing game landscape teardown

Research for [ticket 01](../wayfinder/tickets/01-sailing-game-landscape.md). Researched 2026-09-22.

**Question:** How do existing sailing games handle controls, boat handling, rule enforcement, wind and current display, race length, modes, lobby/matchmaking and monetization, and what do players praise and complain about?

**Method and limits.** Primary sources first: each game's own site, store listing and help pages. Nothing was downloaded, installed or signed into, so in-game detail that isn't publicly documented is marked *not public*. Three primary sources couldn't be read directly: the VR Inshore help centre (`vrinshore.zendesk.com`) sits behind a Cloudflare bot check, the Virtual Regatta forum returns 403, and `virtualregatta.com/en/inshore-game/` returns 403. For those I used search-engine excerpts of the pages and label them *(via search excerpt)*. Reddit threads didn't show up in search. Player sentiment comes from store reviews, the VR forum (excerpts), Steam discussions and a Change.org petition.

---

## 1. The games

| Game | Platform | Why it matters to Regatta |
|---|---|---|
| **Regattatron** ([regattatron.com](https://regattatron.com)) | Browser | The direct inspiration: a top-down, real-time multiplayer fleet racer that enforces the RRS on the server. |
| **Inshore by Virtual Regatta** (VR Inshore) ([App Store](https://apps.apple.com/us/app/inshore-by-virtual-regatta/id1182301199)) | iOS, Android, web | The incumbent mobile game, and the official platform of the World Sailing eSailing World Championship. |
| **Virtual Regatta Offshore** ([App Store](https://apps.apple.com/us/app/virtual-regatta-offshore/id387893495)) | iOS, Android, web | The same company's offshore game, which runs for weeks. Its monetization is the cautionary tale. |
| **Sailaway / Sailaway III** ([sailaway.world](https://sailaway.world), [Steam](https://store.steampowered.com/app/2631870/Sailaway_III/)) | PC/Mac | Heavy real-world simulation. It's the reference for current and weather realism and a counter-example on racing rules. |
| **PlayeSailing \| Inshore Racing** ([App Store](https://apps.apple.com/us/app/playesailing-inshore-racing/id1621745536)) | iOS | A small mobile competitor that applies RRS rules and has Elo, private races and cosmetic IAP. |
| **Yacht Racing Game** ([App Store](https://apps.apple.com/us/app/yacht-racing-game/id1244722434)) | iOS | A simple single-player tactics trainer with the lightest controls in the set. |
| **Top Sailor** ([App Store](https://apps.apple.com/us/app/top-sailor/id430948592)) | iOS, Android | A paid single-player sim with tilt steering, a trim slider and AI fleets. |
| **Sailboat Championship** ([App Store](https://apps.apple.com/us/app/sailboat-championship/id364580591)) | iOS | An older paid game with tiller and sheet controls. Not updated since 2018. |

---

## 2. Comparison

### 2.1 Controls and boat handling

| Game | Steering | Sail handling | Manoeuvres |
|---|---|---|---|
| Regattatron | *Not public* (the page is behind sign-in) | *Not public* | Its marketing implies tack-on-shifts play. Details *not public*. |
| VR Inshore | Left and right arrow buttons on screen, or the keyboard ([Sailing World](https://www.sailingworld.com/racing/going-virtual/)) | A "switch sails" button picks the best sail for the course, and an "ease" button slows and eventually stops the boat ([help centre, *via search excerpt*](https://vrinshore.zendesk.com/hc/en-us/articles/360012294540-How-do-I-control-my-boat)) | A tack/gybe button (or the T key) turns through the tack or gybe and keeps the same angle to the wind *(same source)*. Best VMG is a paid race help that holds the optimum angle (see 2.8). |
| PlayeSailing | Steering controls | Daggerboard and spinnaker buttons | Separate tack/gybe buttons ([App Store](https://apps.apple.com/us/app/playesailing-inshore-racing/id1621745536)) |
| Yacht Racing Game | Long-press to steer towards a point | None | Tap to tack. Its listing calls this an "easy way to control" ([App Store](https://apps.apple.com/us/app/yacht-racing-game/id1244722434)) |
| Top Sailor | Tilt the device like a steering wheel | On-screen trim slider | Manual ([App Store](https://apps.apple.com/us/app/top-sailor/id430948592)) |
| Sailboat Championship | Tiller | Sheet control | Manual ([App Store](https://apps.apple.com/us/app/sailboat-championship/id364580591)) |
| Sailaway | Full manual helm, with autopilot and routing | Realistic sail trim with auto-trim | Manual. Boats keep sailing on autopilot when the player logs off ([sailaway.world](https://sailaway.world), [Steam thread](https://steamcommunity.com/app/552920/discussions/0/3288067088096215253/?ctp=3)) |

**What players say about controls**
- VR Inshore: players on the forum complain that one fixed-rate button per direction is "either too sensitive or not sensitive enough" and ask for a proportional, gesture-style slider ([forum thread, *via search excerpt*](https://forum.virtualregatta.com/topic/11225-steering-pc-web-app/)). VR's own release notes advertise "smoother controls" and a zoom-sensitivity setting, which suggests the problem was known ([App Store](https://apps.apple.com/us/app/inshore-by-virtual-regatta/id1182301199)).
- A coach quoted by Yachting World says VR lets sailors "focus solely on strategy and tactics without the distraction of boat handling". Serious sailors treat abstracted boat handling as a feature ([Yachting World](https://www.yachtingworld.com/news/esailing-virtual-regatta-racing-boom-coronavirus-lockdown-126344)).
- Top Sailor reviewers complain about touch controls going unresponsive at intense moments and about the camera changing perspective on its own. Sailboat Championship reviewers report sheet controls that glitch after the tutorial. Yacht Racing Game shipped a fix for "taps not responding". Across the small mobile titles, **responsive input is the most common complaint**.
- In Sailaway, players complain that auto-trim and autopilot routing beat hands-on helming: "No need to know how to helm" ([Steam](https://steamcommunity.com/app/552920/discussions/0/3288067088096215253/?ctp=3)). Automation that beats skill undermines a racing game.

### 2.2 Rule enforcement

| Game | Rules enforced | Penalty mechanic | Notes |
|---|---|---|---|
| Regattatron | Rule 10 (port/starboard), 11 (windward/leeward), 18 (mark room), 22 (OCS, boat must return), 31 (touching a mark) ([regattatron.com](https://regattatron.com)) | *Not public* | The server runs the simulation and has the final say: "Contact is judged on the boats' actual hulls, not on how close you looked" and "nobody's connection decides who fouled whom". Results are "decided by the server, not by argument". |
| VR Inshore | An adapted RRS, the World Sailing "Racing Rules of eSailing" ([Wikipedia](https://en.wikipedia.org/wiki/Virtual_Regatta)). The virtual umpire gives "instantaneous penalties and rule citations" ([Sailing World](https://www.sailingworld.com/racing/going-virtual/)) | A timed speed reduction served straight away, getting longer for repeat offences. **DSQ after two penalties** (Sailing World). Reviews describe a 12 s OCS penalty *plus* having to return, which players call a "double penalty" (*via search excerpt* of App Store reviews) | The rules PDF at [esailing-wc.com](https://esailing-wc.com/wp-content/uploads/2019/01/Virtual_Racing_Rules_220119.pdf) couldn't be fetched because its TLS certificate has expired. |
| PlayeSailing | Includes Rule 13 (while tacking) and Rule 18 (mark room) | Penalties appear in the leaderboard ([App Store](https://apps.apple.com/us/app/playesailing-inshore-racing/id1621745536)) | |
| Yacht Racing Game | Starboard over port, and a tacking boat keeps clear | A collision means disqualification ([App Store](https://apps.apple.com/us/app/yacht-racing-game/id1244722434)) | |
| Top Sailor | Starboard over port, leeward over windward | Collision penalties ([App Store](https://apps.apple.com/us/app/top-sailor/id430948592)) | |
| Sailaway | **None.** Boats can't collide and racing rules aren't enforced ([Steam thread](https://steamcommunity.com/app/552920/discussions/0/1290691937731884425/), [Steam thread](https://steamcommunity.com/app/552920/discussions/0/1473096694452121430/)) | None | Players say anyone who follows the rules loses 30–45 s at a crowded mark. |

**What players say about rules**
- VR Inshore's **most frequent** complaint is unfair penalties:
  - Players say the umpire doesn't check who caused a collision, so right-of-way boats get barged and the victim is penalised.
  - Starboard boats get fouled when a port boat enters the zone.
  - Mark-rounding rulings are wrong.
  - Instant timed penalties reward *forcing* a foul over sailing a proper course.

  See the forum threads ["Rules are bad in this game!"](https://forum.virtualregatta.com/topic/5157-rules-are-bad-in-this-game/), ["Deliberately crashing"](https://forum.virtualregatta.com/topic/16094-deliberately-crashing/) and ["Penalty for maneuvering?"](https://forum.virtualregatta.com/topic/9537-penalty-for-maneuvering/) (all *via search excerpt*). The App Store summary lists "penalty system perceived as unfair". The company says it is "evaluating how the penalties are given with some umpires" (*via search excerpt*).
- Players praise VR for teaching the real RRS. Sailing World calls it "highly addictive" and useful for learning the rules. Yacht Racing Game reviewers call it "great practice for wind shifts and right-of-way rules".
- In Sailaway, having no rules at all is itself the complaint.

### 2.3 Wind and current display

| Game | Wind model | Wind display | Current |
|---|---|---|---|
| Regattatron | Shifts, puffs, and a wind shadow that "costs you a knot" ([regattatron.com](https://regattatron.com)) | *Not public* | None mentioned |
| VR Inshore | Dynamic shifts. Yachting World mentions wind shadow effects | HUD shows TWS, boat speed, VMG and the apparent/true wind angle ([Sailing World](https://www.sailingworld.com/racing/going-virtual/)). **Laylines, Wind Intelligence and a wind-shadow display are paid race helps.** The VIP "PRO Interface" adds a racing compass and a wind-variation indicator ([help centre, *via search excerpt*](https://vrinshore.zendesk.com/hc/en-us/articles/360012434379-What-are-the-benefits-of-a-VIP-subscription)) | None found |
| PlayeSailing | Wind shadow, turbulence and dynamic shifts. Boats use real polars ([App Store](https://apps.apple.com/us/app/playesailing-inshore-racing/id1621745536)) | Not described | None mentioned |
| Top Sailor | Adjustable weather and variable wind | Wind speed and direction on the track map, plus apparent wind and telltale indicators ([App Store](https://apps.apple.com/us/app/top-sailor/id430948592)) | None. It has islands and shoals |
| Sailaway | Real-world forecast weather ([sailaway.world](https://sailaway.world)) | Instruments | **Yes.** Ocean currents come from OSCAR data. Tidal currents are computed from tide phase using player-entered local data ([sailaway.world/sa3_tide](https://sailaway.world/sa3_tide)) |

**Takeaway:** none of the mobile racers found simulate **current**. It's open ground for Regatta, but there's no precedent for showing it on a phone. Ticket 04 should look outside games, for example at tidal-stream atlases and chartplotters. Wind is shown two ways: as numbers (VR's TWA/TWS/VMG) or drawn onto the course (Regattatron's puffs and shadow, VR's paid laylines and wind shadow).

### 2.4 Race length and fleet size

| Game | Race length | Fleet |
|---|---|---|
| Regattatron | Windward-leeward laps. Duration *not public*. Also three-race series | Up to 20 on the start line |
| VR Inshore | About 10 minutes, with a one-minute pre-start ([Sailing World](https://www.sailingworld.com/racing/going-virtual/)). Yachting World says "just a few minutes long". Short formats modelled on the America's Cup and SSL (App Store) | Up to 10 in public races (Sailing World), up to 20 in private club races ([RYA](https://www.rya.org.uk/racing/esailing/)), and a player reports "up to 40" in events (Yachting World) |
| PlayeSailing | Olympic triangle, match race and team race courses | Up to 16 in a private race |
| VR Offshore / Sailaway | Days to months. Sailaway races can have a flexible start window, timed on elapsed time ([FAQ](https://sailaway.world/frequently-asked-questions)) | Hundreds of thousands in VR Offshore events |

### 2.5 Modes

| Game | Modes |
|---|---|
| Regattatron | Fleet race, three-race regatta, 2v2 and 3v3 team racing, 1v1 match racing, and daily scheduled regattas |
| VR Inshore | Public races, eSailing World Championship qualifiers, licensed series, private club races (VIP), and Sailing School lessons. Several boat classes, from foiling cats to dinghies and monohulls ([App Store](https://apps.apple.com/us/app/inshore-by-virtual-regatta/id1182301199), [RYA](https://www.rya.org.uk/racing/esailing/)) |
| PlayeSailing | Ranked Open Events and password-protected private races |
| Single-player titles | Races against AI fleets. Top Sailor adds a random track generator and replays |
| Sailaway | Races, social flotillas and cruises ([FAQ](https://sailaway.world/frequently-asked-questions)) |

### 2.6 Lobby and matchmaking

- **Regattatron** presents its lobby as "a room full of sailors, not a matchmaking queue". Players chat, agree a race and go. Anyone can spawn a race and invite people, and **bots fill empty seats**. There are daily regattas you register for in your own time zone, one ELO ladder and a top-50 board ([regattatron.com](https://regattatron.com)).
- **VR Inshore** puts players into public races automatically. There's a sign-in profile, rankings, and a championship qualifying pathway. Clubs host private races.
- **PlayeSailing** has Elo-ranked Open Events, added in a recent update.
- **Sailaway** runs clubs that schedule races, which players must turn up for. A review site describes the wait as a downside ([Life of Sailing](https://www.lifeofsailing.com/blogs/articles/best-virtual-sailing-simulators-and-games), secondary).
- **Complaints:** VR reviewers report disconnections, lag "when it matters most" and frequent crashes (App Store summary, and search excerpts of reviews). None of the public sources found praise or criticise matchmaking quality directly.

### 2.7 Monetization

| Game | Model | Does paying affect racing? |
|---|---|---|
| Regattatron | Free unlimited racing. **Pro costs $5 a month or $40 a year** and adds a post-race debrief: your track against the boats that beat you, start loss "in seconds and boat lengths", time on the favoured tack and the position ladder. It also adds high-res textures and custom sail graphics. Liveries are recolourable | **No.** It sells analysis and looks, and advertises "Free to race. Pro to find out why you lost." |
| VR Inshore | Free to race. **VIP** is $8.99, with 3/6/12-month terms, or £8.99 a month in the UK. Credit packs cost $2.99–$89.99. VIP brings the PRO interface, unlimited private races and race helps for 3 tokens instead of 4. Race helps (Best VMG, laylines, Wind Intelligence, wind shadow) are paid with tokens. Boat upgrades come from regatta points ([App Store](https://apps.apple.com/us/app/inshore-by-virtual-regatta/id1182301199), [RYA](https://www.rya.org.uk/racing/esailing/)) | **Yes.** Paid helps give tactical information, and the Best VMG help does part of the steering |
| VR Offshore | Credits buy equipment packs (a Full Pack is worth €29.99) and consumables such as "coffee" for stamina ([VR help centre, *via search excerpt*](https://virtualregatta.zendesk.com/hc/en-us/articles/115001449233-Credits-on-Virtual-Regatta)) | Yes. Equipment makes the boat faster |
| PlayeSailing | Free. Skins, coins, memberships and support packs cost $1.99–$19.99 | Mostly cosmetic or convenience |
| Top Sailor | $3.99 to buy, plus cosmetic hull, sail and text IAP at $0.99–$9.99 | No |
| Yacht Racing Game | Free with ads | No. One review mentions a network error that blocks progress gated on watching ads |
| Sailaway III | $15.99 one-off. Boats cost extra. The FAQ says it is "NOT a pay to win game" and that paying can't make a boat faster | No |

**What players say about monetization**
- VR Inshore is repeatedly called **pay-to-win** in App Store reviews. A 2020 Change.org petition ([link](https://www.change.org/p/virtual-regatta-make-virtual-regatta-fair-no-pay-to-win), 19 signatures, closed) says a player has to spend about £11 a week to stay competitive with helps. It asks for helps to be free in custom races, for race hosts to choose which helps are allowed, and for VR to charge for cosmetics instead.
- VR Offshore players argue on Sailing Anarchy that a race "only has integrity if it's a level playing field for a fixed price" ([thread](https://forums.sailinganarchy.com/threads/vend%C3%A9e-globe-2024-virtual-regatta.248632/), *via search excerpt*).
- Sailaway and Regattatron both advertise **not** being pay-to-win. The market is ready to hear it.

### 2.8 Praise and complaints at a glance

| Game | Praised for | Complained about |
|---|---|---|
| VR Inshore (4.1★, 734 US ratings) | Accurate sailing that carries over to real racing, tactical depth, short and busy races, real championships | Unfair or inconsistent penalties, pay-to-win helps, crashes and disconnects, steering sensitivity, no support replies |
| Sailaway III (68 % positive on Steam, 159 reviews) | Realism, real weather and currents, boat design | No racing rules, automation beats helming, long waits for scheduled races |
| Yacht Racing Game (4.4★, 96) | Simple controls, teaches shifts and rules | Taps not registering, AI that breaks the rules, little speed difference between points of sail |
| Top Sailor (3.9★, 35) | Physics and graphics | Touch lag, camera moving on its own, no jib or spinnaker |
| Sailboat Championship (4.3★, 28) | Graphics, tutorial | Sheet control glitches |
| Regattatron | No public reviews found | No public reviews found |

---

## 3. Steal this / avoid this

### Steal this
1. **The server decides fouls, judged on hull contact** (Regattatron). Fairness is the top complaint about VR Inshore. Adjudicate on the server, use real hull geometry, and cite the rule number when a penalty is given, as VR does. → tickets 08, 17
2. **Show the rule number with every penalty** (VR's "instantaneous penalties and rule citations"). Players learn the RRS from it, and it's what they praise most. → 08, 14
3. **One-tap tack and gybe that keeps the same angle to the wind** (VR, Yacht Racing Game), with proportional steering underneath. It fits the "simple boat handling, real tactics" framing. → 12
4. **Bots fill empty seats** (Regattatron), so a race can start on time. → 15, 18
5. **A lobby where people talk, plus scheduled daily regattas in the player's time zone, and one ELO ladder** (Regattatron). → 15, 16
6. **Short races.** About 10 minutes with a 1-minute pre-start (VR), on windward-leeward laps. Fleets of 10–20. → 07
7. **Draw wind onto the water**, with puffs, shifts and wind shadow that has a real speed cost (Regattatron, and VR's laylines and shadow). → 04, 09, 14
8. **Paid tier for analysis and looks only, never speed** (Regattatron Pro: a start-loss breakdown in seconds and boat lengths, time on the favoured tack, the position ladder). Say "not pay-to-win" loudly, as Sailaway does. → 19, 20
9. **Cosmetic liveries that make a boat recognisable at a glance** (Regattatron). → 20

### Avoid this
1. **Selling tactical information or steering help.** VR's token-priced laylines, Wind Intelligence and Best VMG are its loudest monetization complaint. Every player should get the same information. → 14, 19
2. **Penalties that reward barging.** VR's instant timed slowdown, which doesn't check who caused the contact, lets boats force fouls. Base rulings on RRS obligations (keep clear, room, Rule 14), not on contact alone. Watch for players forcing fouls on purpose, which the map already lists under fair play. → 08
3. **Penalising OCS twice** (a time penalty *and* having to return). Choose one. The RRS way is to return. → 07, 08
4. **Hard disqualification after two penalties** (VR). It's harsh on a phone where controls are less precise, and ticket 08 should decide it deliberately. → 08
5. **Fixed-rate arrow buttons** (VR) and **tilt steering** (Top Sailor). Players call the first too twitchy or too sluggish, and the second is unreliable. Reviews also punish input lag and a camera that moves on its own. → 12, 14
6. **No rule enforcement or ghost boats** (Sailaway). Following the rules becomes a disadvantage. → 08
7. **Automation that beats skill** (Sailaway's auto-trim and routing, VR's Best VMG). Any assist has to be available to everyone and must never be the fastest way to sail. → 12, 13
8. **Long waits for scheduled races** (Sailaway) with no quick way into a race. → 15
9. **Losing a race to a disconnect.** VR's crashes and disconnects, some triggered by notifications, are a top complaint. Handle backgrounding and reconnecting properly. → 17

### Open gaps
- Regattatron's controls, HUD, penalty mechanic and race length need an account to see. The user could look at them in person.
- The Racing Rules of eSailing PDF (World Sailing's official adaptation of the RRS for virtual racing) couldn't be fetched. Ticket 02 should get it: [esailing-wc.com PDF](https://esailing-wc.com/wp-content/uploads/2019/01/Virtual_Racing_Rules_220119.pdf).
- No mobile racing game found shows current, so ticket 04 has no game precedent to borrow from.
