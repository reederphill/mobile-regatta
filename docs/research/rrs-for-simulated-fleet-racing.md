# Racing Rules of Sailing for a simulated, auto-adjudicated fleet race

Research for wayfinder ticket [02](../wayfinder/tickets/02-rrs-for-simulated-fleet-racing.md).
Researched 2026-09-22 against World Sailing primary sources (listed at the end).
Rule text is **paraphrased**. Short phrases in quotation marks are verbatim.

## TL;DR

- **The 2025–2028 RRS renumbered Section D of Part 2.** Part 2 now runs from rule 10 to rule 23, not 10 to 24. Exoneration (the old rule 21) moved to **rule 43**. Starting errors, taking penalties and backing a sail are now **rule 21** (was 22). Capsized, anchored or aground is now **22** (was 23). Interfering with another boat is now **23** (was 24). `RacingRule.startingAndPenalties = 22` in `Rules.swift` uses the old number. [RRS pp. 16–22, 30]
- **Two definitions changed on 1 January 2025 through a Changes and Corrections notice.** *Proper Course* now means sailing "the course as quickly as possible" (it used to say "complete the leg … as soon as possible"). *Obstruction* was also reworded. A copy of the printed July 2024 PDF is out of date on both. [C&C v2 p. 3]
- **Rule 18 (mark-room) was restructured in 2025.** Who gets mark-room is fixed at the moment **the first boat reaches the zone**. If the boats are overlapped then, the outside boat owes the inside boat. If they are not overlapped, the boat that had not yet reached the zone owes the other. The obligation lasts even if the overlap later changes. The current engine decides mark-room at the moment of contact from whichever boat is closer to the mark. That is a different rule.
- **Machine-checkable core.** A machine can decide these from geometry and state: rules 10, 11, 12 and 13, the definitions *overlap*, *clear astern*, *zone* and *keep clear (b)*, and rules 18.1 and 18.2 given a recorded zone-entry snapshot. It can also decide rule 21, rules 29.1 and 30.1 to 30.4 (the I, Z, U and black flags are pure hull-in-region tests), rule 31 limited to marks of the current leg, rule 28 via the string test, and the mechanics of the rule 44.2 turns.
- **Rules that need judgement.** These turn on *proper course*, *room* ("seamanlike"), "reasonably possible", "significant advantage" or hails: rule 14, rule 15, rule 16, rule 17, rule 18.4, rules 19 and 20, rule 23 and rule 44.1(b). A simulator has one big advantage over a human umpire: it knows the exact boat dynamics. So *room* and *keep clear* can be approximated by simulating the best avoiding manoeuvre.
- **Precedents for virtual racing.**
  - World Sailing's **Virtual Racing Rules of Sailing (VRRS, 2019)** is used by Virtual Regatta Inshore and the eSailing World Championship. It keeps only definitions, rules 10–13, 15, 16, 18.1–18.2, the old 21 and 22, 26, 28, 29.1, 31, 35 and 44. It **drops** rules 14, 17, 19 and 20. Its penalty is **being slowed**, and a slowed boat "cannot cause another boat to be penalised and has no wind shadow".
  - The 2025 eSailing World Championship notice of race says Part 2 and rules 28 and 31 are enforced automatically by the game engine. Those decisions cannot be protested or used as grounds for redress.
  - **Appendix UF** (umpired fleet racing) and **Appendix C** (match racing) supply useful patterns: a **"last point of certainty"** rule, penalties only when signalled, a one-turn penalty, and a tighter *mark-room*.

---

## 1. Definitions (RRS 2025–2028, pp. 8–12, as corrected)

