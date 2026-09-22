---
id: 2
title: Racing Rules of Sailing relevant to simulated fleet racing
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

Which rules of the RRS 2025–2028 matter for an automatically-adjudicated fleet race, and exactly how are they worded? Cover the Part 2 definitions (keep clear, overlap, mark-room, proper course, zone, tack/gybe), Rules 10–24 (incl. 14 avoiding contact, 15 acquiring right of way, 16 changing course, 17 proper course, 18 mark-room, 19 room at obstructions), starting (26, 29, 30 flags: I, Z, U, black), 28 sailing the course, 31 touching a mark, 44 penalties, and any umpired / eSailing appendices that adapt rules for virtual racing. Flag which rules need judgement a machine can't easily make.

## Context

Findings: branch `research/rrs-for-simulated-fleet-racing`, file `docs/research/rrs-for-simulated-fleet-racing.md`.

## Resolution

Resolved by research; full findings on branch `research/rrs-for-simulated-fleet-racing` in `docs/research/rrs-for-simulated-fleet-racing.md`. Sources: RRS 2025–2028 with 2025 corrections, the 2025–2028 Case Book, the Virtual Racing Rules (VRRS, 2019), the 2025 eSailing Championship notice of race, and the umpired fleet racing appendix (UF).

**What changed in the 2025 rules:**
- Part 2 now ends at rule 23. Exoneration moved to rule 43, and returning/penalty boats keep clear is now rule **21** (was 22).
- *Proper course* now means sailing "the course as quickly as possible", and *obstruction* was reworded.
- Who owes mark-room (18.2) is fixed when the first boat reaches the zone and lasts even if the overlap changes.

**What a machine can judge:**
- Easy: rules 10–13, overlap and clear astern, the zone, 18.1–18.2 (if the state at zone entry is recorded), 21, recalls, the I/Z/U/black flag tests, 28, 31 and the turns in 44.2.
- Hard: 14, 15, 16, 17, 18.4, 19, 20, 23 and "significant advantage" in 44.1(b). They depend on proper course, seamanlike room or hails. Because the game knows its own boat physics, it could test *room* by simulating the best escape manoeuvre.

**Virtual racing precedent:**
- The VRRS drops rules 14, 17, 19 and 20.
- Its penalty is a slowdown; a slowed boat can't get others penalised and casts no wind shadow.
- The game engine is final for Part 2, 28 and 31.
- The umpired appendices add a "last point of certainty" rule, which suits handling network lag.
- The VRRS found is the 2019 edition, though the 2025 notice of race refers to a newer version.

**Bugs in the current engine:**
1. It picks the windward boat by who is further upwind, not which side of the other boat she is on.
2. It changes tack at dead downwind without a gybe, because there is no boom-side state.
3. Start and recall checks use the boat's centre, not any part of the hull.
4. Mark-room is decided at contact by who is nearer the mark and treated as right of way. It is also never applied on opposite tacks.
5. Fouls are only called on contact; rules 15 and 16 and exoneration are missing.
6. Touching any mark at any time is penalised, instead of only the marks of the current leg. The mark penalty is also stacked on a foul penalty from the same incident.
7. Finishing with turns owed is treated as a DSQ. Under the rules the boat hasn't finished yet, and can do its turns and re-cross.
8. There is no warning or preparatory signal and no flag rules.
