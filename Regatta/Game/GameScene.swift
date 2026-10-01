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

    private let world = SKNode()
    private let cam = SKCameraNode()
    private let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
    private let effectsLayer = SKNode()
    private let courseLayer = SKNode()
    private let boatLayer = SKNode()
    private let laylines = SKShapeNode()
    private let startLine = SKShapeNode()
    private var boatNodes: [BoatNode] = []

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
    private var laylineCountdown = 0.0
    /// A render-only value changed while the race is paused: draw the standing world once more with it.
    private var needsPausedRender = false

    /// Touches on the water to rudder, in the device's steering scheme (#112).
    private var steering = SteeringInterpreter()

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
        laylines.zPosition = 2
        boatLayer.zPosition = 3
        [water, effectsLayer, courseLayer, laylines, boatLayer].forEach(world.addChild)
        // Every node in the layers has a z of its own too (`DrawOrder`). Named, so a test can say which is which.
        let layers: [(SKNode, String)] = [(water, "water"), (effectsLayer, "effects"), (courseLayer, "course"),
                                          (laylines, "laylines"), (boatLayer, "fleet")]
        for (layer, name) in layers { layer.name = name }
        addChild(world)

        addChild(cam)
        camera = cam
        cam.setScale(rig.cameraScale)
        cam.position = point(driver.renderWorld.me.position)

        laylines.strokeColor = UIColor.white.withAlphaComponent(0.22)
        laylines.lineWidth = 1

        buildCourse()
        buildBoats()
    }

    private func buildCourse() {
        let course = driver.course

        for mark in course.elements.flatMap(\.marks) {
            let zone = SKShapeNode(circleOfRadius: CGFloat(course.zoneRadius) * ppm)
            zone.path = zone.path?.copy(dashingWithPhase: 0, lengths: [6, 6])
            zone.strokeColor = UIColor.white.withAlphaComponent(0.18)
            zone.lineWidth = 1
            zone.position = point(mark.position)
            courseLayer.addChild(zone)
            courseLayer.addChild(buoy(at: mark.position, radius: mark.radius, color: CuePalette.orange.uiColor))
        }

        // The line's ends are marks (#15), so the pin is a mark's orange, not yellow: yellow is the laylines' (#22).
        let pin = course.startLine.pin
        courseLayer.addChild(buoy(at: pin.position, radius: pin.radius, color: CuePalette.orange.uiColor))

        let committee = SKShapeNode(ellipseOf: CGSize(width: 4.6 * ppm, height: 5.2 * ppm))
        committee.fillColor = UIColor(white: 0.95, alpha: 1)
        committee.strokeColor = UIColor(white: 0.55, alpha: 1)
        committee.lineWidth = 1.5
        committee.position = point(course.startLine.committee.position)
        // The flag is the course layer's own node, not the committee boat's child, so it takes a z of its own.
        let flag = SKShapeNode(rect: CGRect(x: -3, y: -3, width: 10, height: 7))
        flag.fillColor = CuePalette.orange.uiColor
        flag.lineWidth = 0
        flag.position = committee.position
        courseLayer.addChild(committee)
        courseLayer.addChild(flag)

        let line = CGMutablePath()
        line.move(to: point(course.startLine.pin.position))
        line.addLine(to: point(course.startLine.committee.position))
        startLine.path = line.copy(dashingWithPhase: 0, lengths: [8, 6])
        startLine.lineWidth = 2
        courseLayer.addChild(startLine)

        // A z each (`DrawOrder`), in the order built: the start line crosses the pin and the committee boat, and
        // draws over them.
        for (slot, node) in courseLayer.children.enumerated() {
            node.zPosition = DrawOrder.z(slot)
        }
    }

    private func buoy(at position: Vec2, radius: Double, color: UIColor) -> SKNode {
        let node = SKShapeNode(circleOfRadius: max(CGFloat(radius) * ppm, 5))
        node.fillColor = color
        node.strokeColor = .white
        node.lineWidth = 1.5
        node.position = point(position)
        return node
    }

    private func buildBoats() {
        let me = driver.myBoatIndex
        for boat in driver.currentFrame.boats {
            let node = BoatNode(boat: boat, isMine: boat.id == me, color: Palette.boat(boat.colorIndex),
                                boatClass: driver.boatClass, pointsPerMeter: ppm)
            boatNodes.append(node)
            boatLayer.addChild(node)
            effectsLayer.addChild(node.shadowCone)
            effectsLayer.addChild(node.wake)
        }
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
        guard !session.isPaused else {
            // The tuning panel's render-only values show over a paused race (#232). Nothing steps: no time passes.
            if needsPausedRender {
                needsPausedRender = false
                render(driver.renderWorld)
            }
            return
        }

        syncScheme()
        let rudder = steering.advance(by: frameTime)
        // The driver latches it for the next tick. With `-demo` a bot sails your seat and ignores it.
        driver.submit(BoatInput(rudder: rudder, ease: session.isEasing))
        driver.tick(frameTime, within: Self.tickBudget)

        Signpost.renderUpdate.measure { render(driver.renderWorld) }
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
        for (i, boat) in world.boats.enumerated() {
            let pose = BoatPose(boat, ease: world.ease(ofSeat: i), isGhost: world.isGhost(ofSeat: i),
                                boatClass: world.boatClass, style: boatStyle)
            boatNodes[i].update(with: boat, pose: pose, style: boatStyle, time: world.time, dt: dt, settled: settled)
        }

        syncCamera()
        rig.advance(CameraWorld(world), sceneSize: size, dt: dt, settled: settled)
        cam.position = rig.center
        cam.setScale(rig.cameraScale)
        cam.zRotation = rig.cameraRotation

        let view = WaterView(center: cam.position, sceneSize: size, scale: cam.xScale, rotation: cam.zRotation)
        Signpost.waterUpdate.measure { water.update(WaterWorld(world), view: view, dt: dt) }

        // Before the gun the line is where you're going: the active leg's orange.
        startLine.strokeColor = world.time < 0
            ? CuePalette.orange.uiColor.withAlphaComponent(0.9)
            : UIColor.white.withAlphaComponent(0.4)

        laylineCountdown -= dt
        if laylineCountdown <= 0 {
            laylineCountdown = 0.25
            updateLaylines(world)
        }
    }

    /// The north-up course camera over `course` in a scene of `sceneSize` (`CameraRig.courseFraming`): centred on
    /// the course, scaled to show the whole of it (marks, pin and committee boat) with a margin, and never closer
    /// than `zoom`.
    static func courseFraming(_ course: CourseLayout, sceneSize: CGSize, zoom: CGFloat,
                              margin: CGFloat = CGFloat(CameraStyle.standard.courseMargin)) -> (center: CGPoint, scale: CGFloat)? {
        CameraRig.courseFraming(course.obstacles.map(\.position), sceneSize: sceneSize, zoom: zoom, margin: margin,
                                pointsPerMeter: Double(pointsPerMeter))
    }

    /// Your laylines, from the formula a bot sees them by (`Laylines`, `SeatView.laylines`).
    private func updateLaylines(_ world: RenderWorld) {
        let player = world.me
        let course = world.course
        let leg = course.legSailed(status: player.status, legIndex: player.legIndex)
        guard let lines = Laylines(for: leg, in: course, polar: world.boatClass.polar, wind: world.groundWind(at:)) else {
            laylines.path = nil
            return
        }
        let path = CGMutablePath()
        for heading in [lines.starboardHeading, lines.portHeading] {
            // The layline is the track that arrives at the mark on this heading.
            path.move(to: point(lines.mark))
            path.addLine(to: point(lines.mark - Vec2.heading(heading) * 350))
        }
        laylines.path = path.copy(dashingWithPhase: 0, lengths: [10, 10])
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

    /// Hands the tiller's track and knob to the session for `RaceView` to draw, when they move.
    private func publishTillerKnob() {
        guard let session, session.tillerKnob != steering.tillerKnob else { return }
        session.tillerKnob = steering.tillerKnob
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        syncScheme()
        for touch in touches {
            steering.touchBegan(ObjectIdentifier(touch), at: touch.location(in: view), midX: view.bounds.midX)
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
