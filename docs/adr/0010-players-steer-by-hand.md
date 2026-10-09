# Players steer by hand; the autohelm is an option

For a human's boat, a centred rudder holds the rudder centred again: she sails straight on her heading, and every shift and puff is the player's to steer through. The autohelm of ADR 0007 is off for players by default and stays as a tuning setting (on: ADR 0007's behaviour). Bots keep the autohelm. The tack/gybe tap still sails the turn for a player, onto the groove on the new tack, and hands back a centred rudder once she is within 3° of it, so she doesn't stall just past head to wind. Settled in [#426](https://github.com/reederphill/mobile-regatta/issues/426), overriding part of ADR 0007 and [#219](https://github.com/reederphill/mobile-regatta/issues/219).

We did this because the autohelm made the legs mindless: holding the groove through every puff and shift left nothing to do between decisions. #426 set out to add boat handling as a second skill axis beside tactics, and the owner playtested three handling mechanics on the throwaway `proto-handling` branch (an overpowered state with Ease and wipeouts; Ease as a sheet dial with a fast heel band; and a three-stage flat/groove/overpowered model, dropped before it was built). Each was either a tapping game to survive gusts or too much to work while steering. The `proto-tiller` branch, main's sailing model with only the player's autohelm turned off, played "much better" (2026-10-09). Steering through the wind at your boat is the handling skill.

## Considered options

- **Keep the autohelm and add a gust mechanic (heel, overpowered, depower with Ease, wipeout):** rejected after playtest. Ease is a separate button, so depowering fought steering, and the cliff design made it bang-bang.
- **Ease as a sheet dial with a fast heel band and rounding up:** rejected after playtest as too much.
- **Flat, groove and overpowered stages shown as tilt, steered out of:** dropped before it was built.
- **Autohelm off for players, kept as a tuning setting (chosen):** the smallest change that gives the legs something to do, and it reuses the polar, vane and groove tick as they are.

## Consequences

- This reverses ADR 0007's rejection of a heading-hold option, and the 2026-09-25 playtest that found compass-heading hold a tracking chore; the 2026-10-09 playtest overrides it. The tuning setting is the purist option ADR 0007 rejected, inverted, so two input models do exist: bot behaviour and tuning stay on the autohelm side.
- A new simulation version (ADR 0002) when this lands: what a player's centred rudder does changes. Bots and old logs are unchanged on their own version.
- A player's right-of-way boat no longer changes course by following a shift, so the watchdog and [#228](https://github.com/reederphill/mobile-regatta/issues/228)'s shift-following case apply to bots only.
- The groove tick stays as the target to steer to. The pinch/foot arc only shows while the autohelm holds an angle, so for players mostly during a tap.
- `-demo` sails the player's seat badly: its bot steers through the autohelm, which is off for that seat.
- The bot suite needs a hand-steering bot (steering error from skill) before parity between handling and tactics can be measured; #426's targets are reread against it.
