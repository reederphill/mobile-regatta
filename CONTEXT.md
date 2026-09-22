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
A boat that is on the course side of the start line at the gun and must return before starting.
_Avoid_: false start, early

**Penalty turns**:
The turns a boat must complete after breaking a rule. Two turns for fouling another boat, one for touching a mark.
_Avoid_: spin, 720 (except as UI shorthand)

**Foul**:
Breaking a rule of Part 2 of the RRS with respect to another boat.
_Avoid_: collision (contact is not itself a foul)

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

**Wind shift**:
A change in wind direction. A shift that lets a boat point closer to its mark is a **lift**; one that forces it further away is a **header**.

**Puff**:
A patch of stronger wind moving down the course. A patch of weaker wind is a **lull**.
_Avoid_: gust (for a moving patch)

**Wind shadow**:
The disturbed, weaker air downwind of a boat's sails.
_Avoid_: dirty air (fine as UI copy)

**Current**:
Movement of the water itself, which carries every boat regardless of wind. May vary across the venue and over time (tide).
_Avoid_: tide (tide is the rise and fall; current is the flow)

### Boats

**Boat class**:
A boat design with its own performance and handling. v1.0 has exactly one.
_Avoid_: boat type, model

**Livery**:
The player-chosen colours and graphics applied to their boat. Cosmetic only.
_Avoid_: skin
