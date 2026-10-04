#if canImport(Glibc)
import Glibc
#endif

// ADR 0002: a race log is replayed by the simulation version that produced it, and the server's
// Swift toolchain and C library are part of that version. Trig comes from the platform libm
// (glibc on the server), so libm is pinned with the C library rather than replaced by our own.

/// Bumped by hand whenever simulation output changes: physics, rules, wind, tick rate, or
/// anything else a golden digest would see. Add the new row to `Tests/Goldens.json` with it.
/// The golden replays a fixed input log with no bot brains (ADR 0002), so retuning bots never moves it.
///
/// 2: the wind is keyed by its own seed, not the race seed; held inputs are int8 (#59).
/// 3: keyed wind (#75). The wind is a `WindField` of the public `WindSetup` (classic-oscillating@2, stub
///    pairing; the course laid square to its mean direction) and the key chain `WindKeyGenerator` makes
///    from the wind seed by HMAC-SHA256. Window origin: `WindWindows(startSequenceTicks:)`, 900 ·
///    (⌈startSequenceTicks / 900⌉ + 1) ticks before the gun, so knots fall on whole windows from the gun
///    and the race starts in window 1. First knot: `WindField.firstKnot` (no shift, base strength, level)
///    at the origin, never sampled by a race. No puffs until #76.
/// 4: boats carry no names (bot names moved to the roster outside the sim), so the digest no longer
///    hashes them; bot brains left `Race` for RegattaBots' seat controllers (#60).
/// 5: boats sail their class file (#70): `BoatDynamics` with the class's momentum, steering, rudder
///    drag and slew, head-to-wind fall-off and ease; the polar table, hull outline, shadow cone and
///    contact factors of ilca-dinghy@1.
/// 6: keyed puffs and lulls (#76). Each window's key spawns them from its `puffSeed` (`PuffPlan`,
///    stream "windpuff") in the race area, which `Race` sets to `RaceArea.placeholder(around:)` until
///    #80; the count is calibrated from the conditions' coverage. They fade in and out, drift downwind at
///    their drift × base strength and fan the direction; `WindField.sample` adds them on top of the
///    clamped channel speed, and needs the keys back to the oldest window whose puffs may be alive.
/// 7: the boom (#71). Each boat has a boom side and her tack follows it; the boom crosses at head to wind
///    or past the class's by-the-lee limit, and by the lee she sails the mirrored polar less the class's
///    penalty. The tap steers to the same wind angle with the boom on the other side. Tacked and gybed
///    events. Boats sail ilca-dinghy@2 (turn rate curve, rudder drag and no-go time constant retuned).
/// 8: race assembly (#81). A race is built from the files its setup names (`RaceFiles`) and sails the
///    derived `CourseLayout` (#80): windward, offset mark, leeward gate, the line on the pairing's start-line
///    centre sized for the fleet, and its race area for the puffs. The prototype placement is laid square
///    to that line. `WindField.sample` composes the pairing's geographic grid (#77). The log header records
///    the files and the tide state at the gun.
/// 9: right of way (#87), on the assembled race of 8: rules 10–13 with windward by side of boat (her boom
///    side is her leeward side), both tacking (port side or astern keeps clear); overlap (incl. opposite
///    tacks both more than 90° from the wind, and a boat between) counted once it has held for the last
///    point of certainty (15 ticks) per pair, updated after the boats move and before contacts, and in the
///    digest. Ghosts have none.
/// 10: sailing in current (#79), on 9. Every boat has three winds (`BoatWinds`): over the ground, sailing
///    (ground less the current at her position, the race's `CurrentField` from its venue and tide state
///    at the gun) and apparent (sailing less her velocity through the water). The polar, her tack angle and
///    the rules read the sailing wind, and the current carries every boat, ghosts too. The shadow cone
///    follows the caster's apparent wind, and a backwind zone reaches to windward of her (`ShadowCone`),
///    both under the class's stacking floor. The digest hashes the three winds and the current.
/// 11: the autohelm (#230, ADR 0007), on 10. A centred rudder no longer holds the heading: the autohelm
///    captures her sailing angle on the tick the held rudder centres (every boat at the first tick), snaps
///    to the groove within the class's snap widths and bears away to it from the no-go zone, and steers the
///    rudder in proportion to the angle's error; the tap sails to the groove on the new tack. Boats sail
///    ilca-dinghy@3 (schema 2: the autohelm's values); schema-1 classes are refused. The digest hashes
///    the autohelm's target and tap in place of the tack autopilot's heading and boom side.
/// 12: the skiff (#248), on 11. Boats sail skiff@1 (schema 3) by default, three laps. A schema-3 class
///    planes (on and off the plane with hysteresis on speed and apparent wind angle, an off-plane branch
///    of the polar), hoists and drops an automatic spinnaker (two-sail speed without it and through a
///    hoist or drop), loses speed by the degree by the lee (the spinnaker collapsing), and its autohelm's
///    grooves follow a running average of the wind strength at the boat. Schema-2 classes (ilca-dinghy@3)
///    sail as on 11. The digest hashes planing, the spinnaker and the averaged wind.
/// 13: race area boundary and land contact (#82), on 12. After obstacle contacts, every boat on the
///    course is moved out of the venue's land in the race area and back inside its boundary
///    (`RaceEdges.resolve`); heading into the edge she keeps her speed along it, the course's
///    `edgeSpeedRetention` of it as the touch begins, which lasts until she is `RaceEdges.touchMargin`
///    clear of it. No penalty; the touch is announced and recorded. The autohelm has no special case
///    there. The prototype placement is squeezed towards the line to keep every boat a hull length
///    inside the area.
/// 14: start row and OCS by hull (#85), on 13. The prototype placement is gone: every boat starts the
///    sequence in one row half a line length below the line, in slots over 1.5 line lengths, the order
///    shuffled from the race seed's own stream ("startrow"), on starboard reaching towards the pin at polar
///    speed in the base strength, her rudder centred so the autohelm holds the reach (#219). The row is
///    squeezed towards the line only where the race area or its land needs it (#82's squeeze, moved onto
///    the row), its neighbours never closer than the rules file's start-row spacing floor (fleet-rules@2,
///    the default from #85; a schema-1 rules file has none). OCS, clearing and starting read every hull
///    point, not the centre: OCS if any is on the course side at the gun, cleared once all are on the
///    pre-start side, started when any crosses the line itself after the gun. Rule 21.1 applies to an OCS
///    boat only while she moves towards the pre-start side (`CourseLayout.isReturning`).
/// 15: race close, ghosts and scoring (#86), on 14. The race closes at the finish window after the first
///    finish, capped by the time limit after the gun, both from the race format (120 s and 960 s; it was
///    180 s after the first finish, with no limit), a boat crossing on the close tick still finishing; or at
///    once when no boat is racing or able to, or every human has gone (`Race.closeAllGone`). Only a finisher
///    opens the window: a DSQ at the line no longer does. A ghost is a finished or DSQ boat (an OCS or
///    never-started one from the close, `Race.isGhost(seat:)`); `dnf` is gone, and a boat still racing at the
///    close keeps `racing`. The results score finishers, then by distance to finish round the remaining
///    marks, DSQ, OCS and RET, and standings rank boats racing by that distance, with no stage bonus.
/// 16: incidents (#88), on 15. A ruling is triggered by contact or by a near miss: an overlapped pair where
///    the right-of-way boat, swept ±10° from her heading and sailed on in a straight line for 0.5 s while
///    the other holds her course (fleet-rules' `incidents.nearMissSweep`), would hit. Near misses are the
///    authoritative race's alone. One incident per pair until their hulls are more than 2 hull lengths
///    apart (`incidents.separation`), held in the umpire's memory; the 5 s foul memory the world carried is
///    gone. Contacts are announced (`contact`). Rule 21 still overrides Section A.
/// 17: penalty turns (#89), on 16. A call (a foul, or a mark touch under rule 31) costs one turn, not a foul's
///    two; owed turns add up with no cap (the cap of 4 is gone) and are served in order. Each turn is 360° one
///    way: `penaltyProgress` is the current turn's, a turn back gives it up, a full turn serves it and the
///    excess carries on. Each turn has a clock (`Boat.penaltyClockTick`): started 30° by the rules' start
///    deadline and completed by their complete deadline after it (fleet-rules@3, the default: 20 s and 40 s;
///    15 s and 30 s in @1 and @2), or DSQ and a ghost at that tick (`missedStart`, `missedComplete`), in the
///    authoritative race. The rules file's `stackedPenaltyDeadlines` says when a queued turn's clock starts:
///    `sequential` (fleet-rules@3: at the later of its call and the previous turn's completion) or `fromCall`
///    (schema 1 and 2 files, fleet-rules@1 and @2). Only a tick the player steers (rudder off centre, or the
///    tap) completes or gives up a turn; the autohelm holding her moves it neither back past its start nor
///    onto the full turn. Crossing the finish line owing a turn no longer disqualifies: she doesn't finish.
///    Boats sail skiff@2 by default, skiff@1 turning quicker (36°/s from 1.5 kn, a 10°/s floor, rudder drag
///    0.4 a second): a hard-over 360 in open water takes about 10 s, not 14–22 s.
/// 18: rule 18 mark-room (#91), on 17. The overlap terms apply on opposite tacks between boats rule 18 applies
///    between (`Rules.markRoomApplies`: racing to the same mark, the nearer of a gate's two or of the finish
///    line's ends, some of either's hull within the zone's 3 hull lengths of it, and not on opposite tacks both
///    on a beat), so the digested overlaps change at marks. `Rules.judge` loses the mark-room shortcut (nearer
///    the mark at contact, both in the zone): mark-room is not right of way, and rules 21 and 10–13 decide every
///    call. The umpire keeps rule 18's records (18.2(a)–(c), 18.3) and announces each (`markRoomNotice`); no
///    call reads them yet (#93).
/// 19: the escape simulation (#92), on 18. Under a schema-4 rules file (fleet-rules@4, the default) the umpire
///    records every boat over the last few seconds, and an incident whose right-of-way boat acquired right of
///    way within `initially` (2 s), not by the other's own action, or turned faster than `changesCourse`
///    (12°/s) in the last 2 s, is judged by sailing the keep-clear boat on through each candidate input for the
///    2 s horizon against the other's track: with no escape, rule 15 or 16.1 (16.1 only if holding her course
///    would have left one) is called on the right-of-way boat and the other is exonerated (43.1(b), on the
///    incident). Schema-1 to -3 files run none: their races sail as on 18.
/// 20: rule 16.1 on the incident's tick (#273), on 19. A course change first seen in the step to the incident
///    no longer falls through to the Section A call for want of a tick to answer in: had the right-of-way boat
///    held her course from the tick before, the keep-clear boat, clear of it on the incident's tick, answers
///    from that tick with the escape candidates, as she does from an earlier change's tick; with an escape,
///    16.1 on the right-of-way boat and the other exonerated. The golden sails fleet-rules@1, which runs no
///    escape simulation.
/// 21: the pressure field (#286, ADR 0008), on 20. Schema-3 conditions files (the version-4 files, which
///    dev-venue@4 pairs) add a stateless pressure side and pressure lanes, keyed per 30 s window from each key's
///    `puffSeed` on their own streams and laid across the pairing's across-the-wind coordinate (`Venue.AcrossWind`,
///    derived at load from its geographic grid): `WindField.sample` scales the speed and bends the direction by
///    them after the geographic grid and before the puffs, and needs keys further back (`PressurePlan.lookback`).
///    Schema-1 and -2 files have no pressure field: their races sail as on 20.
/// 22: venue geography (#287, ADR 0008), on 21. Schema-2 venue files (dev-venue@5, on the schema-4 version-5
///    conditions files) give each pairing's geographic grid a signed speed change in place of the speed factor,
///    lane spots and a side tendency: a share of lanes forms at the spots (`presspot` stream), and window 0's key
///    draws the race's multiplier on the tendency (`prestend`), added to every pressure side target, so the wind
///    needs window 0's key throughout. The bot-suite matrix moves to dev-venue@5 and the version-5 conditions.
///    Schema-1 venues have no spots or tendency, draw nothing more and use their speed factor as written: their
///    races, the default race's included, sail as on 21.
/// 23: puffs and lulls form from the pressure field (#288, ADR 0008), on 22. Schema-5 conditions files (version 6,
///    on dev-venue@6) draw `pressureField.puffChoices` places for each puff and lull (`puffplce` stream) and form it
///    at the one with the most pressure at its spawn tick (a lull, the least), at about a third of version 5's
///    coverage. The pressure field's knots are cached per window rather than worked out each tick, bit for bit the
///    same. The bot-suite matrix moves to dev-venue@6 and the version-6 conditions. Older files draw nothing more:
///    their races, the default race's included, sail as on 22.
/// 24: momentum, shadow cost, tack cost and the roll tack (#263), on 23. Races sail skiff@3 by default: momentum
///    speeding up 2.5 s and slowing down 10 s (#220, the owner #263), rudder drag 0.25, and its wind shadow a speed loss
///    (`WindShadow.slowingDown`): her polar reads the clean wind, her target is the polar × (1 − 0.48 × cone depth),
///    stacked no lower than 0.3, and she slows to it at 2 s. A second tack/gybe tap during a tack is the roll
///    (`BoatClass.RollTackTuning`, `Boat.roll`, `Boat.tackCrossingTick`): within 0.25 s of the boom crossing a hit
///    keeps half of each tick's speed loss until close-hauled, outside it a miss multiplies her speed by 0.8; roll
///    hit and roll miss events. Boats carry the roll and the crossing tick in the digest and the wire snapshot.
///    Classes without the new fields (every file before skiff@3) sail as on 23.
/// 25: pressure lanes are finite patches (ADR 0008), on 24. Schema-6 conditions files (version 7, on dev-venue@7) give
///    `pressureField.lanes` a length along the wind, a drift down it and a share that weaken the wind: each lane is an
///    ellipse that moves down the course, its length, mid-life place along it, drift and weak coin drawn from the
///    `presalng` stream (the lane draws before it stay as they were), so the pressure changes up the course as well as
///    across it, and puffs and lulls, which form where the field is at their spawn, gather in the strong patches and
///    keep out of the weak. The bot-suite matrix moves to dev-venue@7 and the version-7 conditions. Older files draw
///    nothing more: their races, the default race's included, sail as on 24.
/// 26: the backwind astern on the windward quarter (#298), on 25. Races sail skiff@4 by default: its backwind is a right
///    trapezoid from her windward stern corner (read off the hull outline), 1 hull length out along the stern, 2 astern
///    on its outer edge and 1.5 on its inner one, following her heading and windward side (it swaps at the boom
///    crossing), not her apparent wind; its loss, 0.2 at the stern edge, fades to nothing at the far edge
///    (`ShadowCone.backwindFactor(at:)`). A boat to windward and ahead of her is no longer in it. Classes without the
///    inner length (every file before skiff@4 and ilca-dinghy@4) keep #79's band and sail as on 25.
/// 27: ladder distance (#267), on 26. Boats racing rank by `Race.ladderDistanceToFinish(of:)` in place of the path
///    length: on the beats and runs their distance to the leg's target along the course axis (fixed for the race, so
///    boats on one ladder line are level however far apart across the course), on the W → O reach straight along the
///    leg, then each later leg the same way. It sets `standings()`, `place(of:)` and the by-distance places in the
///    results at the close, and `Race.gapToLeader(of:)` reads it. Boat state and the digest don't move; races whose
///    close places boats by distance can place them differently from 26.
/// 28: rule 31, marks of the leg (#90), on 27. Only a mark of the leg a boat is sailing (`CourseLayout.isRule31Mark`:
///    the mark or gate her leg rounds, the finish line's ends on the finish leg, and the start line's ends before
///    she has started) costs a penalty turn and a `markTouch`; any other touch (the gate marks on the second beat
///    and the final run, the windward mark on the reach) is an `obstructionContact` of the new kind `.mark`: slowed
///    as before, no penalty, recorded in `IncidentIndex.obstructionContacts`. 44.1(a): a touch and a foul in one
///    open incident cost one turn between them, either order: a touch while she is the offender of an open call
///    is an obstruction contact, and a call against a boat within the separation of her penalised touch since
///    owes no turn (`turnsOwed` 0).
/// 29: protests and the incident index (#94), on 28. A protest is linked to the pair's latest incident when its last
///    contact (or its opening, for a near miss) was within the protest window before it, inclusive, and recorded in
///    `IncidentIndex.protests`; `protestRecorded` carries the matched incident's id and goes to the protester alone.
///    The index also records every boat contact (`contacts`), every penalised mark touch (`markTouches`) and
///    each incident's trigger (contact or near miss), and a race's log carries it (`RaceLog.incidentIndex`). Boat
///    state, the calls and the digest don't move; the events, the index and the log's JSON do.
/// 30: the shadow reshaped (#298 follow-up, the owner's playtest), on 29. Races sail skiff@5 by default, and its cone starts
///    from her bow and stern, not a line across her centre (`ShadowCone.nearEdge`, `coneFromBowAndStern`): its near edge is
///    the hull's line, so it follows her heading across the wind, and it fades with distance and to its sides as before. It is
///    10 hull lengths long and 6 wide at its end, and its axis is swung half the way from downwind towards straight astern
///    (`BoatClass.WindShadow.coneSwing`), so it opens behind her.
///    Its backwind trapezoid has its stern edge turned steep (level with her stern on the hull side, 1.25 hull lengths
///    astern outboard) and its far edge flat, 2 astern, 1 wide, its loss 0.2 full along the stern edge and fading to
///    nothing at the far edge (`BoatClass.WindShadow.backwindSpan(out:)`). Its length astern scales with her speed
///    through the water, full size at 6 knots, to 1.5 times at 9 and nothing when stopped (`backwindScale(speed:)`),
///    and she loses it gradually across a reach, full at 90 degrees true wind angle and none from 115, running (`ShadowCone.backwindPresence`). Files without
///    the new optional fields (skiff@4, ilca-dinghy@4 and before) sail as on 29, bit for bit.
/// 31: rule 17 (#345), on 30. Under a schema-5 rules file (fleet-rules@5, the new default) the umpire records each pair
///    whose leeward boat became overlapped from clear astern within two hull lengths on the same tack
///    (`UmpireState.updateProperCourse`), and an incident on such a pair is rule 17 on the leeward boat, the windward
///    boat exonerated, when the leeward boat was above her proper course (`ProperCourse`: the upwind groove on a beat,
///    the bearing to the mark on a reach, to the further gate mark or line end on a run, kept to the downwind groove)
///    by more than the tolerance (5 degrees on a beat, 8 on a reach or run), not promptly sailing astern (both
///    projected at their velocities, clear astern within 4 s), and the windward boat on her own track was clear of
///    the leeward boat's proper-course path (`EscapeSimulation.verdict`). Rule 17 wins over rules 15 and 16.1; otherwise
///    the chain runs as on 30. Rules files before schema 5 sail as on 30, bit for bit.
/// 32: compelled breaches and mark-room calls (#93), on 31. Under a rules file with an escape simulation (schema 4 and
///    later): a boat compelled by another's breach is exonerated (43.1(a)): when the boat she breaks a rule against, or
///    the mark of her leg she touches, is one the escape simulation finds she had no way clear of without hitting the
///    boat that fouled her (an open incident, called on that boat with her the victim, within the recorded track), yet
///    a way clear of it alone. The incident is then no call (no penalty, no event), or the touch an obstruction contact
///    with her exonerated on the foul's incident. An incident whose Section A call names the boat entitled to
///    mark-room by the pair's rule 18 record is rule 18.2 (or 18.3) on the owing boat, the entitled boat exonerated
///    (43.1(b)), unless the entitled boat gained her inside overlap from clear astern or by tacking and the owing boat
///    had no escape from the tick it began (18.2(d)): then the Section A call stands, the owing boat exonerated. A mark
///    touch in an open mark-room incident called on the other boat is exonerated (Case 95). Rules files before
///    schema 4 sail as on 31, bit for bit.
public let simulationRevision = 32

