import SpriteKit
import RegattaCore

/// Renders the race and turns touches into rudder input. The simulation advances
/// at a fixed 30 Hz (`Race.tickRate`) regardless of display refresh rate.
final class GameScene: SKScene {
    static let pointsPerMeter: CGFloat = 8

    let race: Race
    /// Simulated seconds per real second (`-timescale`).
    let timescale: Double
    weak var session: GameSession?

    private let world = SKNode()
    private let cam = SKCameraNode()
    private let water = WaterNode()
    private let effectsLayer = SKNode()
    private let courseLayer = SKNode()
    private let boatLayer = SKNode()
    private let laylines = SKShapeNode()
    private let startLine = SKShapeNode()
    private let puffTexture = GameScene.makePuffTexture()
    private var boatNodes: [BoatNode] = []
    private var puffNodes: [SKSpriteNode] = []

    // Stopgap fixed-step loop; #61 replaces it.
    private let fixedStep = Race.dt
    private var accumulator = 0.0
    private var lastUpdate: TimeInterval?
    private var hudCountdown = 0.0
    private var laylineCountdown = 0.0
    private var zoom: CGFloat = 0.8

    private var portTouches = Set<UITouch>()
    private var starboardTouches = Set<UITouch>()
    private var rudderInput = 0.0

    init(race: Race, timescale: Double = 1) {
        self.race = race
        self.timescale = timescale
        super.init(size: CGSize(width: 390, height: 844))
        race.botBrainsInterval = { Signpost.botBrains.measure($0) }
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backgroundColor = Palette.water
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
        addChild(world)

        addChild(cam)
        camera = cam
        cam.setScale(1 / zoom)
        cam.position = point(race.player.position)

        laylines.strokeColor = UIColor.white.withAlphaComponent(0.22)
        laylines.lineWidth = 1

        buildCourse()
        buildBoats()
    }

    private func buildCourse() {
        let course = race.course

        for mark in course.marks {
            let zone = SKShapeNode(circleOfRadius: CGFloat(course.zoneRadius) * ppm)
            zone.path = zone.path?.copy(dashingWithPhase: 0, lengths: [6, 6])
            zone.strokeColor = UIColor.white.withAlphaComponent(0.18)
            zone.lineWidth = 1
            zone.position = point(mark.position)
            courseLayer.addChild(zone)
            courseLayer.addChild(buoy(at: mark.position, radius: mark.radius, color: Palette.mark))
        }

        courseLayer.addChild(buoy(at: course.pin, radius: course.pinRadius, color: Palette.startLine))

        let committee = SKShapeNode(ellipseOf: CGSize(width: 4.6 * ppm, height: 5.2 * ppm))
        committee.fillColor = UIColor(white: 0.95, alpha: 1)
        committee.strokeColor = UIColor(white: 0.55, alpha: 1)
        committee.lineWidth = 1.5
        committee.position = point(course.committee)
        let flag = SKShapeNode(rect: CGRect(x: -3, y: -3, width: 10, height: 7))
        flag.fillColor = Palette.mark
        flag.lineWidth = 0
        committee.addChild(flag)
        courseLayer.addChild(committee)

        let line = CGMutablePath()
        line.move(to: point(course.pin))
        line.addLine(to: point(course.committee))
        startLine.path = line.copy(dashingWithPhase: 0, lengths: [8, 6])
        startLine.lineWidth = 2
        courseLayer.addChild(startLine)
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
        for boat in race.boats {
            let node = BoatNode(boat: boat, color: Palette.boat(boat.colorIndex), pointsPerMeter: ppm)
            boatNodes.append(node)
            boatLayer.addChild(node)
            effectsLayer.addChild(node.shadowCone)
            effectsLayer.addChild(node.wake)
        }
    }

    // MARK: - Loop

    override func update(_ currentTime: TimeInterval) {
        let frameTime = min(currentTime - (lastUpdate ?? currentTime), 0.1)
        lastUpdate = currentTime
        guard let session, !session.isPaused else { return }

        updateRudder(frameTime)
        race.setPlayerRudder(rudderInput)
        advanceSimulation(by: frameTime)

        Signpost.renderUpdate.measure { render(frameTime * timescale) }
        session.consume(race.drainEvents())

        hudCountdown -= frameTime
        if hudCountdown <= 0 {
            hudCountdown = 1.0 / 15
            Signpost.hudRefresh.measure { session.refreshHUD() }
        }
    }

    /// Runs the fixed ticks that `frameTime` seconds of real time cover at `timescale`.
    func advanceSimulation(by frameTime: Double) {
        accumulator += frameTime * timescale
        while accumulator >= fixedStep {
            Signpost.simStep.measure { race.step() }
            accumulator -= fixedStep
        }
    }

    private func render(_ dt: Double) {
        for (i, boat) in race.boats.enumerated() {
            boatNodes[i].update(with: boat, time: race.time, dt: dt)
        }

        let player = race.player
        let target = point(player.position + player.velocity * 2)
        let k = CGFloat(1 - exp(-dt * 3))
        cam.position = CGPoint(x: cam.position.x + (target.x - cam.position.x) * k,
                               y: cam.position.y + (target.y - cam.position.y) * k)

        water.update(center: cam.position, windDirection: race.wind.direction(at: player.position))
        updatePuffs()

        startLine.strokeColor = race.time < 0
            ? Palette.startLine.withAlphaComponent(0.9)
            : UIColor.white.withAlphaComponent(0.4)

        laylineCountdown -= dt
        if laylineCountdown <= 0 {
            laylineCountdown = 0.25
            updateLaylines()
        }
    }

    private func updatePuffs() {
        let puffs = race.wind.puffs
        while puffNodes.count < puffs.count {
            let node = SKSpriteNode(texture: puffTexture)
            node.colorBlendFactor = 1
            node.zPosition = -1
            effectsLayer.addChild(node)
            puffNodes.append(node)
        }
        for (i, node) in puffNodes.enumerated() {
            guard i < puffs.count else {
                node.isHidden = true
                continue
            }
            let puff = puffs[i]
            let intensity = puff.intensity
            node.isHidden = false
            node.position = point(puff.center)
            let diameter = CGFloat(puff.radius * 2) * ppm
            node.size = CGSize(width: diameter, height: diameter)
            node.color = intensity >= 0 ? Palette.gust : .white
            node.alpha = CGFloat(min(abs(intensity) * (intensity >= 0 ? 2.2 : 1.0), 0.55))
        }
    }

    private func updateLaylines() {
        let player = race.player
        let course = race.course
        let leg = player.status == .racing ? course.legs[player.legIndex] : (player.isOnCourse ? course.legs[0] : .finish)
        guard case .round(let index) = leg else {
            laylines.path = nil
            return
        }
        let mark = course.marks[index]
        let w = race.wind.direction(at: mark.position)
        let angle = mark.kind == .windward ? race.polar.upwindTWA : race.polar.downwindTWA
        let path = CGMutablePath()
        for heading in [w - angle, w + angle] {
            // The layline is the track that arrives at the mark on this heading.
            path.move(to: point(mark.position))
            path.addLine(to: point(mark.position - Vec2.heading(heading) * 350))
        }
        laylines.path = path.copy(dashingWithPhase: 0, lengths: [10, 10])
    }

    // MARK: - Input

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

    // MARK: - Textures

    private static func makePuffTexture() -> SKTexture {
        let size = CGSize(width: 128, height: 128)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: 64, y: 64)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 64, options: [])
        }
        return SKTexture(image: image)
    }
}