| Term | Paraphrase | Machine notes |
|---|---|---|
| **Clear astern / clear ahead; overlap** | A boat is clear astern when her hull and equipment in normal position are behind a line abeam from the aftermost point of the other boat. The other boat is clear ahead. They overlap when neither is clear astern, or when a boat between them overlaps both. These terms always apply on the same tack. On opposite tacks they apply only when rule 18 applies between the boats or both are sailing "more than ninety degrees from the true wind". | Pure geometry. The overlap-through-a-third-boat clause needs a transitive check across the fleet. |
| **Keep clear** | A boat keeps clear of a right-of-way boat if (a) the right-of-way boat can sail her course "with no need to take avoiding action", and (b) when overlapped, the right-of-way boat can also change course in both directions without immediately making contact. | (b) is geometric: sweep the right-of-way hull through a short turn each way. (a) needs a notion of "her course" and of what counts as avoiding action. Case 88 says a boat may avoid contact and still fail to keep clear, so **contact is not the test**. |
| **Leeward and windward** | A boat's leeward side is the side away from the wind. When she is head to wind, it is the side that was away from the wind. When sailing **by the lee or directly downwind**, it is the side "on which her mainsail lies". With two overlapped boats on the same tack, the one on the other's leeward side is the leeward boat. | Downwind this needs a modelled **boom side**, not just the sign of the wind angle. |
| **Tack, starboard or port** | A boat is on the tack that corresponds to her windward side. | Inherits the boom-side rule above. |
| **Tacking / gybing** | **Not defined** in the RRS. Rule 13 bounds the tacking period as from passing head to wind until close-hauled. Head to wind and close-hauled take their ordinary nautical sense. Appendix C adds a gybing period for match racing: from the foot of the mainsail crossing the centreline until the mainsail fills or the boat is no longer sailing downwind (C2.7, rule 13.2). | Case 17: the rule 13 period ends on a close-hauled **course**, whatever the boat's speed or sail trim. A heading test is correct. |
| **Mark** | An object the sailing instructions say to leave on a specified side. Also a race committee vessel surrounded by navigable water from which the starting or finishing line extends, and anything intentionally attached. The anchor line is not part of the mark. | The committee boat **is** a mark. |
| **Mark-room** | Room (a) to sail to the mark when her proper course is to sail close to it, (b) to round or pass it as needed, and (c) to leave it astern. | Appendix UF (UF1.8) narrows it to room to sail "no farther than her proper course" to round or pass the mark. That is easier for a machine. |
| **Room** | The space a boat needs in the existing conditions, including space to meet her Part 2 obligations and rule 31, "while manoeuvring promptly in a seamanlike way". | Judgement for a human. For a simulator it is approximable from the known turning and braking dynamics. Case 21 says there is no fixed minimum or maximum. |
| **Proper course** (changed 1 Jan 2025) | The course a boat would choose to "sail the course as quickly as possible" in the absence of the other boats referred to. There is no proper course before her starting signal. | Judgement. Case 14: two nearby boats may have different proper courses. Case 134: it depends on wind, puffs, waves, current and the boat. It can be approximated with polar VMG towards the next mark, but that will sometimes disagree with a human reading. |
| **Obstruction** (changed 1 Jan 2025) | An object a boat could not pass without a substantial course change when sailing straight at it from one hull length away. Also an object that can safely be passed on only one side, or an object, area or line designated by a rule. A boat racing is not an obstruction unless others must keep clear of or avoid her. | Relevant once venues have shorelines or islands. |
| **Continuing obstruction** | An obstruction the shortest boat would pass alongside for at least three hull lengths. A vessel under way, a boat racing, or a race committee vessel that is also a mark is not one. | Geometric. |
| **Zone** | The area around a mark within **three hull lengths** of the boat nearer to it. A boat is in the zone when **any part of her hull** is in it. | Appendix C uses 2 hull lengths and Appendix E uses 4. The number is configurable in practice. |
| **Fetching** | A boat is in a position to pass to windward of the mark and leave it on the required side without changing tack. | Geometric given the polar and the local wind. |
| **Start** | A boat starts when her hull has been entirely on the pre-start side at or after her starting signal, she has complied with rule 30.1 if it applies, and any part of her hull then crosses the line to the course side. | Geometric. |
| **Finish** | Any part of the hull crosses the finishing line from the course side after her starting signal. She has not finished if she then takes a rule 44.2 penalty, corrects a course error made at the line, or continues to sail the course. | Taking penalty turns just past the line un-finishes a boat. It does not disqualify her. |
| **Sail the course** | Start. Then a **string** representing her track, drawn taut, passes each mark on the required side and in order, touches each rounding mark, and passes through gates from the direction of the previous mark. Then finish. A mark that does not begin, bound or end her leg has no required side. | Geometric. Cases 90, 106 and 145 clarify edge cases. |
| **Racing** | From her preparatory signal until she finishes and clears the finishing line and marks, retires, or there is a general recall, postponement or abandonment. | Bounds rules 31 and 44. |