/// The race server's platform: the pinned image in `scripts/linux-test.sh`
/// (`swift:6.3.3-noble`, `linux/amd64`, glibc 2.39). Only results on this platform are
/// authoritative; clients just have to be close enough for prediction.
public let replayPlatform = "swift-6.3.3/glibc-2.39/x86_64"

/// The toolchain, C library and architecture this build runs on.
public let simulationPlatform = "\(toolchainID)/\(libcID)/\(architectureID)"

/// Tags every race log. A replay needs a build whose version matches exactly.
public let simulationVersion = "\(simulationRevision)/\(simulationPlatform)"

/// Whether this build's results are the authoritative ones that golden digests pin.
public var isReplayPlatform: Bool { simulationPlatform == replayPlatform }

private let toolchainID: String = {
    #if compiler(>=6.3.3) && compiler(<6.3.4)
    return "swift-6.3.3"
    #else
    return "swift-unpinned"
    #endif
}()

private let libcID: String = {
    #if canImport(Glibc)
    var buffer = [CChar](repeating: 0, count: 64)
    let length = confstr(Int32(truncatingIfNeeded: _CS_GNU_LIBC_VERSION), &buffer, buffer.count)
    guard length > 0, length <= buffer.count else { return "glibc-unknown" }
    let name = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return String(name.map { $0 == " " ? "-" : $0 }) // "glibc 2.39" → "glibc-2.39"
    #elseif canImport(Darwin)
    return "darwin"
    #else
    return "libc-unknown"
    #endif
}()

private let architectureID: String = {
    #if arch(x86_64)
    return "x86_64"
    #elseif arch(arm64)
    return "arm64"
    #else
    return "arch-unknown"
    #endif
}()
