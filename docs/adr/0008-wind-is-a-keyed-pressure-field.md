# Wind is a keyed pressure field connected to the course

The wind's speed across the water is shaped mainly by a **pressure field**, not by independent puffs. The field is a stateless function of the venue, the wind's window keys (ADR 0001), the race clock and the position, and it has three layers:
- A **cross-course gradient** that makes one side the pressure side. It holds for most of a leg and can flip within a race. Each venue has a standing tendency, but its strength is drawn per race and moved per window, so it can be strong, absent or reversed.
- **Pressure lanes**: patches of pressure stretched along the wind, a few hundred metres across, living 2–4 minutes and drifting sideways. A lane veers the wind on one edge and backs it on the other, so which edge you sail into can pick your tack. Since 2026-09-30 a lane is finite (an ellipse a few hundred metres long) and drifts down the wind slowly, and some lanes weaken the wind instead of strengthening it; before, lanes were unending bands that only varied across the course.
- The venue's static **geography**: a signed speed change per geographic-grid cell.

Lanes and the gradient follow the geography. They are laid across a curved across-the-wind coordinate that the venue derives once from its geographic bends, so they curve where the shore bends the wind. The venue also marks where lanes like to form (off a headland, down a channel); the keys place lanes mostly, not always, at those spots. Small **puffs** and **lulls** stay as a supplement, spawned from the field (puffs where it is strong, lulls where it is weak) at about a third of the old coverage, and keep their fan. Settled in [#283](https://github.com/reederphill/mobile-regatta/issues/283), overriding parts of [#10](https://github.com/reederphill/mobile-regatta/issues/10), [#221](https://github.com/reederphill/mobile-regatta/issues/221) and [#224](https://github.com/reederphill/mobile-regatta/issues/224).

We did this because independent puffs meandering down the course felt random and uninteresting in play (2026-09-28): round dots, laid uniformly, with lulls landing on puffs. Real race-course wind has structure tied to the place, with large pressure differences across the field that reward reading the water and local knowledge.

## Considered options

- **Independent puffs, made bigger and irregular, with lulls kept apart:** rejected. It fixes the look but not the randomness, and keeping lulls clear of puffs drawn in earlier windows needs every window's draw to see the windows before it.
- **A fluid simulation (a density field advected by the wind):** rejected. It is stateful, so late joiners and replay seeks must run the race from the start or stream state (which ADR 0001 rejected). A full solve is also chaotic, so the last-bit maths differences between iOS and the Linux server (ADR 0002) would grow until clients stopped predicting the server's wind.
- **A keyed pressure field (chosen):** keeps the wind a pure function (ADRs 0001, 0002) and puts the structure where the game needs it.

## Consequences

- A new simulation version (ADR 0002). Old conditions and venue files keep today's behaviour, so old logs replay unchanged on their own version.
- Nothing dynamic is derivable at race start: the gradient and lanes are keyed per window and blended between knots like the shift. The venue's geography, lane spots and side tendency are public data, like current (ADR 0003), and reading them is local knowledge.
- The venue file gains columns (signed speed change, lane preference, side tendency) in a new schema. Shadow in older schemas reads as a negative speed change.
- The water and the minimap draw the field as one continuous tone. Bots read it only within what a player could perceive (view and minimap), and the bot suite's tactician-beats-baseline gate is how we know the pressure is worth reading.
- The upwind edge tint of #224 is removed; the minimap shows the wind off screen instead.
- Finite lanes (2026-09-30, simulation revision 25, conditions schema 6, the version-7 files): the first tuning found that the field carried little beyond a ramp. The pressure side was ±15 % at the course edges while lanes peaked at 8–15 % and, at 200–400 m wide, were as wide as half the course (which is under 540 m across), and as unending bands the field never changed up the course. Version 7 halves the side, makes lanes narrower, more numerous and stronger, and gives each a length, a drift down the wind and a chance to be weak, all drawn from a stream of its own so older files sail unchanged. Measured on the real field over the race area, the variation left after taking out the across-course ramp doubles, and about half of it now varies up the course rather than none. The water's and the minimap's full tone is now 10 % pressure, so weaker lanes read.
- Strengths, sizes and persistence of every layer are placeholders with debug tuning sliders (#232) until tuned.