## 2. Part 2, when boats meet (pp. 16–22)

**Preamble.** Part 2 applies between boats in or near the racing area that intend to race, are racing or have been racing. A boat **not racing** is penalised only under rule 14 (with injury or serious damage) or rule 23.1. So before the preparatory signal the rules apply, but nobody is penalised.

### Section A: right of way

- **10 On opposite tacks.** Port keeps clear of starboard.
- **11 Same tack, overlapped.** Windward keeps clear of leeward.
- **12 Same tack, not overlapped.** Clear astern keeps clear of clear ahead.
- **13 While tacking.** After passing head to wind, a boat keeps clear until on a close-hauled course, and rules 10, 11 and 12 do not apply to her during that time. If two boats are both under rule 13, the one on the other's port side, or the one astern, keeps clear.
  - There is **no gybing equivalent** in fleet racing.
  - Case 30: a boat that loses right of way by accidentally changing tack still has to keep clear.

### Section B: general limitations

- **14 Avoiding contact.** If reasonably possible, a boat shall avoid contact, not cause contact between boats, and not cause contact between a boat and an object that should be avoided. A right-of-way boat, or one sailing within the room or mark-room she is entitled to, need not act "until it is clear" that the other is not keeping clear. Rule 43.1(c) exonerates such a boat for breaking rule 14 **if the contact causes no damage or injury**.
  - Case 123: the test is when it would be clear to a "competent, but not expert" helm.
  - Case 26: a right-of-way boat that could then have avoided a damaging collision breaks rule 14.
- **15 Acquiring right of way.** A boat that gains right of way must initially give the other boat room to keep clear. This does not apply if she gained right of way because of the other boat's actions. It is typical after completing a tack or after establishing a leeward overlap from astern (Cases 24, 27, 93).
- **16 Changing course.**
  - 16.1: a right-of-way boat that changes course must give the other boat room to keep clear.
  - 16.2: on a beat, when a port-tack boat is keeping clear by passing to leeward of a starboard-tack boat, starboard must not bear away if that forces port to change course immediately.
  - Case 92: the keep-clear boat need only respond to what the right-of-way boat is doing now.
  - Case 132 defines "on a beat to windward".
- **17 Same tack; proper course.** A boat that becomes overlapped from clear astern within **two hull lengths** to leeward shall not sail above her proper course while they stay overlapped on the same tack within that distance. The exception is when doing so she promptly sails astern of the other boat. Cases 7 and 46 apply.

### Section C: at marks and obstructions

- **Preamble.** Section C does not apply at a **starting mark** surrounded by navigable water, or its anchor line, from when boats approach it to start until they have left it astern.
- **18.1 When rule 18 applies.** Rule 18 applies when boats must leave the mark on the same side and **at least one** is in the zone. It does not apply:
  1. between boats on opposite tacks on a beat to windward,
  2. between boats on opposite tacks when the proper course at the mark is to tack for one boat but not both,
  3. between a boat approaching the mark and one leaving it, or
  4. at a continuing-obstruction mark, where rule 19 applies instead.

  It stops applying once mark-room has been given.
- **18.2 Giving mark-room.**
  - (a) When the **first** of two boats reaches the zone: (1) if overlapped, the outside boat at that moment gives the inside boat mark-room; (2) if not overlapped, the boat that has not reached the zone gives the other boat mark-room.
  - (b) The obligation continues while rule 18 applies, even if the overlap is later broken or a new one begins. Rule 18.2(a) ends if the entitled boat passes head to wind or leaves the zone.
  - (c) When 18.2(a) does not apply and the boats are overlapped, the outside boat gives the inside boat mark-room.
  - (d) An inside overlap gained from clear astern, or by tacking to windward, gives no entitlement if the outside boat has been unable to give room since the overlap began.
  - (e) If there is reasonable doubt that an overlap was gained or broken in time, the presumption is that it was not.
  - Case 2: the boat clear astern can be entitled if she reaches the zone first.
  - Case 25: mark-room is **not** right of way. Once it has been given, rule 11 still governs the inside windward boat.
