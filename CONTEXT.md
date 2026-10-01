# Regatta

A mobile sailing race game: players helm dinghies around a course against other players and bots, with the Racing Rules of Sailing enforced automatically.

## Language

### Racing

**Fleet race**:
A single race in which every boat sails for itself and finishing order decides the result.
_Avoid_: match, game, round

**Regatta** (series):
Several races sailed by the same fleet, scored cumulatively. Not in v1.0.
_Avoid_: tournament, event

**Start sequence**:
The countdown before the gun, during which boats manoeuvre below the start line.
_Avoid_: pre-race, lobby countdown

**OCS** (On Course Side):
A boat with any part of her hull on the course side of the start line at the gun. She must return until her whole hull is on the pre-start side before starting. A boat that never comes back is scored OCS, and so is a boat that never started: behind every boat placed by ladder distance and every DSQ, and ahead of RET.
_Avoid_: false start, early

**Penalty turn**:
The single turn, including one tack and one gybe, that a boat must complete after a foul or touching a mark.
_Avoid_: spin, 720, 360 (except as UI shorthand)

**Foul**:
Breaking a rule of Part 2 of the RRS with respect to another boat.
_Avoid_: collision (contact is not itself a foul)

**Incident**:
What triggers a ruling between two boats: contact, or a near miss. One incident per pair until they separate by 2 hull lengths.

**Near miss**:
No contact, but sweeping an overlapped right-of-way boat's hull ±10° over 0.5 s would hit. It triggers a ruling as contact does.

**Room** (to keep clear):
What a right-of-way boat that has just acquired right of way (rule 15) or changes course (16.1) must give the other boat. Judged by the escape simulation.
_Avoid_: space, time to react

**Escape simulation**:
The umpire's test of room: the keep-clear boat's candidate inputs sailed on with the real boat dynamics for 2 s against the right-of-way boat's recorded track. If none keeps her clear, room wasn't given.
_Avoid_: avoidance check, track projection

**Exoneration**:
A boat that broke a rule of Part 2 isn't penalised for it, because she was compelled to (43.1(a)) or was denied the room she was entitled to (43.1(b)). Recorded on the incident; the rule call names the boat that broke the rule.
_Avoid_: acquittal, cleared

**Hold course**:
What a right-of-way boat does to keep her rights: rudder centred, the autohelm holding her wind angle. A turn the autohelm makes following a shift is still a course change under rule 16.1, but not one she initiated.
_Avoid_: hold heading, stand on

**Defend lane**:
A right-of-way boat keeping the water she's sailing in rather than giving it up to a boat that must keep clear of her: she holds course, and luffs only within the room rule 16.1 leaves the other boat.
_Avoid_: hunting (steering at a boat to force a foul, which bots never do)

**Zone**:
The water within 3 hull lengths of a mark; the rules configuration sets the size. A boat is in it once any part of her hull is, and rule 18 applies between two boats racing to the same mark only while at least one of them is in its zone.

