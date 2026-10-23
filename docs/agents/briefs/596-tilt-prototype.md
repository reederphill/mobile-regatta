# Brief: #596 prototype, a 2.5D race scene at three tilts (PROBE branch, never merged)

Branch `prototype/596-tilt`, worktree `.claude/worktrees/t596`. The output is **pictures**: nine simulator
screenshots, one short recording, and a paragraph per tilt, posted on issue #596. No tests, no fixtures, no
reference re-records, no PR. Skip every layer that doesn't change the look. Time box: two agent sessions; this
is session 1. Near ~400K context or ~150 tool calls: WIP-commit, write a handoff note in the commit message
(done, next, gotchas, exact next command) and return.

## Question (the owner's)

Does a 2.5D race scene, the flat world drawn from a fixed oblique tilt with boats and sails that look solidly
three-dimensional, give the look the owner wants (a Sailboss-like feel) without leaving SpriteKit? Which tilt?
Tilts off vertical to show: **30°, 42°, 55°**.

## Build (the ticket's list, with the orchestrator's technical decisions)

Everything is presentation: no file under `Packages/` changes (ADR 0002 untouched by construction).

### 1. Launch arguments (`Regatta/App/LaunchOptions.swift`)

- `-tilt <deg>`: 0…80, default 0 (flat, today's look). Stored on `LaunchOptions`; `GameScene` reads
  `LaunchOptions.current`.
- `-boats <n>`: 2…16, sets `config.opponents = n - 1` in `launchRaceConfig` (the demo race is 8 boats today; the
  owner wants 10 in the start shot).
Add both to `flags` and `apply` like `-laps`. Debug-only is fine.

### 2. Oblique projection in one place (`GameScene.swift`)

Today: `world` (water, effects, course, cues, fleet layers) is a scene child; the `SKCameraNode` `cam` carries
position, uniform scale and `zRotation` (`render(_:)` lines ~334–339). Touches use view coordinates, not scene
conversion, so they don't care.

Decision: **don't tilt the camera; re-parent the world.** Scene ← `tilt` (SKNode, `yScale = cos(tilt)`) ←
`rotor` (SKNode, `zRotation = -rig.cameraRotation`) ← `world` (`position = -rig.center`). The camera stays at the
origin, unrotated, with `setScale(rig.cameraScale)` as now. Screen-up stays boat-up in boat-up mode because the
rotation happens before the squash. With tilt 0 this is pixel-identical to today (check once by eye).

- Camera children (`edgeArrow`, `hintLeader`) are untouched.
- `WaterView(center:sceneSize:scale:rotation:)`: pass `rig.center`, `rig.cameraScale`, `rig.cameraRotation` as
  now, but with `sceneSize.height / cos(tilt)` so the water still tiles the taller visible rect.
- `TurbulenceTrailLayer.pixelFrame` converts camera → layer with `convert`, which is affine and so already
  includes the squash. If the ribbons look wrong, hide `trailLayer` behind a flag rather than fix it.
- `ruleCues.update(... rotation: cam.zRotation)` and `chart.update(cameraScale: cam.xScale)`: pass
  `rig.cameraRotation` / `rig.cameraScale`.
- Put `ChartGeometry` a one-line `static func obliqueSquash(tiltDegrees:) -> CGFloat { cos }` so "the projection
  lives in one place" is literally true; everything reads it from there.

### 3. Boats that read as 3D (`Regatta/Game/Boat3D.swift`, new; `BoatNode.swift`, `GameScene.swift`)

The owner's requirement: the hull shows its topsides and deck as she heels; the sail is a cambered surface with
light and shade from luff to leech; boom and mast included; heel leans the whole rig and reveals the windward
topside. Liveries: hull colour from the boat's `color` (what `BoatNode` gets), sail off-white. Nothing else.

Decision, a deviation from the ticket's "SK3DNode per boat" that the orchestrator takes on the ticket's own
grounds (shortest path, cost): **one `SK3DNode` for the whole fleet**, a child of the camera covering the whole
view (`viewportSize = scene size`, `zPosition` above the fleet layer, say 4), holding one `SCNScene` with one
node per boat, the buoys and the committee boat. One SceneKit pass, one light, free depth sorting between every
standing thing (the ticket's "draw order by screen-y" is then the z-buffer's job; `DrawOrder` is untouched).
If the single node composites badly over the water, fall back to the ticket's per-boat `SK3DNode`s, and only
then to projected `SKShapeNode` polygons.

Geometry of the SceneKit scene (units: scene points, so 1 metre = `GameScene.pointsPerMeter`):
- Ground plane is XZ, Y up. Orthographic camera (`usesOrthographicProjection`, `orthographicScale` = half the
  viewport height in points, `zNear`/`zFar` generous), pitched down by `(90° - tilt)` from horizontal so it looks
  at the ground at `tilt` off vertical: `eulerAngles.x = -(.pi/2 - tilt)`. With this, a ground point
  `(x, 0, -y)` projects to screen `(x, y·cos(tilt))`: the same squash the `tilt` node gives the flat world, so a
  3D hull sits on its 2D wake and shadow. Camera position: pulled back along its own -Z far enough that
  everything is in front of it; the orthographic projection doesn't care how far.
- Per boat each frame: screen-space position of her centre from the flat world = `rotor`/`tilt` maths:
  `p = R(-θ) · (boat.position·ppm - rig.center)`; SCN node `position = (p.x, 0, -p.y)`; yaw
  `eulerAngles.y = -(boat.heading) + θ` (verify the sign once against the flat sprite: keep the flat hull
  drawing under it until the two agree, then hide the flat hull/outline/sail behind the tilt flag).
- Hull: a procedural `SCNGeometry` lofted from `BoatClass.Hull.outline` (metres, x starboard, y bow; convex) at
  deck height `freeboard` (0.12 × beam) down to a keel line: the outline scaled to 0.35 beam at depth 0 with a
  slight V. Side quads with per-face normals (duplicate vertices, flat shading), a deck cap, a cockpit as a
  darker inset quad if cheap. `SCNMaterial` lambert, `diffuse` = the livery colour; the deck a touch lighter.
- Rig: mast a thin `SCNCylinder` at the mast step (`y = +0.16 L` on the hull, as `BoatNode` places the sail),
  height 1.25 L. Boom a thin cylinder 0.62 L along -y. Sail: a quad strip from luff (mast) to leech (boom end):
  N=8 columns, 2 rows (foot and head, the head short), each column bowed to leeward by a camber curve
  `belly · sin(π·t)` with `belly = 0.12 L · pose.sailFullness`; vertex normals from the curve so one directional
  light shades luff to leech. Off-white lambert, double sided.
- Pose (`BoatPose`, unchanged): heel rotates the whole boat node about her longitudinal axis by
  `pose.heel × 28°` toward `pose.leeSide`; the sail+boom pivot about the mast by `pose.sailTrim` toward
  `pose.sailSide`; flutter adds `sin(time·flutterSwingRate + seat phase) × flutterDegrees × pose.flutter` as in
  `BoatNode.updateSail`; a ghost: alpha 0.4 on the materials.
- Light: one `SCNLight.directional` from the chart's light bearing (any fixed bearing is fine; from upper-left
  of the screen reads well), plus a weak ambient. `scene.background.contents` clear; the SK3DNode's
  `autoenablesDefaultLighting = false`.