- **18.3 Tacking in the zone.** A boat that tacks from port to starboard in the zone of a port-hand mark loses 18.2 against a starboard boat fetching the mark. If that boat has been on starboard since entering the zone, the tacker must not make her sail above close-hauled to avoid contact, and must give her mark-room if she gets an inside overlap.
- **18.4 Gybing in the zone.** An inside overlapped right-of-way boat that must gybe to sail her proper course shall sail no farther from the mark than that course needs until she gybes. This does not apply at gate marks.
- **19 Room to pass an obstruction.** A right-of-way boat may choose which side to pass it, giving room to keep clear if she changes course to do so. Overlapped outside boats give inside boats room, unless they have been unable to since the overlap began. At a continuing obstruction, a boat that pushes in from astern without room has no entitlement and must keep clear.
- **20 Room to tack at an obstruction.** A boat may hail "Room to tack" only if she is close-hauled or above and approaching an obstruction that will soon require a substantial course change. She may not hail at a mark that a fetching boat would have to change course for. The hailed boat must respond, either by tacking or by replying "You tack" and then giving room. The notice of race may specify an alternative to the hail (20.4(b)), which suits an app.

### Section D: other rules

When rule 21 or 22 applies between two boats, Section A does not.

- **21.1** After her starting signal, a boat sailing towards the pre-start side of the line or an extension, to start or to comply with rule 30.1, keeps clear of boats not doing so until her hull is completely on the pre-start side.
- **21.2** A boat taking a penalty keeps clear of one that is not.
- **21.3** A boat moving astern or sideways to windward by backing a sail keeps clear.
- **22** If possible, avoid a boat that is capsized (masthead in the water) or has not regained control, is anchored or aground, or is helping someone in danger.
- **23.1** A boat not racing shall not interfere with a racing boat if reasonably possible.
- **23.2** A boat shall not interfere with a boat taking a penalty, sailing on another leg, or subject to 21.1. After the start this does not apply while she is sailing her proper course. Case 149 applies.

## 3. Part 3 and Part 4 (pp. 23–32)

- **26 Starting races.** Warning signal at 5 minutes (class flag). Preparatory at 4 minutes: P, I, Z, Z with I, U or black flag. One-minute signal when the preparatory flag comes down. Start when the class flag comes down. Times are taken from visual signals, and a missing sound is disregarded. The notice of race or sailing instructions may change the timings. The VRRS uses warning at 1:15, preparatory at 1:00 and start at 0.
- **28 Sailing the course.** 28.1: sail the course. 28.2: errors may be corrected until she finishes. Case 112: an uncorrected error is only a breach at the finish. Appendix UF narrows 28.2 to before rounding the next mark or finishing (UF2.1), and makes an umpire DSQ the consequence (UF3.4(c)).
- **29.1 Individual recall.** If **any part of the hull** is on the course side at her starting signal, or she must comply with 30.1, the race committee shows flag X until each such boat's hull has been **completely** on the pre-start side (latest 4 minutes after the start). **29.2 General recall** (First Substitute) may be signalled when boats cannot be identified or the procedure was wrong. A machine can always identify boats, so a general recall is purely a design choice.
- **30 Starting penalties.** Each applies when the flag has been displayed.
  - **30.1 I flag.** Hull on the course side of the line or an extension in the **last minute** → the boat must return round an **extension** to the pre-start side before starting.
  - **30.2 Z flag.** Any part of the hull inside the **triangle formed by the line ends and the first mark** in the last minute → 20% scoring penalty without a hearing. It survives a restart or resail, and is added again for a repeat.
  - **30.3 U flag.** Same triangle → disqualified without a hearing. The DSQ is dropped if the race is restarted or resailed.
  - **30.4 Black flag.** Same triangle → disqualified even if the race is restarted or resailed. The boat's sail number is displayed and she may not sail the restart.
  - All four are pure point-in-region tests over hull points. They are ideal for automation.