**Mark-room**:
The room one boat owes another to sail to a mark, round or pass it, and leave it astern (rule 18). It isn't right of way (Case 25): rules 10–13 still decide which boat keeps clear, and an inside windward boat still keeps clear under rule 11.
_Avoid_: mark room; right of way; room on its own (that's what a right-of-way boat gives under rules 15 and 16.1)

**Entitled boat**:
The boat owed mark-room: the inside boat if the two were overlapped as the first of them reached the zone, otherwise the one that reached it first; with no such record, the inside of two overlapped boats (18.2(c)). A record made at the zone holds even if the overlap later changes, until mark-room has been given or she leaves the zone or passes head to wind. A boat that tacks from port to starboard in the zone of a mark left to port is owed no mark-room by a starboard boat fetching it (18.3 in the 2025 rules, where it's the starboard boat that must be fetching, not the tacker).
_Avoid_: right-of-way boat (mark-room isn't right of way); inside boat (a boat clear astern that reaches the zone first is entitled, Case 2)

**Last point of certainty**:
The last moment at which it was certain whether two boats were overlapped, or whether a boat was in a mark's zone. A change counts only once it has held for a short margin.
_Avoid_: overlap timer

**Protest**:
A player's claim that a rule was broken in an incident, or that a rule call was wrong. In v1.0 it's recorded but never changes a result.
_Avoid_: report, appeal (an appeal is a later challenge to a protest decision)

**Finish window**:
The time after the first boat finishes during which the rest of the fleet can still finish.
_Avoid_: time limit (that's the overall cap)

**Time limit**:
The latest time after the gun at which the race ends, whether or not any boat has finished.

**Distance to finish**:
How far a boat still has to sail, round its remaining marks, to finish: the path length, which times the race's close. Boats are placed by **Ladder distance**, not this.
_Avoid_: distance to the line (the finish line is also the start line)

**RET** (retired):
A boat whose player is gone when the race ends. She's placed behind every boat still racing, including those placed by ladder distance. When several are RET they tie for last, unless the race ended because every human had gone: then the player who left latest ranks highest.
_Avoid_: DNF, quit, abandoned

**Ghost**:
A boat that has stopped racing: finished, from the moment she crosses the line; disqualified, from the call; or OCS at the close, a boat that never started included. Still drawn, and still carried by the current, but it casts no wind shadow or backwind, can't be touched and has no rights or obligations.
_Avoid_: spectator, dead boat

**Bot**:
A computer-helmed boat that fills an empty seat in a fleet. A bot also sails a dropped player's boat until they come back. Bots are always labelled as bots.
_Avoid_: AI, CPU

**Bot tier**:
How well a bot sails: **Club**, **Regional** or **National**. Online, bots are matched to the fleet's ratings instead of using a fixed tier.
_Avoid_: difficulty, level

**Rival**:
One of the 1–2 bots in a practice race whose skill is set from the player's recent practice results, so the player usually finishes near them. A rival races like any other bot and never targets the player. Practice only.
_Avoid_: nemesis; "rival" for just any nearby boat

**Mixed fleet**:
A practice race whose bots are drawn from all three bot tiers. The default for practice.

**Briefing**:
The short screen between fleet lock and the start sequence showing the venue, conditions, the wind and tide forecasts, the course and the fleet. The only place current is shown.
_Avoid_: loading screen, pre-race

### Online play

**Queue**:
Where players wait to be placed in an online race. There's one, global.
_Avoid_: lobby (the lobby is the chat space), room, matchmaking

**Lobby**:
The one global chat space where signed-in players talk between races. Queued players wait here. It isn't a room or a match.
_Avoid_: room, channel

**Quick-chat**:
The fixed set of phrases and emotes a player can post to the lobby with one tap.
_Avoid_: emotes (as the umbrella term), canned messages

**Fleet lock**:
The moment an online race's boats are fixed and the briefing begins. Leaving before the gun costs nothing; a bot takes the seat.

**Rated race**:
An online race with at least two humans at the gun. Only results between humans move ratings.
_Avoid_: ranked match

**Completed race**:
An online race in which the player's result is finished, placed by ladder distance, DSQ or OCS: they stayed in the race. RET never counts, and a cancelled race counts for nothing. Earned liveries and the free-text unlock count completed races.
_Avoid_: finished race (when DSQ and OCS are meant too)

**Race token**:
What hands a player one seat in one online race: the race, the seat and an expiry, signed by the server. The client sends it, unread, to join.
_Avoid_: ticket, invite, session key

**Instant race**:
A dev-only online race started on request for the clients asking, with bots filling it to ten boats. It exists only on a dev server, for testing; players never see it.
_Avoid_: quick race, private race

**Practice race**:
An offline race against bots. Unrated, and needs no account.
_Avoid_: single player, training

**Tuned copy**:
A copy of a bundled boat class, conditions or rules configuration file with some values changed by the debug tuning panel, made at a practice race's start in Debug builds only. It keeps its file's id and version, has its own hash and a tune number, and its race's log replays only with it saved beside the log.
_Avoid_: override, variant, tweak

**Saved tuning**:
A named set of the debug tuning panel's values, kept on the device, which exports as the next version of each file it changes.
_Avoid_: preset (conditions avoid that word too), profile

**First race**:
The fixed practice race a new player is dropped into on first launch, before the home screen. It can be skipped.
_Avoid_: tutorial (that's a later, separate thing)

**Hint**:
A one-line message on the race screen that fires the first time its situation comes up and stops once the player has learned it.
_Avoid_: tip, tooltip, coach mark

### Course

**Venue**:
The body of water a race is sailed on, including any shoreline that shapes wind and current. Venues are fictional.
_Avoid_: map, level, arena

**Course**:
The marks, start line and finish line laid in a venue for one race, and the order they're sailed in.
_Avoid_: track

**Leg**:
The part of a course between consecutive marks (or the start line and the first mark).

**Mark**:
An object the course requires a boat to leave on a given side. The start and finish line ends are also marks.
_Avoid_: buoy (a buoy is just the physical object)

**Leeward gate**:
A pair of marks at the bottom of the course that boats sail between, then round either one.
_Avoid_: bottom mark (unless it's a single mark), gates

**Offset mark**:
A mark a short distance to one side of the windward mark, rounded straight after it, that keeps boats bearing away clear of boats still coming up.
_Avoid_: spreader mark, wing mark (a wing mark is on a reaching course)

**Race area**:
The water a course's boats may sail in, bounded by land or a drawn boundary. A boat can't leave it.
_Avoid_: arena, bounds, map edge

**Layline**:
The line from a mark along which a boat, at her best angle to the wind, can just fetch it without another tack or gybe. Drawn from the wind only, never from current.

**Ladder line**:
A line drawn across the course axis (the seeded mean wind direction, fixed for the race), so boats on the same line are level in the race to windward or leeward.

**Ladder distance**:
How far a boat still has to go to finish, counting only progress across the ladder lines on her current leg (along the course axis) plus the full length of each later leg measured the same way. On the reach, which crosses no ladder lines, it is the distance along the leg instead, so the total runs on across each rounding without a jump. Orders boats racing and places those unfinished when the race ends; the gap to the leader is the difference.
_Avoid_: distance to finish (the path length)

**Gap to leader**:
How far a boat is behind the leader in **Ladder distance**, in metres: her ladder distance less the least of any boat racing. Once a boat has finished, it is her own ladder distance still to go; a finished boat's gap is 0. None for a boat not started, disqualified, or whose player has gone before finishing (a finished boat keeps 0). A boat behind the leader shows at least 1 m. Shown on the **Live leaderboard**.
_Avoid_: time gap, distance behind

**Live leaderboard**:
The in-race HUD board under the clock and place, from the gun to the close: the leader, the boats directly ahead of and behind you, and you, each with a livery swatch and a **Gap to leader**; tap to see the whole fleet. Never names. Not the online ratings leaderboard (#165).
_Avoid_: ranking table, leaderboard (alone, for this board)

### Conditions

**Conditions**:
The named kind of wind a race is sailed in, such as "gusty offshore". Fixes the wind's strength, how it shifts and how puffy it is. Each venue lists the conditions it can have.
_Avoid_: preset, weather

**Wind shift**:
A change in wind direction. A shift that lets a boat point closer to its mark is a **lift**; one that forces it further away is a **header**.

**Oscillating shift**:
A wind shift that swings back and forth about a mean direction.

**Persistent shift**:
A wind shift that keeps trending one way over the race.
_Avoid_: permanent shift

**Geographic shift**:
The venue's static, public change to the wind at a place, fixed by its shoreline and felt by any boat that sails there: a direction bend and a signed speed change (an older venue's shadow reads as a loss), plus where pressure lanes like to form and the pressure side's standing tendency (#287).

**Pressure**:
How much stronger or weaker the wind is than the course average at a place. Shaped by the pressure side, pressure lanes and the venue's geography (ADR 0008).
_Avoid_: density, wind strength (for the local difference)

**Pressure side**:
The side of the course with more pressure at the moment. It holds for most of a leg and can change within a race.
_Avoid_: favoured side (that can mean the shift)

**Pressure lane**:
A patch of pressure stretched along the wind: a few hundred metres across and several hundred long, drifting slowly sideways and down the wind, and curving with the venue's geography. Stronger than its surroundings, or a **weak lane** weaker (older venues' lanes are unending strong bands). The wind veers on one edge and backs on the other.
_Avoid_: gust lane, streak

**Puff**:
A small, short-lived patch of stronger wind moving down the course, found mostly in pressure. A patch of weaker wind is a **lull**.
_Avoid_: gust (for a moving patch)

**Wind shadow**:
The disturbed, weaker air downwind of a boat's sails.
_Avoid_: dirty air (fine as UI copy)

**Backwind**:
Air deflected off a boat's sails that slows a boat just to windward of her and astern. What makes a safe leeward position safe.

**Lee-bow**:
To put your boat to leeward of another boat and just ahead of her, on the same tack and close enough that she sits in your backwind. She can only sink back or tack away. Usually done by crossing her bow and tacking onto her lee bow, which needs room to cross. She is then _lee-bowed_.
_Avoid_: lee-bowing the tide (see **Current on the lee bow**), cover (that puts you between her and the mark), tack on her wind (that puts you to windward of her)

**Current on the lee bow**:
Close-hauled with the current setting across the wind on the leeward bow. It lifts the boat toward a windward mark and raises the apparent wind speed.
_Avoid_: lee-bowing (in this game that means the tactic above)

**Current**:
Movement of the water itself, which carries every boat regardless of wind. May vary across the venue and over time (tide).
_Avoid_: tide (tide is the rise and fall; current is the flow)

**Adverse current** / **fair current**:
Current against or with a boat's progress toward its mark.
_Avoid_: foul tide (a foul is a rules breach)

**Slack**:
The time when the current is near zero as it reverses.

**Turn of the tide**:
The current reversing through slack. It turns first in the shallows and later in the channel.

**Tidal venue**:
A venue whose current changes noticeably during a race. Other venues have steady current or none.

### Boats

**Boat class**:
A boat design with its own performance and handling. v1.0 has exactly one: the skiff.
_Avoid_: boat type, model

**Skiff**:
v1.0's boat class: a fictional two-person 4.9 m high-performance dinghy with trapezes and an asymmetric spinnaker, modelled on the 49er.

**Planing**:
Sailing fast enough that the hull skims over the water instead of pushing through it. Downwind and on reaches a skiff is either on the plane or off it; once off, she has to head up to get back on.
_Avoid_: foiling (a different thing)

**Spinnaker**:
The skiff's large asymmetric downwind sail. It goes up automatically once she bears away far enough and comes down as she heads up.
_Avoid_: kite (fine as UI copy), gennaker

**Tack** (starboard or port):
The side opposite the boom. A boat changes tack only by tacking or gybing, never by just sailing by the lee.

**Polar**:
A boat class's speed through the water at each wind angle and wind strength.
_Avoid_: speed curve, performance table

**VMG** (velocity made good):
The part of a boat's speed that carries her straight upwind or downwind, or toward her mark.

**Sailing by the lee**:
Sailing downwind with the wind past dead astern on the same side as the boom, short of the point where the boom crosses and she gybes.

**Ease**:
Letting the sheets out so the sail flaps and the boat slows, e.g. to hold position before the start.
_Avoid_: luff (in the rules, luffing means turning toward the wind)

**Autohelm**:
What steers the boat whenever nobody is holding the rudder: it holds the angle to the true wind she had when the rudder was centred, snapping to the groove when close to it. It never tacks or gybes by itself, and it sails the tack/gybe tap.
_Avoid_: autopilot, lock, helm (to helm is what a player does)

**Groove**:
The best-VMG angle to the wind for the wind strength at the boat, upwind or downwind. The autohelm snaps to it when let go close to it and follows it as the wind strength changes.

**Tack cost**:
What a tack loses against sailing on: the distance made good upwind, in hull lengths, over the tack and the speed she takes to get back. About a hull length from close-hauled with the autohelm sailing the tap; it decides which shifts are worth tacking on.
_Avoid_: tack penalty (a penalty is a rules turn)

**Roll tack**:
A second tack/gybe tap during a tack, timed on the boom crossing. Close enough to the crossing it hits and she loses less speed until close-hauled; too early or too late it misses and costs her speed. It never makes a tack better than not tacking.
_Avoid_: double tap (fine as UI copy), roll gybe (a gybe has no roll yet)

**Pinch** / **foot**:
Sailing a few degrees above the groove (closer to the wind, slower) or below it (further from the wind, faster). The autohelm holds either until the player changes it.
_Avoid_: pinch for the two-finger zoom gesture; call that **pinch-zoom**

**Livery**:
How a player's boat looks: a livery design, the colours filling it, and a sail number. Cosmetic only, and every other player sees it.
_Avoid_: skin

**Livery design**:
A pattern and sail graphic with two or three colour slots, which the player fills from the safe palette. Starter designs are free, some are earned by racing, and the rest are sold one at a time.
_Avoid_: skin, template

**Safe palette**:
The only colours a livery may use: readable against every venue's water and never the hue of an on-water cue (vermillion, orange, yellow, or the give-way chevron's blue). White and charcoal are allowed.

**Sail number**:
A number from 1 to 9999 the player chooses for their boat. It need not be unique; when two boats in a fleet share one, the later one shows another number for that race.

### View

**Course-up**:
The default camera: the view turned so the course axis is at the top of the screen, putting the windward mark up whatever the venue's orientation. The minimap is always course-up.
_Avoid_: north-up, map view

**Boat-up**:
The optional camera: the view turned to follow your boat's heading with about a second's lag, so tacks and penalty turns don't whip it round.
_Avoid_: chase cam, heading-up

**Heading lead**:
Where the camera centres: your boat plus a lead the way she's heading, sized as a share of the screen (further up it than across it) at every zoom and speed. The lead's direction follows your heading with a couple of seconds' lag and shrinks while she turns hard (360s, pre-start spins). Nothing else moves the centre after the start.
_Avoid_: look-ahead, upwind framing

**Shot**:
What sets the camera's zoom at a moment of the race, never its centre. In order of precedence: pre-start (your boat low on the screen with the line in view, until just after the gun), close quarters (zoomed in while a boat is within a few hull lengths), mark rounding (widening only as much as keeps the mark on screen) and open water. A shot holds a few seconds before a lower one replaces it, and changes ease.
_Avoid_: framing, camera mode

**Auto zoom**:
The camera's shots choosing its zoom; on by default. Off, the heading lead stays and the zoom is open water's. Either way a pinch-zoom multiplies the zoom and is kept across races; a two-finger double tap resets it.
_Avoid_: auto framing, smart camera

**View heading**:
The compass heading at the top of the screen in course-up or boat-up; the HUD's arrows turn by it so they point true on screen.
_Avoid_: camera angle, screen rotation
