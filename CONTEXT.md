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
A boat with any part of her hull on the course side of the start line at the gun. She must return until her whole hull is on the pre-start side before starting.
_Avoid_: false start, early

**Penalty turn**:
The single turn, including one tack and one gybe, that a boat must complete after a foul or touching a mark.
_Avoid_: spin, 720, 360 (except as UI shorthand)

**Foul**:
Breaking a rule of Part 2 of the RRS with respect to another boat.
_Avoid_: collision (contact is not itself a foul)

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

**Bot**:
A computer-helmed boat that fills an empty seat in a fleet.
_Avoid_: AI, CPU

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

### Boats

**Boat class**:
A boat design with its own performance and handling. v1.0 has exactly one.
_Avoid_: boat type, model

**Tack** (starboard or port):
The side opposite the boom. A boat changes tack only by tacking or gybing, never by just sailing by the lee.

**Livery**:
The player-chosen colours and graphics applied to their boat. Cosmetic only.
_Avoid_: skin