- **31 Touching a mark.** While racing, a boat shall not touch:
  - a **starting mark before starting**,
  - a mark that begins, bounds or ends **the leg she is on**, or
  - a **finishing mark after finishing**.

  Touching any other mark is not a breach. Case 77: touching with equipment counts. Case 28 and rule 43.1(a): a boat compelled to touch by another boat's breach is exonerated. Case 95: a boat entitled to mark-room that is forced onto the mark is exonerated. UF2.2 and C2.15 add the crew and ban touching a race committee vessel that is a mark at any time.
- **43 Exoneration.**
  - (a) A boat compelled to break a rule by another boat's breach is exonerated.
  - (b) A boat within her room or mark-room that breaks a Section A rule, 15, 16 or 31 in an incident with the boat owing that room is exonerated.
  - (c) A right-of-way boat or a boat entitled to room is exonerated for a rule 14 breach **when there is no damage or injury**.
- **44 Penalties at the time of an incident.**
  - 44.1: a **Two-Turns Penalty** for a possible Part 2 breach, and a **One-Turn Penalty** for rule 31. The notice of race or sailing instructions may substitute a scoring penalty or another penalty.
  - 44.1(a): a boat that broke Part 2 and rule 31 in the same incident need not take the rule 31 penalty.
  - 44.1(b): if the boat caused injury or serious damage, or gained a "significant advantage" despite the penalty, she must retire.
  - **44.2:** get well clear as soon as possible after the incident, then promptly make the turns **in the same direction**, "each turn including one tack and one gybe". A boat taking the penalty at or near the finishing line must get her hull completely on the course side before finishing.
  - Case 108: a mark-touch turn need not be a full 360°, and it can be combined with rounding if it includes a tack and a gybe.

## 4. Umpired and virtual-racing adaptations

**World Sailing Virtual Racing Rules of Sailing (VRRS).** Published 22 Jan 2019, adapted from RRS 2017–2020 for Virtual Regatta Inshore.

- Keeps the definitions (simplified), 10–13, 15, 16.1, 18.1 and the pre-2021 18.2, exoneration (old 21), 22.1 and 22.3, 26, 28, 29.1, 31, 35 and 44.
- **Omits** 14, 16.2, 17, 18.3, 18.4, 19, 20, 22.2, 23, 24 and all of rule 30.
- Section C does not apply at a starting mark.
- The start sequence is 1:15, 1:00, 0.
- The individual recall is a notification.
- **Rule 44 penalty = "being slowed".** While slowed, a boat cannot cause another boat to be penalised and casts no wind shadow.
- It still uses the old rule 18.2 wording and pre-2025 numbering. No 2025 edition was found (see Open questions).

**2025 eSailing World Championship notice of race** (World Sailing).

- Governed by RRS 2025–2028 as changed by the VRRS, plus the Virtual Regatta Inshore game engine "with the penalty-start counter system".
- NoR 1.2.1: Part 2 and rules 28 and 31 cannot be protested by players, and their penalties are "conducted automatically" by the engine.
- NoR 1.2.2: engine decisions are not grounds for redress.
- In practice World Sailing accepts a game engine as the umpire for exactly the rules Regatta automates.

**Appendix UF, Umpired Fleet Racing** (World Sailing Development Rule DR21-04, v2025). Text read from the February 2025 Open Skiff event edition, which may only choose among the listed options.

- UF1.1: a boat taking or manoeuvring to take a penalty is not sailing a proper course.
- UF1.2: a boat need not take a penalty "unless signalled to do so by an umpire".
- UF1.3: new rule 7, **Last Point of Certainty**. Umpires assume a boat's state, or her relationship to another boat, has not changed until they are certain it has. Appendix C has the same rule (C2.5).
- UF1.8: tighter mark-room ("no farther than her proper course").
- UF3.2: One-Turn Penalty for Part 2.
- UF3.4: umpire-initiated penalties for rule 31, rule 42, advantage gained despite a penalty, sportsmanship, and failing to take a penalty correctly. A rule 28.2 failure brings DSQ.
- UF3.5: signals are green-white (no penalty), red (penalty) and black (DSQ).
- UF5.1: no proceedings over umpire actions.
- Rule 14 goes to a hearing only with damage or injury.
- Fleet size is capped at 25 boats with at least 1 umpire boat per 5 boats. This shows that humans find fleet umpiring hard to scale.

