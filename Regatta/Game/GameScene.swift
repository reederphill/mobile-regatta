import os
import SpriteKit
import RegattaBots
import RegattaCore

/// Renders the race and turns touches into rudder input. The driver runs the simulation at a fixed
/// 30 Hz (`Race.tickRate`) whatever the display's refresh rate, and the scene draws between its last
/// two ticks (`RenderWorld`). The scene never holds a `Race`.
final class GameScene: SKScene {
    static let pointsPerMeter: CGFloat = 8
    /// The follow camera's zoom until you pinch-zoom, unless the tuning panel (#232) sets another.
    static let defaultZoom = CGFloat(CameraStyle.standard.defaultZoom)

    let driver: any RaceDriver
    /// The fleet's names, which the scene never draws: boat names are never shown on the water (#15, #117).
    let roster: FleetRoster
    weak var session: GameSession?
    /// A render fixture's camera (#62), with auto zoom on and no pinch; nil takes the device's camera, auto zoom
    /// and pinch multiplier from `session.controls` (#113, #322), read every frame.
    var cameraOverride: CameraRig.Mode? {
        didSet { syncCamera() }
    }
    /// A render fixture's laylines and ladder lines (#122), standing; nil takes them from `session.controls`, read
    /// every frame.
    var cueOverride: (laylines: Bool, ladderLines: Bool)?
    /// The compass heading at the top of the screen, radians in [−π, π): the HUD's arrows turn by it (#113).
    var viewHeading: Double { rig.viewHeading }
    /// The camera's maths: course-up, boat-up, the heading lead, shots and pinch-zoom (#113, #322).
    private(set) var rig = CameraRig(pointsPerMeter: Double(GameScene.pointsPerMeter))
    /// The water's look: the debug tuning panel's (#232) seam, live, even on a paused race.
    var waterStyle: WaterStyle {
        get { water.style }
        set {
            water.style = newValue
            needsPausedRender = true
        }
    }
    /// The camera's framing: the debug tuning panel's (#232) seam, live, even on a paused race.
    var cameraStyle = CameraStyle.standard {
        didSet {
            rig.setStyle(cameraStyle)
            cam.setScale(rig.cameraScale)
            needsPausedRender = true
        }
    }
    /// How boats are drawn (#117): the debug tuning panel's (#232) seam, live, even on a paused race.
    var boatStyle = BoatStyle.standard {
        didSet { needsPausedRender = true }
    }
#if DEBUG
    /// The tuning panel's pressure overlay (#289, Debug builds): live, even on a paused race.
    var showsPressureOverlay: Bool {
        get { water.showsPressureOverlay }
        set {
            water.showsPressureOverlay = newValue
            needsPausedRender = true
        }
    }
#endif
    /// The water's tier: the thermal ladder's (#127) seam. Puff shading and the pressure draw in every tier.
    var waterQuality: WaterQuality {
        get { water.quality }
        set { water.quality = newValue }
    }
    /// The wakes' tier: the thermal ladder's (#127) seam. Every tier's wake is speed-scaled.
    var wakeQuality = WakeQuality.full
    /// The far boats' sail tier (#127): your boat and ghosts always draw in full.
    var sailDetail = SailDetail.full
    /// `-cuesOnly` (#127's UI test): draws none of what the thermal tiers change (ripple, whitecaps, wakes, sails).
    var drawsCuesOnly = false {
        didSet { needsPausedRender = true }
    }

    /// Draws at `policy`'s tiers from the next frame (#127), and at its frame rate: `RaceView` gives the same rate to
    /// its `SpriteView`, and setting it on the view here too makes a change take hold whether or not SpriteView passes
    /// a changed rate on to a view it already made.
    func apply(_ policy: RenderQualityPolicy) {
        view?.preferredFramesPerSecond = policy.fps
        waterQuality = policy.water
        wakeQuality = policy.wake
        sailDetail = policy.sail
        needsPausedRender = true
    }

    /// Whether SpriteKit draws the world and the camera's nodes: `-hideScene` turns it off for a UI test that only
    /// waits for the results (#361), so a GPU-less CI runner rasterises nothing while `render(_:)` still moves every
    /// node but the ribbons' (#377: skipped while hidden), and the race's pace no longer hangs on the runner's draw
    /// speed. The HUD and results are SwiftUI's.
    var paintsWorld = true {
        didSet {
            // The tilt node holds the world and the land's rim (#597).
            tiltNode.isHidden = !paintsWorld
            world.isHidden = !paintsWorld
            cam.isHidden = !paintsWorld
            // Its own flag too: an SK3DNode under a hidden camera must not render its SceneKit scene either.
            fleet3D?.node.isHidden = !paintsWorld
        }
    }
    /// The race's pace since the first frame that stepped it (#361), for UI tests (`PaceProbe`).
    private(set) var pace = PaceMeter()

