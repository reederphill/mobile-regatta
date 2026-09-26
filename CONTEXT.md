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
A boat with any part of her hull on the course side of the start line at the gun. She must return until her whole hull is on the pre-start side before starting. A boat that never comes back is scored OCS, behind every boat placed by distance to finish.
_Avoid_: false start, early

**Penalty turn**:
The single turn, including one tack and one gybe, that a boat must complete after a foul or touching a mark.
_Avoid_: spin, 720, 360 (except as UI shorthand)

**Foul**:
Breaking a rule of Part 2 of the RRS with respect to another boat.
_Avoid_: collision (contact is not itself a foul)

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
How far a boat still has to sail, round its remaining marks, to finish. Places boats that haven't finished when the race ends.
_Avoid_: distance to the line (the finish line is also the start line)

**RET** (retired):
A boat whose player is gone when the race ends. She's placed behind every boat still racing, including those placed by distance to finish. When several are RET, the player who left latest ranks highest.
_Avoid_: DNF, quit, abandoned

**Ghost**:
A boat that has stopped racing (finished, disqualified, or OCS at the close). Still drawn, but it casts no wind shadow, can't be touched and has no rights or obligations.
_Avoid_: spectator, dead boat

**Bot**:
A computer-helmed boat that fills an empty seat in a fleet. A bot also sails a dropped player's boat until they come back. Bots are always labelled as bots.
_Avoid_: AI, CPU

**Bot tier**:
How well a bot sails: **Club**, **Regional** or **National**. Online, bots are matched to the fleet's ratings instead of using a fixed tier.
_Avoid_: difficulty, level

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
An online race in which the player's result is finished, placed by distance, DSQ or OCS: they stayed in the race. RET never counts, and a cancelled race counts for nothing. Earned liveries and the free-text unlock count completed races.
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
A line drawn across the wind, so boats on the same line are level in the race to windward or leeward.

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
A wind shift fixed in place by the venue's shoreline, felt by any boat that sails there.

**Puff**:
A patch of stronger wind moving down the course. A patch of weaker wind is a **lull**.
_Avoid_: gust (for a moving patch)

**Wind shadow**:
The disturbed, weaker air downwind of a boat's sails.
_Avoid_: dirty air (fine as UI copy)

**Backwind**:
Air deflected off a boat's sails that slows a boat just to windward of it. What makes a safe leeward position safe.

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
A boat design with its own performance and handling. v1.0 has exactly one.
_Avoid_: boat type, model

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

**Pinch** / **foot**:
Sailing a few degrees above the groove (closer to the wind, slower) or below it (further from the wind, faster). The autohelm holds either until the player changes it.

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