**Appendix C (match racing) and Appendix E (radio sailing)** add options worth borrowing.

- C: zone of 2 hull lengths, a gybing extension to rule 13, rule 17 deleted, a simpler rule 18 that resets when the entitled boat leaves the zone, and rule 18.3 limits on tack or gybe speed.
- E: zone of 4 hull lengths, and a one-turn penalty for both Part 2 and rule 31. Under E4.3 a boat that gains an advantage despite a penalty takes **additional one-turn penalties until the advantage is lost**, rather than retiring. That is a machine-friendly replacement for the "significant advantage" judgement.

## 5. Machine adjudicability

| Rule | Machine-decidable? | What is hard, and a suggested approximation |
|---|---|---|
| Defs: overlap, clear astern, zone, fetching, start, finish, sail the course | Yes | Use **all hull points**, not the boat centre. Overlap on opposite tacks only under rule 18 or when both boats are more than 90° from the true wind. |
| Def: leeward/windward, tack | Yes, once the boom side is modelled | By the lee and dead downwind need a mainsail-side state with hysteresis. |
| 10, 11, 12, 13 | Yes | Deciding **when** a breach happened needs a keep-clear test (below), not contact. Case 30: use the relationship **just before** contact. |
| Keep clear (b) | Yes | Sweep the right-of-way hull ±N° over about 0.5 s. |
| Keep clear (a) | Partly | "Need to take avoiding action": project both tracks forward, and flag when the right-of-way boat must deviate from her current course to avoid contact. |
| 14 | Mostly moot | With no damage model, rule 43.1(c) always exonerates the right-of-way boat. Enforcing 14 on the keep-clear boat duplicates Section A. The VRRS omits it. |
| 15, 16.1 "room to keep clear" | Judgement ("seamanlike") | Simulate the keep-clear boat's best manoeuvre with the real dynamics (max rudder, known turn rate). If none avoids contact, the right-of-way boat breaks the rule and the keep-clear boat is exonerated under 43.1(b). |
| 16.2 | Mostly | Needs "on a beat" (Case 132) and "port is passing to leeward". |
| 17 | Judgement (proper course) | Approximate proper course as the target-VMG heading to the next mark. Or drop the rule, as the VRRS and Appendix C do. |
| 18.1, 18.2 | Yes, with state | Record a **zone-entry snapshot** per pair: who reached the zone first and the overlap state then. Keep it until mark-room is given, the entitled boat passes head to wind or leaves the zone, or the boats leave the mark astern. The 18.1(a)(2) exclusion needs "proper course is to tack". The 18.2(d) "unable to give room" condition needs the room simulation. 18.2(e) reasonable doubt ≈ last point of certainty. |
| 18.3 | Yes | Fetching is geometric. |
| 18.4 | Judgement | "No farther than needed". |
| Mark-room (as a quantity) | Judgement | UF's narrower "no farther than proper course" is easier. Otherwise use a corridor around the mark. |
| 19, 20 | Hard | Needs obstructions and hails. Only relevant if venues have shorelines or islands. 20.4(b) allows a button instead of a hail. The VRRS omits both. |
| 21.1, 21.2, 21.3 | Yes | "Taking a penalty" needs a clear start-of-penalty state. |
| 22 | N/A unless capsize is modelled | |
| 23.2 | Partly | The proper-course exception is judgement. |
| 26, 29.1, 30.1–30.4 | Yes | Hull-in-region tests over the last minute. |
| 28 | Yes | String test, or an ordered gate crossing as now. |
| 31 | Yes | Limit to starting marks before starting, marks of the current leg, and finishing marks after finishing. Exonerate when pushed by a boat that broke a rule. |
| 44.1(b) "significant advantage" | Judgement | Use the Appendix E-style extra turns, or UF3.4(a)(3). |
| 44.2 | Yes | Turns in one direction, each including a tack and a gybe, and "promptly" (a timeout). Treat "well clear" as a distance threshold. |

