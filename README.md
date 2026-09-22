# Regatta

A native iOS take on [Regattatron](https://regattatron.com): top-down dinghy fleet racing with
the Racing Rules of Sailing enforced. Swift, SpriteKit and SwiftUI.

This first cut is single-player against bots. Multiplayer, the lobby and rankings come later.

## Layout

```
Packages/RegattaCore/   The simulation: pure Swift, no UI, unit tested
  Geometry.swift          vectors, angles, line crossings, SAT collision
  Wind.swift              oscillating shifts, left/right bias, drifting puffs and lulls
  Polar.swift             boat speed by true wind angle
  Course.swift            windward-leeward course, start/finish line, rounding gates
  Boat.swift              boat state and hull shape
  Rules.swift             Rules 10, 11, 12, 13, 18, 22, 31 — who had to keep clear
  Race.swift              fixed-step race loop: start sequence, OCS, contacts, penalties, finish
  BotBrain.swift          AI helms: start timing, laylines, shifts, roundings, keeping clear
Regatta/                The iOS app
  Game/GameScene.swift    SpriteKit renderer, camera, touch steering
  Game/BoatNode.swift     batched boat sprites, sails, wakes, wind-shadow cones
  Game/GameSession.swift  bridges the race to SwiftUI: HUD, rule-call messages, haptics
  UI/                     menu, HUD, minimap, results
```

The simulation runs at a fixed 60 Hz, independent of the display (the app renders at up to 120 Hz on
ProMotion). Everything the rules engine decides lives in `RegattaCore`, so it can later move to a
server for authoritative multiplayer.

## Building

Open `Regatta.xcodeproj` and run the **Regatta** scheme. Xcode must have the iOS platform that matches
its SDK installed (Xcode → Settings → Components); if it doesn't, the scheme will show no run
destinations.

Run the simulation tests from the command line:

```bash
cd Packages/RegattaCore && swift test
```

### Launch arguments

- `-autostart` skips the menu and starts a race.
- `-demo` starts a race with a bot sailing your boat too. Useful for watching the AI and profiling.

## Playing

- Hold the **left** or **right** half of the screen to steer. Short taps make small corrections.
- **Tack / Gybe** swings you through the wind onto the mirror-image angle.
- Be below the line at the gun. If you're over (OCS), dip back below the line, then start.
- Round the windward mark and leeward mark to port, then finish by crossing the line downwind.
- Dark water is a puff and pale water is a lull. The faint cone behind each boat is its wind shadow.
- Fouling another boat costs a 720°, and touching a mark costs a 360°. Turn circles to serve it.
  Finishing with a penalty unserved is a DSQ.