    private let world = SKNode()
    /// The oblique projection (#596, #597). Scene ← `tiltNode` (y squashed by `cos(tilt)`) ← `rotor` (the camera's
    /// turn) ← `world` (at −centre). The camera stays at the origin, unturned, carrying only the zoom, so boat-up stays
    /// boat-up: the squash comes after the camera's turn. Whatever a camera child places against a world point takes
    /// `screenPoint(of:)`.
    private let tiltNode = SKNode()
    private let rotor = SKNode()
    /// The tilt drawn now, degrees off vertical (#597): eased to `targetTilt` each frame, snapped in a settled one.
    private(set) var shownTilt: Double?
    /// How fast the shown tilt closes on the setting, per second: about 0.5 s to settle, like a camera change.
    static let tiltEaseRate = 6.0
    /// The device's tilt (`ControlSettings.tilt`, `-tilt` over it), read every frame.
    private var targetTilt: Double {
        session?.controls.tilt ?? ControlSettings.tilt(DeviceSettings.defaultTilt, launchOptions: .current)
    }
    private var tiltDegrees: Double { shownTilt ?? targetTilt }
    /// Screen-up's share of its length at the tilt drawn (`ChartGeometry.obliqueSquash`).
    var squash: CGFloat { ChartGeometry.obliqueSquash(tiltDegrees: tiltDegrees) }
    /// The fleet, buoys and committee boat standing up (#596, #597): every boat's hull, rig and sail.
    private var fleet3D: Fleet3D?
    /// The standing fleet, for tests.
    var standingFleet: Fleet3D? { fleet3D }
    /// The land's extruded rim (#596), a child of `world` (so it turns with the camera): the land's silhouette, built
    /// once, in `landRimSteps` copies sharing one path, each dropped a share of the rim's height down the screen.
    private let landRim = SKNode()
    /// The rim's drop in `world` space at the last frame drawn, so a still frame writes nothing.
    private var landRimDrop: CGPoint?
    /// How many copies of the silhouette sweep the rim: one alone leaves a notch where a coast runs straight down the
    /// screen (the union of the land and its one dropped copy misses a triangle there), `1 / (2n)` of the drop deep.
    static let landRimSteps = 3
    /// The rim's one path, in world points, built once (`buildLandRim`); nil with no land.
    private(set) var landRimPath: CGPath?
    /// The rim's copies, nearest the land first, for tests.
    var landRimLayers: [SKShapeNode] { landRim.children.compactMap { $0 as? SKShapeNode } }
    private let cam = SKCameraNode()
    private let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
    private let effectsLayer = SKNode()
    /// The fleet's wind shadow (#377): the sim's turbulence ribbons, one faint layer in the effects layer, under every
    /// boat's backwind and wake.
    private(set) lazy var trailLayer = TurbulenceTrailLayer(pointsPerMeter: ppm)
    private let courseLayer = SKNode()
    private let boatLayer = SKNode()
    /// The boat-side cues (#122) in the world, under the fleet: laylines, ladder lines and your wind vane with its
    /// groove tick and arc. Each a named node, the same in every thermal tier (#127).
    private let cueLayer = SKNode()
    private let laylines = SKShapeNode()
    private let ladderLines = SKShapeNode()
    private let vaneArc = SKShapeNode()
    private let vane = SKShapeNode()
    private let grooveTick = SKShapeNode()
    /// The next-mark edge arrow (#15): the camera's child, so it stays put on screen as the view zooms and turns.
    private let edgeArrow = SKShapeNode()
    /// A hint's leader line (#129), on the camera.
    private let hintLeader = HintLeaderLayer()
    /// The camera scale the ladder lines were last built for: a zoom past it rebuilds them.
    private var ladderScale: CGFloat = 0
    /// The vane's and tick's length the paths were built for, points.
    private var vaneLength: CGFloat = 0
    /// Race area, land, shallows, marks and the start line (#115).
    private(set) lazy var chart = ChartLayer(course: driver.course, venue: driver.venue, pointsPerMeter: ppm)
    private var boatNodes: [BoatNode] = []
    /// The rule cues (#123) over the fleet: built with it.
    private var ruleCues: RuleCueLayer?
    /// Whether the rule cues draw: a render fixture's turn them off unless it asks for them.
    var showsRuleCues = true
    /// The rule calls whose lines draw (#123): the session adds each one it drains.
    var ruleCalls = RuleCallLines()
    /// Your last served penalty turn's flash on the arc (#489): the session tells it each serve it drains, and the scene
    /// reads it each frame it draws your owed turn.
    var servedTurn = ServedTurnFlash()

    private var lastUpdate: TimeInterval?
    /// The most wall-clock time a frame spends starting ticks: half a 60 Hz frame. A frame is at most
    /// 0.1 s of real time, so at `-timescale 32` it can owe about 100 ticks; unbudgeted, a slow simulator
    /// spent every frame catching up and the main thread never idled to draw or answer UI tests.
    static let tickBudget: Duration = .milliseconds(8)
    /// The race clock last drawn, so effects run on simulated time (`-timescale` included).
    private var lastRenderTime: Double?
    /// Whether fingers are pinching: the rig's pinch multiplier, not the saved one, stands until they lift.
    private var isPinching = false
    private var hudCountdown = 0.0
    private var cueCountdown = 0.0
    /// A render-only value changed while the race is paused: draw the standing world once more with it.
    private var needsPausedRender = false