**Server authority and latency.** Rule 18.2(e) (reasonable doubt → no overlap) and UF/Appendix C rule 7 (last point of certainty) give a principled basis for hysteresis. Only flip overlap, tack or zone state after it has held for a few ticks or a margin. This hides jitter from network reconciliation.

## 6. Where the current engine simplifies or gets it wrong

References are to `Packages/RegattaCore/Sources/RegattaCore/`.

1. **Wrong windward/leeward test.** In `Rules.swift:63–66` the windward boat is whichever is further **upwind** (a dot product with the wind vector). The RRS test is **which side of the other boat** she is on. Two close-hauled boats at 45° illustrate the problem: if the leeward boat's bow is d metres forward and s metres to leeward, she projects further upwind whenever d > s. The engine then calls her "windward" and penalises the wrong boat. Use the lateral offset relative to the boats' headings, with a cross product against `forward`.
2. **Tack flips at dead downwind.** `Boat.tack` (`Boat.swift:71`) comes from the sign of the relative wind. The RRS uses the mainsail side when by the lee or dead downwind. A boat sailing a few degrees by the lee changes tack, and so rule 10 status, without gybing. A boom-side state is needed.
3. **Rule numbering is from the old edition.** `startingAndPenalties = 22` should be **21** in 2025–2028. The title "Returning or penalised boats keep clear" matches 21.1 and 21.2.
4. **Rule 21.1 is over-applied.** Every `.ocs` boat is made keep-clear (`Rules.swift:37`). The rule applies only while she is **sailing towards** the pre-start side. Clearing uses the boat centre (`Race.swift:307`) where the rule needs the hull **completely** on the pre-start side.
5. **OCS detection uses the boat centre.** `fireGun` (`Race.swift:287`) tests `lineSide(position) > 0`. Rule 29.1 is **any part of the hull**. The start crossing (`crossing` of the centre, `Race.swift:296`) is also centre-based, where the definition Start is "any part of her hull".
6. **Rule 18 is decided at contact time, not zone entry.** `sharedMarkInZone` plus "nearer boat is inside" (`Rules.swift:54–58`) departs from the rule in several ways:
   - (a) it ignores 18.2(a) and (b), where the relationship is **frozen when the first boat reached the zone**;
   - (b) it needs **both** boats in the zone, where the rule needs at least one;
   - (c) it uses the centre, where the rule uses any part of the hull;
   - (d) it never applies on **opposite tacks**, although rule 18 does apply there except on a beat, for example at the leeward mark while gybing;
   - (e) it treats mark-room as right of way. Case 25: an inside windward boat that sails outside her mark-room is still bound by rule 11;
   - (f) it misses Case 2, where the boat clear astern reaches the zone first;
   - (g) it has no 18.3 and no exclusion for "one boat's proper course is to tack".
7. **Fouls exist only on contact.** Fouls are judged only on first hull contact, with a 5 s per-pair cooldown (`Race.swift:241–249`). The RRS has no contact requirement (Case 88). Near misses where the right-of-way boat had to alter course go unpunished, and a right-of-way boat that holds course and hits is safe. That boat is exonerated anyway under 43.1(c) without damage. **Rules 15 and 16 are absent.** A port-tacker completing a tack right under a starboard boat's bow gains full rights as soon as she is close-hauled. Exoneration under 43.1(a) and (b) is absent too.
8. **Rule 31 is over-applied.** `resolveObstacleContacts` (`Race.swift:258–277`) penalises touching **any** mark at **any** time. That includes the leeward mark on a beat (it is 70 m up the course and does not bound the beat), both marks before the gun, the committee boat after starting, and marks touched because another boat's breach pushed the boat into them (Cases 28 and 95). It also stacks a rule 31 turn on top of a Part 2 penalty from the same incident, which 44.1(a) waives.
9. **An unserved penalty at the finish means DSQ.** `finish` (`Race.swift:334–340`) disqualifies a boat that crosses with turns owed. Under the definition Finish, a boat that takes her penalty after crossing **has not finished** and may complete the turns and re-cross. Under 44.2 she must be completely on the course side before finishing. DSQ-on-cross is harsher than the RRS. Appendix UF's automatic DSQ exists only for failing to take a penalty.
10. **Penalty mechanics are loose.**
    - `penaltyProgress` counts net heading change. 360° in one direction does include a tack and a gybe, so the core test is sound.
    - There is no "get well clear" or "promptly".
    - 21.2 kicks in only after 30° of turning (`Boat.swift:80`), which is a reasonable "has begun" trigger.
    - Turns are capped at 4 with no RRS basis. Rule 44.1(b) would require retiring.