- Ten boats: keep geometry small (hull ~60 triangles, sail ~32).

### 4. Things that stand up

In the same SceneKit scene, flat colour, no texture:
- Marks: `SCNCylinder` buoys (radius = the mark's drawn radius, height ≈ 1.2 m·ppm), orange for the active leg's
  marks and grey otherwise (read the tones `ChartMarks.tone(of:in:status:legIndex:)` once per frame as
  `ChartLayer.update` does; or just orange for the windward mark and grey elsewhere if that's quicker).
- The committee boat: an `SCNBox` of `ChartStyle.committeeHull` size, height 1.5 m·ppm, white.
- Land as an extruded rim: NOT in SceneKit. A child of `tilt` (so the extrusion is screen-vertical), one dark
  `SKShapeNode` rebuilt each frame from the land polygons (`ChartLayer`'s source, `ChartGeometry.edges`):
  for each edge, the quad `[a, b, b + d, a + d]` with `d = (0, -h)` in `rotor` space before the squash (so apply
  the rotor transform to a, b first), `h` ≈ 6 m·ppm; drawn at a z just under the land's top fill. Flat dark
  land colour. Skip if the venue's land is off screen in every shot; note it.

### 5. Water with depth (`WaterNode.swift`, `WaterStyle` untouched)

The existing water is squashed by the `tilt` node for free. Add:
- A specular glint band: one full-view `SKSpriteNode` child of the camera with an `SKShader`, z just above
  the water (-9.5), additive-ish white at low alpha: a horizontal band whose centre is a fixed share of the
  view height from the top (the light's reflection line, say 0.3), width ~0.15 of the height, modulated by
  `sin`s of screen x and `u_time` so it sparkles. Keep it faint (the owner's palette rule: faint but seen).
- Wave displacement: an `SKShader` on the ripple tiles that offsets the texture lookup by
  `0.01·sin(u_time·2 + v_tex_coord.x·12)`; drop it if the tiles' batching breaks or it costs more than 1 ms.
Puffs and lulls stay as they are: the owner needs to see that the wind still reads at each tilt.

### 6. Leave alone

HUD, hints, rule cues, minimap, trails, shadow cones, quality tiers, fixtures' references, tests. Where a layer
looks wrong squashed, hide it with a flag rather than fix it. No camera framing change (the squash costs upwind
view; that's `CameraRig` later, not here). No sim change.

## Capture (the deliverables)

Build and install, once per round:

```
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t596
scripts/heavy.sh --simulator xcodebuild build -project Regatta.xcodeproj -scheme Regatta \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/preview-dd -quiet
APP=$(find .build/preview-dd/Build/Products -name Regatta.app -path '*iphonesimulator*' | head -1)
UDID=983CC37F-13EA-4941-A814-71A228D13151   # iPhone 17, booted
xcrun simctl install $UDID "$APP"
```

Launch (the Debug FPS overlay is on for any launch without `-uitesting`):

```
xcrun simctl launch --terminate-running-process $UDID com.phillreeder.regatta \
  -demo -seed 7 -boats 10 -camera boat -startSeconds 20 -timescale 1 -tilt 42
sleep 10; xcrun simctl io $UDID screenshot out/596/tilt42-1-start.png
```

Shots, iPhone, for **each of 30, 42, 55** (file names carry the tilt, under `out/596/` in the worktree; this
folder is committed on the probe branch too):
1. `tilt<N>-1-start.png`: the fleet at the start, 10 boats, boat-up, about T−10 s (launch with
   `-startSeconds 20`, screenshot at ~10 s): crowding, heel, sails on both sides.
2. `tilt<N>-2-windward.png`: the windward mark rounding, your boat and two others in the zone: heel through the
   turn, the buoy standing up, the sail swinging. Reaching it at `-timescale 1` takes minutes; `-timescale 3`
   to get there is fine (the look doesn't change), then screenshot in a burst (`for i in 1 2 3 4 5 6; do
   xcrun simctl io ... ; sleep 1; done`) and keep the best frame. Pick a seed where boats arrive together.
3. `tilt<N>-3-downwind.png`: downwind on the plane with a puff ahead: the water's depth, the glint, whether the
   puff still reads.
Plus `tilt<N>-tack.mp4` (≤ 15 s) at your preferred tilt: `xcrun simctl io $UDID recordVideo --codec h264
out/596/tilt42-tack.mp4` in the background, kill it with SIGINT after 15 s, during a tack of your boat
(the bot tacks on the beat; start the recording on the beat and keep the first that shows one).

Frame cost: read the Debug FPS overlay (bottom-right) with 10 boats at each tilt and at `-tilt 0` for the
baseline; note FPS and draw count. If SceneKit kills the frame rate, say so and try the per-boat fallback only
if cheap.

## Report (your final message, which the orchestrator posts on #596)

- Per tilt, one paragraph: what reads, what doesn't, FPS/draws with 10 boats vs the flat baseline.
- Which boat approach you landed on and why (the single SK3DNode scene, per-boat nodes or polygons).
- What you hid behind the flag and anything that looked wrong squashed.
- Your preferred tilt.
- The exact relaunch command per shot, so the owner can look live.
- Deviations from the ticket.

Commit on `prototype/596-tilt` as you go (WIP commits are fine; never push to main; never open a PR). Push
the branch with `git push -u origin prototype/596-tilt` at the end so the owner can check it out.

## Reading rules

`grep -n` / `sed -n <range>p`, not `cat` of whole files. Start with `GameScene.swift` lines 160–200 and
300–360, `BoatNode.swift` (`BoatArt.hullPath`, `updateHeel`, `updateSail`), `BoatPose.swift` (the pose's
fields), `ChartLayer.swift` (`buildLand`, `buildMarks`), `WaterNode.swift` (`updateRipple`),
`LaunchOptions.swift` lines 180–330, `RaceView.swift` lines 55–125 (`SpriteView`, `ignoresSiblingOrder`).
Never read other agents' transcripts or tool-output files.