    /// Touches on the water to rudder, in the device's steering scheme (#112). Internal for tests (`resetInput`).
    var steering = SteeringInterpreter()

    init(driver: any RaceDriver, roster: FleetRoster) {
        self.driver = driver
        self.roster = roster
        // A placeholder: `RaceView` sets the size from `RaceViewportPolicy`, so the visible world area
        // doesn't depend on the window. The view has the scene's aspect, so aspect-fit scales it uniformly.
        super.init(size: CGSize(width: 390, height: 844))
        scaleMode = .aspectFit
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backgroundColor = ChartPalette.water.uiColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var ppm: CGFloat { GameScene.pointsPerMeter }

    private func point(_ v: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm)
    }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        guard world.parent == nil else { return }
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        view.addGestureRecognizer(Self.zoomResetRecognizer(target: self, action: #selector(doubleTapped(_:))))

        water.zPosition = -10
        effectsLayer.zPosition = 0
        courseLayer.zPosition = 1
        cueLayer.zPosition = 2
        boatLayer.zPosition = 3
        [water, effectsLayer, courseLayer, cueLayer, boatLayer].forEach(world.addChild)
        // Every node in the layers has a z of its own too (`DrawOrder`). Named, so a test can say which is which.
        let layers: [(SKNode, String)] = [(water, "water"), (effectsLayer, "effects"), (courseLayer, "course"),
                                          (cueLayer, "cues"), (boatLayer, "fleet")]
        for (layer, name) in layers { layer.name = name }
        tiltNode.yScale = squash
        rotor.addChild(world)
        tiltNode.addChild(rotor)
        addChild(tiltNode)

        addChild(cam)
        camera = cam
        cam.setScale(rig.cameraScale)
        cam.position = .zero

        buildCues()
        buildCourse()
        buildBoats()
        buildTilt()
    }

    /// The standing fleet and the land's rim (#596).
    private func buildTilt() {
        let frame = driver.currentFrame
        let fleet = Fleet3D(boats: frame.boats, colors: frame.boats.map { Palette.boat($0.colorIndex) },
                            boatClass: driver.boatClass, course: driver.course, pointsPerMeter: ppm,
                            tiltDegrees: tiltDegrees, sceneSize: size)
        // Over the fleet layer's shadows and glows (global z 5…14), under the rule cues (16) and the edge arrow (20)
        // (`DrawOrder`).
        fleet.node.zPosition = DrawOrder.standingFleet
        fleet.node.name = "fleet3D"
        fleet.node.isHidden = !paintsWorld
        cam.addChild(fleet.node)
        fleet3D = fleet

        buildLandRim()
    }

    /// The land's rim (#596), built once: every land polygon in one path in world points (pieces that share an edge,
    /// Fellmere's, fill as one), drawn just under the land's top fill. Each frame only moves the copies
    /// (`updateLandRim`): the sweep of the silhouette down the screen is the rim, so a coast facing the viewer shows a
    /// face and one facing away hides under the land's fill.
    private func buildLandRim() {
        landRim.name = "landRim"
        let polygons = driver.venue.land.map(\.points)
        guard !polygons.isEmpty else { return }
        let path = CGMutablePath()
        for points in polygons {
            path.addLines(between: points.map(point))
            path.closeSubpath()
        }
        landRimPath = path
        for step in 0..<Self.landRimSteps {
            let layer = SKShapeNode(path: path)
            layer.fillColor = ChartPalette.landmark.uiColor
            layer.strokeColor = .clear
            layer.lineWidth = 0
            // Just under the land's top fill (course layer 1 + `ChartLayer.landZ` −2 = −1), over the water (−10) and
            // shallows; the deeper copies under the nearer, each its own z (`DrawOrder`).
            layer.zPosition = -2.5 - 0.1 * CGFloat(step)
            layer.name = "landRim-\(step + 1)"
            landRim.addChild(layer)
        }
        world.addChild(landRim)
    }

    /// The rim's copies moved to this frame's drop: 6 m standing, shown `sin(tilt)` tall on screen, so
    /// `6 · tan(tilt)` metres down the screen before the squash; screen-down turned into `world` space by the camera's
    /// rotation. Copy `k` of `n` drops `k / n` of it. Written only when the drop changes.
    private func updateLandRim() {
        let drop = 6 * ppm * ChartGeometry.obliqueRise(tiltDegrees: tiltDegrees)
            / ChartGeometry.obliqueSquash(tiltDegrees: tiltDegrees)
        // `rotor` turns `world` by −rotation: screen-down (0, −drop) is (drop·sin θ, −drop·cos θ) in `world`.
        let theta = rig.cameraRotation
        let offset = CGPoint(x: drop * sin(theta), y: -drop * cos(theta))
        guard offset != landRimDrop else { return }
        landRimDrop = offset
        let layers = landRimLayers
        for (step, layer) in layers.enumerated() {
            let share = CGFloat(step + 1) / CGFloat(layers.count)
            layer.position = CGPoint(x: offset.x * share, y: offset.y * share)
        }
    }

    private func buildCourse() {
        chart.install(in: world, courseLayer: courseLayer)
    }

    /// The cue layer's nodes, a z each in drawing order, and the edge arrow on the camera, over everything.
    private func buildCues() {
        let cues: [(SKShapeNode, String)] = [(ladderLines, "ladderLines"), (laylines, "laylines"), (vaneArc, "vaneArc"),
                                            (vane, "windVane"), (grooveTick, "grooveTick")]
        for (slot, (node, name)) in cues.enumerated() {
            node.name = name
            node.zPosition = DrawOrder.z(slot)
            node.lineCap = .round
            node.lineJoin = .round
            cueLayer.addChild(node)
        }
        for node in [vaneArc, vane, grooveTick] {
            node.strokeColor = CuePalette.vermillion.uiColor
        }

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 11, y: 0))
        arrow.addLine(to: CGPoint(x: -7, y: 8))
        arrow.addLine(to: CGPoint(x: -3, y: 0))
        arrow.addLine(to: CGPoint(x: -7, y: -8))
        arrow.closeSubpath()
        edgeArrow.path = arrow
        edgeArrow.name = "edgeArrow"
        edgeArrow.fillColor = CuePalette.orange.uiColor
        edgeArrow.strokeColor = UIColor.black.withAlphaComponent(0.35)
        edgeArrow.lineWidth = 1
        edgeArrow.lineJoin = .round
        // Over everything: the fleet layer tops out about 14, the standing fleet is 15 and the rule cues 16
        // (`DrawOrder`).
        edgeArrow.zPosition = 20
        edgeArrow.isHidden = true
        cam.addChild(edgeArrow)
        cam.addChild(hintLeader.node)
    }

    private func buildBoats() {
        let me = driver.myBoatIndex
        effectsLayer.addChild(trailLayer)
        let pool = TurbulenceTrailLayer.reserve(boats: driver.currentFrame.boats.count)
        trailLayer.reserve(strips: pool.strips, discs: pool.discs)
        for boat in driver.currentFrame.boats {
            let node = BoatNode(boat: boat, isMine: boat.id == me, color: Palette.boat(boat.colorIndex),
                                boatClass: driver.boatClass, pointsPerMeter: ppm, style: boatStyle)
            boatNodes.append(node)
            boatLayer.addChild(node)
            node.effects.nodes.forEach(effectsLayer.addChild)
        }
        // Over the fleet layer (top z about 14) and the standing fleet (15), under the edge arrow (20) (`DrawOrder`).
        let rules = RuleCueLayer(pointsPerMeter: ppm)
        rules.zPosition = 16
        world.addChild(rules)
        ruleCues = rules
#if DEBUG
        // #57's 16-boat demo: what the fleet's wakes and backwinds cost, once at race start (#121).
        if LaunchOptions.current.perf {
            // The boats' own effects only (`BoatEffects`), not the rest of the effects layer.
            let nodes = boatNodes.reduce(0) { $0 + $1.effects.nodeCount }
            Logger(subsystem: "com.phillreeder.regatta", category: "perf")
                .info("Boat effects: \(nodes, privacy: .public) nodes for \(self.boatNodes.count, privacy: .public) boats")
        }
#endif
    }

    // MARK: - Loop

    override func update(_ currentTime: TimeInterval) {
        // A render fixture draws the same settled world every frame: nothing steps and nothing eases.
        if driver.isFrozen {
            render(driver.renderWorld, settled: true)
            return
        }
        let frameTime = min(currentTime - (lastUpdate ?? currentTime), 0.1)
        lastUpdate = currentTime
        guard let session else { return }
        // The notices posted as the race was set up get their time from its first frame (#129).
        session.sceneStarted()
        guard !session.isPaused else {
            // The tuning panel's render-only values show over a paused race (#232). Nothing steps: no time passes.
            if needsPausedRender {
                needsPausedRender = false
                render(driver.renderWorld)
            }
            return
        }

        syncScheme()
        submitInput(after: frameTime)
        let clock = ContinuousClock()
        let tickStart = clock.now
        let ticks = driver.tick(frameTime, within: Self.tickBudget).count
        let renderStart = clock.now
        Signpost.renderUpdate.measure { render(driver.renderWorld) }
        let renderEnd = clock.now
        pace.record(ticks: ticks, tickTime: renderStart - tickStart, renderTime: renderEnd - renderStart, at: renderEnd)
        session.consume(driver.drainEvents())

        hudCountdown -= frameTime
        if hudCountdown <= 0 {
            hudCountdown = 1.0 / 15
            Signpost.hudRefresh.measure { session.refreshHUD() }
        }
    }

    /// Draws `world`. `settled` draws it as if it had been standing still forever: the camera on its
    /// target and every sail trimmed, with no easing towards them (a frozen render fixture).
    private func render(_ world: RenderWorld, settled: Bool = false) {
        // Simulated seconds since the last frame drawn.
        let dt = settled ? 0 : max(0, world.time - (lastRenderTime ?? world.time))
        lastRenderTime = world.time
        var poses: [BoatPose] = []
        for (i, boat) in world.boats.enumerated() {
            let pose = BoatPose(boat, ease: world.ease(ofSeat: i), isGhost: world.isGhost(ofSeat: i),
                                boatClass: world.boatClass, style: boatStyle, autohelm: world.autohelm(ofSeat: i))
            poses.append(pose)
            let backwind = world.backwind(ofSeat: i)
            boatNodes[i].hidesDecoration = drawsCuesOnly
            boatNodes[i].update(with: boat, pose: pose, style: boatStyle, wakeQuality: wakeQuality,
                                time: world.time, dt: dt, settled: settled, backwindSail: backwind.sail,
                                backwindSide: backwind.side, justSeated: world.frame.isJustSeated)
        }
        // The sim's ribbons at the time drawn, between the last two ticks (`ribbons(of:time:)`). Not while the world
        // isn't painted (`-hideScene`): they are pure paint and most of a 16-boat frame's render (#377), so a hidden
        // race spends its frame on ticks. They come back with the next frame painted.
        if paintsWorld { trailLayer.update(wake: world.frame.wake, time: world.time, style: boatStyle) }

        syncCamera()
        rig.visibleInsets = viewInsets
        var cameraWorld = CameraWorld(world)
        cameraWorld.area = chart.framing
        rig.advance(cameraWorld, sceneSize: size, dt: dt, settled: settled)
        // #596: the camera stays at the origin, unturned; the world moves and turns under the squash instead.
        easeTilt(dt: dt, settled: settled)
        cam.position = .zero
        cam.setScale(rig.cameraScale)
        cam.zRotation = 0
        self.world.position = CGPoint(x: -rig.center.x, y: -rig.center.y)
        rotor.zRotation = -rig.cameraRotation
        pointShimmer(world)

        let view = WaterView(center: rig.center, sceneSize: CGSize(width: size.width, height: size.height / squash),
                             scale: rig.cameraScale, rotation: rig.cameraRotation)
        water.hidesRipple = drawsCuesOnly
        Signpost.waterUpdate.measure { water.update(WaterWorld(world), view: view, dt: dt) }

        // The active leg's marks orange, the rest grey (#15); strokes kept steady on screen as the camera zooms.
        chart.update(status: world.me.status, legIndex: world.me.legIndex, cameraScale: rig.cameraScale)
        // Not while the world isn't painted (`-hideScene`): the standing fleet is pure paint.
        if let fleet3D, paintsWorld {
            fleet3D.update(world, poses: poses, style: boatStyle, center: rig.center, rotation: rig.cameraRotation,
                           cameraScale: rig.cameraScale, tiltDegrees: tiltDegrees, sceneSize: size,
                           sailDetail: sailDetail, hidesSails: drawsCuesOnly, time: world.time, dt: dt, settled: settled)
            updateLandRim()
        }

        updateCues(world, dt: dt, settled: settled)
        ruleCues?.isHidden = !showsRuleCues
        if showsRuleCues {
            let mine = world.myBoatIndex
            servedTurn.follow(world.frame.owed.indices.contains(mine) ? world.frame.owed[mine] : nil)
            ruleCues?.update(world, calls: ruleCalls, served: servedTurn, style: boatStyle, px: cam.xScale,
                             rotation: rig.cameraRotation, squash: squash)
        } else {
            ruleCues?.reset()
        }
        // The right-of-way glows are the boats' own (#123): each seat's from the layer's, none while the cues are off.
        let glows = ruleCues?.glows ?? []
        for (seat, node) in boatNodes.enumerated() {
            node.setRightOfWayGlow(seat < glows.count ? glows[seat] : nil, style: boatStyle)
        }
    }

    /// Eases the shown tilt to the device's (#597), at `tiltEaseRate`; a settled frame snaps to it. On the sim's `dt`,
    /// as the camera eases: a paused race holds the tilt where it was, and a change made in Settings mid-pause lands
    /// once the race runs again.
    private func easeTilt(dt: Double, settled: Bool) {
        let target = targetTilt
        if settled || shownTilt == nil {
            shownTilt = target
        } else if let shown = shownTilt {
            let next = shown + (target - shown) * min(1, dt * Self.tiltEaseRate)
            shownTilt = abs(target - next) < 0.01 ? target : next
        }
        tiltNode.yScale = squash
    }

    /// Where world point `world` (metres) draws on screen this frame, in scene points from the view's bottom left:
    /// the rig's flat projection with screen-up squashed by the tilt (`ChartGeometry.obliqueSquash`) about the view's
    /// centre (#597). Every camera child placed against a world point reads it.
    func screenPoint(of world: Vec2) -> CGPoint {
        let flat = rig.project(world, sceneSize: size)
        let centreY = size.height / 2
        return CGPoint(x: flat.x, y: centreY + (flat.y - centreY) * squash)
    }

    /// The tilt drawn, whole degrees, for UI tests (`CueProbe`): e.g. `tilt=45`.
    var tiltSummary: String { "tilt=\(Int(tiltDegrees.rounded()))" }

    /// The edge arrow's position on the camera and whether it shows, for tests.
    var edgeArrowPlacement: CGPoint? { edgeArrow.isHidden ? nil : edgeArrow.position }

    /// Points the ribbons' shimmer at the water this frame (`TurbulenceTrailLayer.setView`): a drawable pixel's world
    /// metres through the camera as just set.
    private func pointShimmer(_ world: RenderWorld) {
        guard let view else { return }
        let frame = TurbulenceTrailLayer.pixelFrame(viewSize: view.bounds.size, pixelScale: view.contentScaleFactor,
                                                    sceneSize: size, camera: cam, layer: trailLayer,
                                                    metresPerPoint: 1 / Double(ppm))
        TurbulenceTrailLayer.setView(pixel: frame, time: world.time)
    }

    /// What the rule cues show (#123), for tests: e.g. `glows=2 lines=1 arc=1`.
    var ruleCueSummary: String { ruleCues?.summary ?? "" }
    /// The penalty arc's tack and gybe marks as drawn (#489, `RuleCueLayer.marksSummary`), for tests.
    var penaltyMarksSummary: String { ruleCues?.marksSummary ?? "none" }
    /// The right-of-way glow each seat shows, for tests.
    var shownGlows: [RightOfWayGlow?] { ruleCues?.glows ?? [] }
    /// Each seat's right-of-way halo as drawn, nil where hidden (#517: orange on a boat taking a penalty), for tests.
    var shownHalos: [(colour: UIColor, alpha: CGFloat)?] { boatNodes.map(\.shownRightOfWayHalo) }
    /// Whether a hint's leader line shows (#129), for tests.
    var showsHintLeader: Bool { hintLeader.isShowing }

    /// The north-up course camera over `course` in a scene of `sceneSize` (`CameraRig.courseFraming`): centred on
    /// the course, scaled to show the whole of it (marks, pin and committee boat) with a margin, and never closer
    /// than `zoom`.
    static func courseFraming(_ course: CourseLayout, sceneSize: CGSize, zoom: CGFloat,
                              margin: CGFloat = CGFloat(CameraStyle.standard.courseMargin)) -> (center: CGPoint, scale: CGFloat)? {
        CameraRig.courseFraming(course.obstacles.map(\.position), sceneSize: sceneSize, zoom: zoom, margin: margin,
                                pointsPerMeter: Double(pointsPerMeter))
    }

    /// The pace line a UI test reads (`PaceProbe`, #361): `PaceMeter.summary` and the race clock's tick.
    var paceSummary: String { "\(pace.summary), race tick \(driver.currentFrame.tick)" }

    // MARK: - Cues

    /// What the cues show, for UI tests (`CueProbe`): each of laylines, ladder lines, your vane and the edge arrow,
    /// 1 when drawn, 0 when hidden, e.g. `laylines=1 ladder=0 vane=1 arrow=0`.
    var cueSummary: String {
        func shown(_ node: SKNode) -> Int { node.isHidden ? 0 : 1 }
        return "laylines=\(shown(laylines)) ladder=\(shown(ladderLines)) vane=\(shown(vane)) arrow=\(shown(edgeArrow))"
    }

    /// Draws the cues (#122) over `world` with the camera of this frame. The laylines and ladder lines are redrawn
    /// four times a second, at once in a settled frame, and at once when turned back on; the ladder lines also as
    /// the zoom changes, so they always reach past the view. The vane and edge arrow every frame.
    private func updateCues(_ world: RenderWorld, dt: Double, settled: Bool) {
        let style = boatStyle
        // Line widths in screen points, whatever the zoom.
        let px = cam.xScale
        let showsLaylines = cueOverride?.laylines ?? session?.controls.showsLaylines ?? true
        let showsLadderLines = cueOverride?.ladderLines ?? session?.controls.showsLadderLines ?? false
        let laylinesTurnedOn = showsLaylines && laylines.isHidden
        let ladderTurnedOn = showsLadderLines && ladderLines.isHidden
        laylines.isHidden = !showsLaylines
        ladderLines.isHidden = !showsLadderLines
        laylines.strokeColor = CuePalette.yellow.uiColor.withAlphaComponent(CGFloat(style.laylineAlpha))
        laylines.lineWidth = 1.5 * px
        ladderLines.strokeColor = CuePalette.cueWhite.uiColor.withAlphaComponent(CGFloat(style.ladderLineAlpha))
        ladderLines.lineWidth = 1 * px

        cueCountdown -= dt
        let refresh = settled || cueCountdown <= 0
        if refresh { cueCountdown = 0.25 }
        if showsLaylines && (refresh || laylinesTurnedOn) { updateLaylines(world) }
        let zoomed = abs(px / max(ladderScale, 1e-6) - 1) > 0.01
        if showsLadderLines && (refresh || ladderTurnedOn || zoomed) { updateLadderLines(world) }
        updateVane(world, style: style, px: px)
        updateEdgeArrow(world)
        updateHintLeader(world)
    }

    /// The showing hint's leader line (#129), from under the notice pill to its target.
    private func updateHintLeader(_ world: RenderWorld) {
        let sceneSize = size
        let top = (view?.safeAreaInsets.top ?? 0)
            + HUDView.noticeTop(showsLeaderboard: session?.controls.showsLeaderboard ?? false) + HintLeader.pillHeight
        hintLeader.update(notice: session?.notice, world: world, sceneSize: sceneSize, anchorFromTop: top,
                          visible: rig.visibleInsets.visibleRect(sceneSize: sceneSize),
                          project: { [unowned self] in screenPoint(of: $0) })
    }

    /// Your laylines, from the formula a bot sees them by (`Laylines`, `SeatView.laylines`): dashed.
    private func updateLaylines(_ world: RenderWorld) {
        let me = world.me
        let course = world.course
        let leg = course.legSailed(status: me.status, legIndex: me.legIndex)
        let path = CGMutablePath()
        for line in LaylineCue.segments(for: leg, in: course, polar: world.boatClass.polar, wind: world.groundWind(at:)) {
            path.move(to: point(line.from))
            path.addLine(to: point(line.to))
        }
        laylines.path = path.isEmpty ? nil : path.copy(dashingWithPhase: 0, lengths: [10, 10])
    }

    /// The ladder lines across the view and well past it, so a quarter second of panning never shows their ends.
    private func updateLadderLines(_ world: RenderWorld) {
        let me = world.me
        let course = world.course
        let leg = course.legSailed(status: me.status, legIndex: me.legIndex)
        let centre = Vec2(Double(rig.center.x / ppm), Double(rig.center.y / ppm))
        ladderScale = cam.xScale
        // The squash shows more water up the screen: the lines reach past that too.
        let radius = Double(hypot(size.width, size.height / squash) * cam.xScale / ppm)
        let path = CGMutablePath()
        for line in LadderCue.segments(for: leg, in: course, centre: centre, radius: radius,
                                       spacing: boatStyle.ladderSpacingMetres) {
            path.move(to: point(line.from))
            path.addLine(to: point(line.to))
        }
        ladderLines.path = path
    }

    /// Your wind vane, its groove tick and any pinch or foot arc (`VaneCue`), under your hull.
    private func updateVane(_ world: RenderWorld, style: BoatStyle, px: CGFloat) {
        let me = world.me
        let seat = world.myBoatIndex
        guard let cue = VaneCue(me, reading: world.autohelm(ofSeat: seat), isGhost: world.isGhost(ofSeat: seat),
                                boatClass: world.boatClass, style: style) else {
            [vane, grooveTick, vaneArc].forEach { $0.isHidden = true }
            return
        }
        let length = CGFloat(world.boatClass.hull.length * style.vaneLengthHulls) * ppm
        if length != vaneLength {
            vaneLength = length
            let head = min(length * 0.18, 6)
            let shaft = CGMutablePath()
            shaft.move(to: .zero)
            shaft.addLine(to: CGPoint(x: 0, y: length))
            shaft.move(to: CGPoint(x: -head * 0.6, y: length - head))
            shaft.addLine(to: CGPoint(x: 0, y: length))
            shaft.addLine(to: CGPoint(x: head * 0.6, y: length - head))
            vane.path = shaft
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: 0, y: length * 0.8))
            tick.addLine(to: CGPoint(x: 0, y: length * 1.2))
            grooveTick.path = tick
        }
        let at = point(me.position)
        // Angles off the bow, to starboard: a node turned by −(heading + angle) has its +y along that bearing.
        for node in [vane, grooveTick, vaneArc] {
            node.isHidden = false
            node.position = at
        }
        vane.zRotation = CGFloat(-(me.heading + cue.vane))
        grooveTick.zRotation = CGFloat(-(me.heading + cue.tick))
        vane.lineWidth = 2 * px
        grooveTick.lineWidth = 2.5 * px
        vaneArc.lineWidth = 2 * px

        guard let end = cue.arcEnd else {
            vaneArc.isHidden = true
            return
        }
        // The arc from the tick to the angle the autohelm holds, at the vane's length, the short way round.
        vaneArc.zRotation = CGFloat(-me.heading)
        let sweep = wrapAngle(end - cue.tick)
        let arc = CGMutablePath()
        let steps = 12
        for i in 0...steps {
            let a = cue.tick + sweep * Double(i) / Double(steps)
            let p = CGPoint(x: length * CGFloat(sin(a)), y: length * CGFloat(cos(a)))
            if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
        }
        vaneArc.path = arc
    }

    /// What the HUD and controls cover of the view (#122, `EdgeArrow.insets`): the edge arrow and the rig's line
    /// ends read the same clear area. The scene draws under the safe area; the HUD and controls keep inside it.
    private var viewInsets: ViewInsets {
        let safe = view?.safeAreaInsets ?? .zero
        return EdgeArrow.insets(safeArea: (top: safe.top, bottom: safe.bottom),
                                showsLeaderboard: session?.controls.showsLeaderboard ?? false, style: boatStyle)
    }

    /// The next-mark edge arrow (`EdgeArrow`), on the camera: shown only while what you sail for is off screen.
    private func updateEdgeArrow(_ world: RenderWorld) {
        let me = world.me
        let sceneSize = size
        let targets = EdgeArrow.targets(status: me.status, legIndex: me.legIndex, course: world.course)
        guard !world.isGhost(ofSeat: world.myBoatIndex),
              let placed = EdgeArrow.placement(targets: targets, project: { [unowned self] in screenPoint(of: $0) },
                                               visible: rig.visibleInsets.visibleRect(sceneSize: sceneSize)) else {
            edgeArrow.isHidden = true
            return
        }
        edgeArrow.isHidden = false
        // The camera's children are placed from the view's centre, in screen points.
        edgeArrow.position = CGPoint(x: placed.position.x - sceneSize.width / 2, y: placed.position.y - sceneSize.height / 2)
        edgeArrow.zRotation = placed.angle
    }

    // MARK: - Input

    /// Follows the device's scheme, live (#131): a change lets go of every touch.
    private func syncScheme() {
        guard let session, steering.scheme != session.controls.steering else { return }
        steering.scheme = session.controls.steering
        publishTillerKnob()
    }

    /// Follows the device's camera, auto zoom and pinch multiplier, live (#113, #131, #322): a change of camera
    /// eases, it doesn't snap. A render fixture's camera stands instead, unpinched.
    private func syncCamera() {
        if let cameraOverride {
            rig.mode = cameraOverride
            rig.autoZoom = true
            rig.setZoomMultiplier(1)
        } else if let session {
            rig.mode = session.controls.camera == .boatUp ? .boatUp : .courseUp
            rig.autoZoom = session.controls.autoZoom
            if !isPinching { rig.setZoomMultiplier(session.controls.zoomMultiplier) }
        }
    }

    /// Hands the tiller's track and knob to the session for `RaceView` to draw, when they move, and the gesture's
    /// ease when it changes.
    private func publishTillerKnob() {
        publishEase()
        guard let session, session.tillerKnob != steering.tillerKnob else { return }
        session.tillerKnob = steering.tillerKnob
    }

    /// The steering gesture's ease as last handed to the session (#453).
    private var publishedEase = false

    /// Hands the gesture's ease to the session when the interpreter's changes: the tiller's pull ticks.
    private func publishEase() {
        guard steering.isEasing != publishedEase else { return }
        publishedEase = steering.isEasing
        session?.setGestureEase(publishedEase, ticks: steering.scheme == .tiller)
    }

    /// Sends this frame's input: the rudder moved on by `frameTime` seconds, and Ease. The driver latches it for the
    /// next tick. With `-demo` a bot sails your seat and ignores it.
    func submitInput(after frameTime: Double) {
        let rudder = steering.advance(by: frameTime)
        publishEase()
        driver.submit(BoatInput(rudder: rudder, ease: session?.isEasing ?? false))
    }

    /// A finger lands on the water at `point`, in view points: the first one ends the opening's seated ease (#477).
    func touchBegan(_ id: AnyHashable, at point: CGPoint, midX: CGFloat) {
        session?.endSeatedEase()
        steering.touchBegan(id, at: point, midX: midX)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        syncScheme()
        for touch in touches {
            touchBegan(ObjectIdentifier(touch), at: touch.location(in: view), midX: view.bounds.midX)
        }
        publishTillerKnob()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        for touch in touches {
            steering.touchMoved(ObjectIdentifier(touch), to: touch.location(in: view))
        }
        publishTillerKnob()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            steering.touchEnded(ObjectIdentifier(touch))
        }
        publishTillerKnob()
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        // A pinch-zoom never steers (#13).
        switch gesture.state {
        case .began: steering.pinchBegan(); publishTillerKnob(); isPinching = true
        case .ended, .cancelled, .failed:
            steering.pinchEnded()
            isPinching = false
            // The multiplier is kept across races (#322): saved once, when the fingers lift.
            if cameraOverride == nil { session?.controls.keepZoomMultiplier(rig.zoomMultiplier) }
        default: break
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        rig.pinchChanged(by: Double(gesture.scale))
        gesture.scale = 1
        cam.setScale(rig.cameraScale)
    }

    /// The pinch-zoom's reset (#322): a two-finger double tap, the fingers of the pinch it undoes, so a quick
    /// one-finger double tap that steers (the halves scheme taps the screen's halves) never resets the zoom. The
    /// taps still reach the scene as touches.
    static func zoomResetRecognizer(target: Any?, action: Selector?) -> UITapGestureRecognizer {
        let doubleTap = UITapGestureRecognizer(target: target, action: action)
        doubleTap.numberOfTouchesRequired = 2
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesEnded = false
        return doubleTap
    }

    /// A two-finger double tap: the pinch-zoom eases back to every shot's own zoom, and that's kept (#322).
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, cameraOverride == nil else { return }
        rig.resetZoomMultiplier()
        session?.controls.keepZoomMultiplier(rig.zoomMultiplier)
    }

    /// Clears held touches, e.g. when an overlay steals them.
    func resetInput() {
        steering.reset()
        publishTillerKnob()
        lastUpdate = nil
    }
}
