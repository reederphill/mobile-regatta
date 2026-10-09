# Boats steer by hand; the autohelm is a tuning option

A centred rudder holds the rudder centred again: she sails straight on her heading, and every shift and puff is hers to steer through. This holds for every boat, players and bots alike. The autohelm of ADR 0007 becomes one race-wide tuning setting, off by default (on: ADR 0007's behaviour for every boat), recorded with the race. Bots steer by hand through the rudder, with skill-scaled steering weaknesses ([#435](https://github.com/reederphill/mobile-regatta/issues/435)). The tack/gybe tap still sails the turn, onto the groove on the new tack, and hands back a centred rudder once she is within 3° of it, so she doesn't stall just past head to wind. Settled in [#426](https://github.com/reederphill/mobile-regatta/issues/426) and built in [#434](https://github.com/reederphill/mobile-regatta/issues/434), overriding part of ADR 0007 and [#219](https://github.com/reederphill/mobile-regatta/issues/219).

We did this because the autohelm made the legs mindless: holding the groove through every puff and shift left nothing to do between decisions. #426 set out to add boat handling as a second skill axis beside tactics, and three handling mechanics were tried on the throwaway `proto-handling` branch (an overpowered state with Ease and wipeouts; Ease as a sheet dial with a fast heel band; and a three-stage flat/groove/overpowered model, dropped before it was built). Each was either a tapping game to survive gusts or too much to work while steering. The `proto-tiller` branch, main's sailing model with only the player's autohelm turned off, played "much better" (2026-10-09). Steering through the wind at your boat is the handling skill.

## Considered options

- **Keep the autohelm and add a gust mechanic (heel, overpowered, depower with Ease, wipeout):** rejected after playtest. Ease is a separate button, so depowering fought steering, and the cliff design made it bang-bang.
- **Ease as a sheet dial with a fast heel band and rounding up:** rejected after playtest as too much.
- **Flat, groove and overpowered stages shown as tilt, steered out of:** dropped before it was built.
- **Autohelm off, kept as a tuning setting for every boat (chosen):** the smallest change that gives the legs something to do, and it reuses the polar, vane and groove tick as they are.
- **A per-player setting, bots keeping the autohelm:** rejected (2026-10-09). Bots and players should sail the same model, and a per-player choice would mean two input models in one race.

## Consequences

- This reverses ADR 0007's rejection of a heading-hold option, and the 2026-09-25 playtest that found compass-heading hold a tracking chore; the 2026-10-09 playtest overrides it. There is still one input model per race, as ADR 0007 wanted: the setting is race-wide.
- A new simulation version (ADR 0002) when this lands: what a centred rudder does changes. Old logs replay unchanged on their own version.
- With the setting off, no right-of-way boat changes course by following a shift, so the watchdog and [#228](https://github.com/reederphill/mobile-regatta/issues/228)'s shift-following case apply only with the autohelm on.
- The groove tick stays as the target to steer to. The pinch/foot arc only shows while the autohelm holds an angle, so mostly during a tap.
- Bots need a hand-steering model (#435) before this can default off in play; #426's targets T1–T4 stand and are measured against it.