11. **Start sequence.** The start sequence is a 60 s countdown with only a gun (`Race.Config.prestartSeconds`). There is no warning or preparatory signal, and no I, Z, U or black flags or general recall. The start of *racing* (the preparatory signal) is undefined, so rule 31 and Part 2 penalties technically should not apply before it.
12. **Rule 28 via ordered gate rays** (`Course.gates`, `Race.swift:312–325`) is a reasonable string-test approximation and allows correction (28.2). It is fine as it is.
13. **Rule 13** (`Race.swift:210–216`) is consistent with Case 17 (it is heading based). Both-boats-tacking falls through to rule 10, where the RRS says the boat on the other's port side or astern keeps clear. That is a small gap.

## Open questions

- **Is there a 2025 VRRS?** The 2025 eSailing WC notice of race links "VRRS" to `sailing.org/our-sport/esailing/`, but the only VRRS document found is the January 2019 edition (RRS 2017–2020 based). The live Virtual Regatta Inshore rule set may have moved on. Worth asking World Sailing (`rules@sailing.org`) or checking in-game.
- The canonical World Sailing DR21-04 template was only available as a .docx. It was not opened, per the no-downloads constraint, so the text above is from an event edition that follows the template's options. Wording may differ slightly in options not chosen by that event.
- Racing Rules of Sailing web app pages (racingrulesofsailing.org) returned 403 and were not used.

## Sources

- World Sailing, *The Racing Rules of Sailing 2025–2028* (July 2024). https://media.sailing.org/sailing/wp-content/uploads/2024/07/05091216/RRS-2025-2028-Final.pdf (landing page https://www.sailing.org/document/2025-2028-racing-rules-of-sailing-july-2024/). Definitions pp. 8–12, Part 2 pp. 16–22, Part 3 pp. 23–27, rules 43–44 pp. 30–32, Appendix C pp. 73–76, Appendix E pp. 95+, Race Signals inside cover.
- World Sailing, *Changes and Corrections to the RRS 2025–2028*, Version 2. https://www.sailing.org/wp-content/uploads/2024/12/Changes-and-Corrections-Version-2.pdf (changes to *Proper Course* and *Obstruction* effective 1 Jan 2025).
- World Sailing, *The Case Book for 2025–2028* (v2025-07). https://media.sailing.org/sailing/wp-content/uploads/2025/07/31104846/WS-Case-Book-2025-2028-v2025-07.pdf. Cases cited: 2, 7, 14, 17, 21, 24, 25, 26, 27, 28, 30, 46, 77, 88, 92, 93, 95, 108, 112, 123, 132, 134, 149.
- World Sailing, *DR21-04 Appendix UF Umpired Fleet Racing* v2025. https://www.sailing.org/document/dr21-04-appendix-uf-umpired-fleet-racing-word/. Text read from the Open Skiff edition (Feb 2025): https://www.openskiff.org/wp-content/uploads/2025/04/DR21-04-Appendix-UF-Open-Skiff-v2025-clean_.pdf
- World Sailing, *The Virtual Racing Rules of Sailing* (22 Jan 2019). https://d2cx26qpfwuhvu.cloudfront.net/sailing/wp-content/uploads/2022/02/25122529/Virtual_Racing_Rules_220119.pdf (World Sailing media CDN).
- World Sailing, *2025 eSailing World Championship Notice of Race*. https://media.sailing.org/sailing/wp-content/uploads/2025/02/05015926/2025-eSailing-World-Championship-Notice-of-Race.pdf (sections 1.1–1.2).
