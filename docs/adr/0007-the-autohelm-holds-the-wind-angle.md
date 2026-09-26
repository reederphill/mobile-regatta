# The autohelm holds the wind angle

A centred rudder no longer holds the boat's compass heading. Whenever the rudder input is centred, the autohelm holds the boat's angle to the true wind at the boat (wind minus current, the wind the polar reads): the angle she had on the tick the rudder centred, or the groove (the best-VMG angle) when that angle is within a snap width of it. It steers through the rudder and the class's turn-rate physics, never tacks or gybes by itself, bears away to the groove from the no-go zone, and sails the tack/gybe tap, which exits at the groove on the new tack. Players and bots use it the same way. Settled in [#219](https://github.com/reederphill/mobile-regatta/issues/219), overriding part of [#13](https://github.com/reederphill/mobile-regatta/issues/13).

We did this because holding a compass heading turned every oscillation into a tracking chore: the player watched the wind angle and corrected by hand, which is attention without a decision, and it crowded out the tactical game that is the real skill. The autohelm knows only the polar and the wind at the boat right now. It doesn't anticipate puffs or shifts and ignores other boats, current, laylines and the race, so leaving the groove at the right moment (pinch, foot, tack) is where skill shows.

## Considered options

- **Compass-heading hold (#13's original decision):** rejected; the playtest of 2026-09-25 found the player only tracking the wind angle.
- **A new "hands on" bit in the held input:** rejected. A centred rudder already means "not steering" in both schemes, so the autohelm needs no new input, and the log format and wire inputs stay as they are.
- **Holding the apparent wind angle:** rejected. A puff swings the apparent wind aft, so the autohelm would head up in every puff and take that decision away from the player.
- **Mode buttons for pinch and foot:** rejected in favour of "steer and let go", which the snap makes precise enough.
- **A heading-hold option for purists:** rejected; two input models would mean two sets of tuning and bot behaviour.

## Consequences

- A new simulation version (ADR 0002): what a centred rudder does changes, so every golden changes. Old logs replay on their own version.
- The autohelm's target (an angle, or the groove) is boat state. It goes in the digest and in the snapshot in place of the tack autopilot, so clients predict it (ADR 0005).
- Snap widths and the controller gain are tuning values, live-tunable as debug sliders before they're written into data.
- A right-of-way boat whose autohelm follows a shift changes course without any input. [#228](https://github.com/reederphill/mobile-regatta/issues/228) decided it: that is a course change like any other under 16.1, and the rules configuration's "changes course" threshold keeps small shift-following turns from counting.
- The bot suite must show that a tactician bot clearly beats a groove-only bot, or the autohelm has flattened skill.
