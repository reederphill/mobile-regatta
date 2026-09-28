import SpriteKit
import RegattaBots
import RegattaCore

/// Renders the race and turns touches into rudder input. The driver runs the simulation at a fixed
/// 30 Hz (`Race.tickRate`) whatever the display's refresh rate, and the scene draws between its last
/// two ticks (`RenderWorld`). The scene never holds a `Race`.
final class GameScene: SKScene {
    static let pointsPerMeter: CGFloat = 8
    /// The boat camera's zoom until you pinch, unless the tuning panel (#232) sets another.
    static let defaultZoom = CGFloat(CameraStyle.standard.defaultZoom)

    let driver: any RaceDriver
    let roster: FleetRoster
    weak var session: GameSession?
    /// Follow your boat, or frame the whole course. Render fixtures set it (#62); the device setting is #113.
    var cameraMode: LaunchOptions.CameraMode = .boat
    /// The water's look: the debug tuning panel's (#232) seam, live, even on a paused race.
    var waterStyle: WaterStyle {
        get { water.style }
        set {
            water.style = newValue
            needsPausedRender = true
        }
    }
    /// The camera's framing: the debug tuning panel's (#232) seam, live, even on a paused race. A new default zoom
    /// replaces your pinch.
    var cameraStyle = CameraStyle.standard {
        didSet {
            if cameraStyle.defaultZoom != oldValue.defaultZoom {
                zoom = CGFloat(cameraStyle.defaultZoom)
                cam.setScale(1 / zoom)
            }
            needsPausedRender = true
        }
    }
    /// The water's tier: the thermal ladder's (#127) seam. Puff shading and the edge tint draw in every tier.
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
    private var hudCountdown = 0.0
    private var laylineCountdown = 0.0
    private var zoom = GameScene.defaultZoom
    /// A render-only value changed while the race is paused: draw the standing world once more with it.
    private var needsPausedRender = false

    private var portTouches = Set<UITouch>()
    private var starboardTouches = Set<UITouch>()
    private var rudderInput = 0.0

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
        // The upwind edge tint sits at the view's edges, over the water and under everything else.
        water.edgeTint.zPosition = -5
        water.edgeTint.name = "edge tint"
        cam.addChild(water.edgeTint)
        cam.setScale(1 / zoom)
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
            let node = BoatNode(boat: boat, name: roster.label(of: boat.id, playerSeat: me), isMine: boat.id == me,
                                color: Palette.boat(boat.colorIndex), boatClass: driver.boatClass, pointsPerMeter: ppm)
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

        updateRudder(frameTime)
        // The driver latches it for the next tick. With `-demo` a bot sails your seat and ignores it.
        driver.submit(heldInput)
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
            boatNodes[i].update(with: boat, time: world.time, dt: dt, settled: settled)
        }

        let player = world.me
        switch cameraMode {
        case .boat:
            let target = point(player.position + player.velocity * cameraStyle.lookAheadSeconds)
            let k = settled ? 1 : CGFloat(1 - exp(-dt * cameraStyle.followRate))
            cam.position = CGPoint(x: cam.position.x + (target.x - cam.position.x) * k,
                                   y: cam.position.y + (target.y - cam.position.y) * k)
        case .course:
            frameCourse(world.course)
        }

        let view = WaterView(center: cam.position, sceneSize: size, scale: cam.xScale)
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

    /// Puts the whole course, marks, pin and committee boat, in view with a margin.
    private func frameCourse(_ course: CourseLayout) {
        guard let framing = Self.courseFraming(course, sceneSize: size, zoom: zoom, margin: CGFloat(cameraStyle.courseMargin))
        else { return }
        cam.position = framing.center
        cam.setScale(framing.scale)
    }

    /// The course camera over `course` in a scene of `sceneSize`: centred on the course, scaled to show the whole
    /// of it (marks, pin and committee boat) with a margin, and never closer than `zoom`.
    static func courseFraming(_ course: CourseLayout, sceneSize: CGSize, zoom: CGFloat,
                              margin: CGFloat = CGFloat(CameraStyle.standard.courseMargin)) -> (center: CGPoint, scale: CGFloat)? {
        let points = course.obstacles.map(\.position)
        let xs = points.map { CGFloat($0.x) * pointsPerMeter }, ys = points.map { CGFloat($0.y) * pointsPerMeter }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              sceneSize.width > 0, sceneSize.height > 0 else { return nil }
        return (CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                max((maxX - minX) / sceneSize.width, (maxY - minY) / sceneSize.height, 1 / zoom) * margin)
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

    /// What the seat holds this frame: the rudder from the touches, and Ease from the button.
    var heldInput: BoatInput { BoatInput(rudder: rudderInput, ease: session?.isEasing ?? false) }

    private func updateRudder(_ dt: Double) {
        let target = (starboardTouches.isEmpty ? 0.0 : 1.0) - (portTouches.isEmpty ? 0.0 : 1.0)
        if target == 0 {
            rudderInput = 0
        } else {
            let maxChange = 3.5 * dt
            rudderInput += (target - rudderInput).clamped(to: -maxChange...maxChange)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        for touch in touches {
            if touch.location(in: view).x < view.bounds.midX {
                portTouches.insert(touch)
            } else {
                starboardTouches.insert(touch)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            portTouches.remove(touch)
            starboardTouches.remove(touch)
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        zoom = (zoom * gesture.scale).clamped(to: 0.45...2.2)
        gesture.scale = 1
        cam.setScale(1 / zoom)
    }

    /// Clears held touches, e.g. when an overlay steals them.
    func resetInput() {
        portTouches.removeAll()
        starboardTouches.removeAll()
        rudderInput = 0
        lastUpdate = nil
    }
}
