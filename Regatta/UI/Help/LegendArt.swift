import RegattaBots
import RegattaCore
import SpriteKit
import UIKit

/// Each legend item's picture (#135, #23: "drawn with the real renderer, so the tutorial can reuse it"): a frozen
/// `GameScene` over a posed moment of a real practice race (`LegendDriver`), framed by the north-up follow camera on
/// your boat and drawn once off screen. Nothing here is a lookalike: the water, boats, wakes, wind shadows, cues, marks and
/// rule cues are the race's own nodes. Each picture is drawn the first time it's asked for, then kept.
@MainActor enum LegendArt {
    /// A picture's size in points.
    static let size = CGSize(width: 104, height: 72)

    private static var cache: [LegendItem: UIImage] = [:]

    /// `item`'s picture if it has been drawn.
    static func cached(_ item: LegendItem) -> UIImage? { cache[item] }

    /// `item`'s picture, or nil if it can't be drawn.
    static func image(for item: LegendItem) -> UIImage? {
        if let image = cache[item] { return image }
        guard let scene = scene(for: item) else { return nil }
        let view = SKView(frame: CGRect(origin: .zero, size: size))
        view.presentScene(scene)
        // A frozen driver draws its settled world on every update.
        scene.update(0)
        guard let camera = scene.camera else { return nil }
        // The world the camera shows, drawn at the camera's scale: line widths are screen points at any zoom.
        let scale = camera.xScale
        let crop = CGRect(x: camera.position.x - size.width * scale / 2, y: camera.position.y - size.height * scale / 2,
                          width: size.width * scale, height: size.height * scale)
        guard let texture = view.texture(from: scene, crop: crop) else { return nil }
        // The texture comes out upside down, and as large as the world it covers: kept at the picture's own size.
        let drawn = UIImage(cgImage: texture.cgImage(), scale: 1, orientation: .downMirrored)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn.draw(in: CGRect(origin: .zero, size: size))
        }
        cache[item] = image
        return image
    }

    /// The race scene `item` is drawn from, sized to the picture; nil if the race can't be set up.
    static func scene(for item: LegendItem) -> GameScene? {
        guard let stage = LegendStage.shared else { return nil }
        let shot = stage.shot(for: item)
        let driver = LegendDriver(stage: stage, shot: shot)
        let scene = GameScene(driver: driver, roster: stage.roster)
        scene.size = size
        var camera = CameraStyle.standard
        camera.defaultZoom = shot.zoom
        camera.lookAheadSeconds = shot.lookAheadSeconds
        scene.cameraStyle = camera
        scene.cameraOverride = .northUpFollow
        scene.cueOverride = (laylines: shot.laylines, ladderLines: shot.ladderLines)
        scene.showsRuleCues = shot.ruleCues
        for call in shot.calls { scene.ruleCalls.add(call) }
        return scene
    }
}

/// One posed moment: the boats (yours first), what the cues show, and the camera's zoom and lead.
struct LegendShot {
    var boats: [Boat]
    var zoom = 1.0
    /// Seconds of your velocity the camera centres ahead of you; negative centres astern, on the wake.
    var lookAheadSeconds = 0.0
    var laylines = false
    var ladderLines = false
    var ruleCues = false
    var keepClear: [RightOfWay?]? = nil
    var owed: [OwedPenalty?]? = nil
    var calls: [RuleCall] = []
}

/// The practice race every legend picture is posed in: the default practice venue and its first conditions, three
/// seats, at its first tick. Built once.
@MainActor final class LegendStage {
    static let shared: LegendStage? = try? LegendStage()

    let race: Race
    let roster: FleetRoster
    let venue: Venue
    /// Open water halfway up the first beat, clear of the marks and the line.
    let openWater: Vec2

    init() throws {
        var config = RaceConfig(opponents: 2, seed: 135, windSeed: RaceConfig.windSeed(pinnedTo: 135))
        if let venue = PracticeVenue.all.first, let conditions = venue.conditions.first {
            config.files.venue = venue.ref
            config.files.conditions = conditions.ref
        }
        let setup = config.setup
        let files = try RaceFiles(resolving: setup)
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: WindSeed(config.windSeed)))
        // On to the first moment with a well-grown puff and lull on the water, for theirs.
        func grown(_ lull: Bool) -> Bool {
            race.wind.activePuffs(atTick: race.tick).contains { lull ? $0.intensity < -Self.grown : $0.intensity > Self.grown }
        }
        while !(grown(false) && grown(true)), race.tick < Self.latestTick { race.step() }
        self.race = race
        roster = FleetRoster(setup: setup)
        venue = files.venue.content
        let line = race.course.startLine
        let start = (line.pin.position + line.committee.position) * 0.5
        openWater = (start + race.course.elements[CourseLayout.windwardIndex].marks[0].position) * 0.5
    }

    /// The puff or lull strength its picture waits for, and the latest tick it waits to.
    private static let grown = 0.12
    private static let latestTick = 0

    var boatClass: BoatClass { race.boatClass }
    var windwardMark: Vec2 { race.course.elements[CourseLayout.windwardIndex].marks[0].position }

    /// The ground wind at `p`, or the race's mean wind where it holds no key.
    func wind(at p: Vec2) -> GroundWind {
        (try? race.wind.sample(p, tick: race.tick))
            ?? GroundWind(direction: race.wind.setup.meanDirection, speed: metresPerSecond(knots: 12))
    }

    /// A boat of `seat` at `p` sailing `sailingAngle` off the wind there with her boom to `boom`, at `speedShare` of
    /// her polar speed, racing on the first leg; `autohelm` holds a target for her vane's tick and arc.
    func boat(seat: Int, at p: Vec2, sailingAngle: Double, boom: BoomSide = .port, speedShare: Double = 1,
              autohelm: Autohelm.Target? = nil) -> Boat {
        let ground = wind(at: p)
        let side: Double = boom == .port ? 1 : -1
        let heading = wrapAngle(ground.direction - side * sailingAngle)
        let speed = boatClass.polar.speed(twa: abs(sailingAngle), tws: ground.speed) * speedShare
        var boat = Boat(id: seat, isPlayer: seat == 0, colorIndex: seat, position: p, heading: heading, speed: speed,
                        boomSide: boom)
        boat.status = .racing
        let winds = BoatWinds.resolve(ground: Wind(ground), current: .zero, velocityThroughWater: boat.velocity)
        boat.windOverGround = winds.overGround
        boat.sailingWind = winds.sailing
        boat.apparentWind = winds.apparent
        boat.averagedWindSpeed = boat.polarWindSpeed(in: boatClass)
        boat.autohelm = autohelm.map { Autohelm(target: $0) }
        return boat
    }

    /// How long, seconds, the posed boats are taken to have sailed straight to where they are (`settledWake`): longer
    /// than a ribbon point lives, so their wakes are whole.
    private static let wakeSeconds = 12.0

    /// The wind shadow `boats` would have left had each sailed straight at her speed, sail working, for `wakeSeconds`
    /// to where she is (#377): the sim's own ribbons (`TurbulenceRibbons`), stepped a tick at a time over that run, so a
    /// picture shows them as a race draws them.
    func settledWake(_ boats: [Boat]) -> TurbulenceRibbons {
        var wake = TurbulenceRibbons(shadow: boatClass.windShadow)
        let scales = boats.map { SailTrim.standard.workingScale(of: $0, ease: false, boatClass: boatClass) }
        let ticks = Int(Self.wakeSeconds * Double(Race.tickRate))
        for back in stride(from: ticks, through: 0, by: -1) {
            let moved = boats.map { boat in
                var boat = boat
                boat.position -= boat.velocity * (Double(back) * Race.dt)
                return boat
            }
            wake.step(boats: moved, tick: race.tick - back, scales: scales)
        }
        return wake
    }

    /// The upwind groove's sailing angle at `p`.
    func upwindGroove(at p: Vec2) -> Double {
        Autohelm.grooveAngle(.upwind, tws: wind(at: p).speed, boatClass: boatClass)
    }

    /// A boat `hulls` hull lengths from `p` along compass bearing `bearing`.
    func offset(_ p: Vec2, hulls: Double, bearing: Double) -> Vec2 {
        p + Vec2.heading(bearing) * (hulls * boatClass.hull.length)
    }

    /// The puff (`lull` false) or lull with the strongest intensity alive at the race's tick, if any.
    func strongest(lull: Bool) -> Puff? {
        race.wind.activePuffs(atTick: race.tick)
            .filter { lull ? $0.intensity < 0 : $0.intensity > 0 }
            .max { abs($0.intensity) < abs($1.intensity) }
    }

    /// `item`'s moment. The camera sits on your boat (no lead, except astern on the wake) at a zoom no closer than
    /// 1, so the picture is drawn at the screen's resolution or better.
    func shot(for item: LegendItem) -> LegendShot {
        let p = openWater
        let groove = upwindGroove(at: p)
        let windDirection = wind(at: p).direction
        let mine = { (at: Vec2) in self.boat(seat: 0, at: at, sailingAngle: groove) }
        switch item {
        case .vane:
            return LegendShot(boats: [boat(seat: 0, at: p, sailingAngle: groove, autohelm: .groove(.upwind))])
        case .pinchFoot:
            let pinch = groove - deg2rad(12)
            return LegendShot(boats: [boat(seat: 0, at: p, sailingAngle: pinch, autohelm: .angle(pinch))])
        case .wake:
            return LegendShot(boats: [boat(seat: 0, at: p, sailingAngle: deg2rad(100))], zoom: 0.6, lookAheadSeconds: -0.6)
        case .puff, .lull:
            // On the edge of the strongest one, so the picture shows its tone against the water beside it.
            guard let puff = strongest(lull: item == .lull) else { return LegendShot(boats: [mine(p)]) }
            let edge = puff.center + Vec2.heading(windDirection + .pi / 2) * (puff.radius * 0.55)
            return LegendShot(boats: [mine(edge)], zoom: 0.16)
        case .windShadow:
            // She sails just to windward, her shadow falling back over you.
            let her = offset(p, hulls: 1.5, bearing: windDirection - .pi / 6)
            return LegendShot(boats: [mine(p), boat(seat: 1, at: her, sailingAngle: groove)], zoom: 0.4)
        case .layline:
            // On the starboard layline to the windward mark.
            let lines = LaylineCue.segments(for: race.course.legSailed(status: .racing, legIndex: 0), in: race.course,
                                            polar: boatClass.polar, wind: { self.wind(at: $0) })
            let on = lines.first.map { $0.from + ($0.to - $0.from) * 0.3 } ?? p
            return LegendShot(boats: [mine(on)], zoom: 0.4, laylines: true)
        case .ladderLine:
            // On the ladder line nearest open water.
            let (along, anchor) = LadderCue.step(for: race.course.legSailed(status: .racing, legIndex: 0), in: race.course)
            let spacing = BoatStyle.standard.ladderSpacingMetres
            let level = (p - anchor).dot(along)
            let on = p + along * ((level / spacing).rounded() * spacing - level)
            return LegendShot(boats: [mine(on)], zoom: 0.4, ladderLines: true)
        case .keepClear, .keepsClearOfYou:
            // You on port and she on starboard (rule 10), or the other way round.
            let youOnPort = item == .keepClear
            let her = offset(p, hulls: 1.5, bearing: windDirection + .pi / 2)
            let you = boat(seat: 0, at: p, sailingAngle: groove, boom: youOnPort ? .starboard : .port)
            let other = boat(seat: 1, at: her, sailingAngle: groove, boom: youOnPort ? .port : .starboard)
            let relation = RightOfWay(keepClear: youOnPort ? 0 : 1, rule: .portStarboard)
            return LegendShot(boats: [you, other], zoom: 0.5, ruleCues: true, keepClear: [nil, relation])
        case .nextMark:
            let near = windwardMark - race.course.upwind * (race.course.zoneRadius * 0.45)
            return LegendShot(boats: [mine(near)], zoom: 0.28)
        case .otherMark:
            let grey = ChartMarks.buoys(of: race.course)
                .first { !ChartMarks.isActive($0.mark, in: race.course, status: .racing, legIndex: 0) }
            let mark = grey?.mark.position ?? p
            return LegendShot(boats: [mine(mark + race.course.upwind.rightPerp * (boatClass.hull.length * 1.2))], zoom: 0.5)
        case .ruleCall:
            let her = offset(p, hulls: 1.8, bearing: windDirection + .pi / 2)
            let call = RuleCall(incidentId: 1, tick: race.tick, rule: .portStarboard, offender: 1, victim: 0, leg: 0,
                                turnsOwed: 1, startDeadlineTick: nil, completeDeadlineTick: nil)
            return LegendShot(boats: [mine(p), boat(seat: 1, at: her, sailingAngle: groove, boom: .starboard)],
                              zoom: 0.5, ruleCues: true, calls: [call])
        case .penaltyArc:
            let penalty = race.rules.raceFormat.penalty
            let ticks = Double(Race.tickRate)
            let owed = OwedPenalty(turnsOwed: 1, startDeadlineTick: race.tick + Int(penalty.start * 0.7 * ticks),
                                   completeDeadlineTick: race.tick + Int(penalty.complete * ticks), progress: 0,
                                   isStarted: false)
            return LegendShot(boats: [mine(p)], zoom: 0.9, ruleCues: true, owed: [owed])
        }
    }
}

/// A legend shot as a frozen race (`RaceDriver`): the scene draws its one world settled, nothing steps, input is
/// ignored. Like a render fixture's `FixtureDriver`, but posed rather than replayed.
final class LegendDriver: RaceDriver {
    let myBoatIndex = 0
    let course: CourseLayout
    let venue: Venue
    let boatClass: BoatClass
    let isPausable = false
    let isFrozen = true
    let currentFrame: TickFrame
    var previousFrame: TickFrame { currentFrame }
    let alpha = 1.0

    @MainActor init(stage: LegendStage, shot: LegendShot) {
        let race = stage.race
        course = race.course
        venue = stage.venue
        boatClass = race.boatClass
        let count = shot.boats.count
        currentFrame = TickFrame(tick: race.tick, boats: shot.boats, standings: Array(0..<count), wind: race.wind,
                                 isOver: false, keepClear: shot.keepClear,
                                 owed: shot.owed.map { $0 + Array(repeating: nil, count: max(0, count - $0.count)) },
                                 penalty: race.rules.raceFormat.penalty, wake: stage.settledWake(shot.boats))
    }

    func tick(_ dt: Double) -> [TickFrame] { [] }
    func submit(_ input: BoatInput) {}
    func tap(_ tap: BoatTap) -> Bool { false }
    func drainEvents() -> [RaceEvent] { [] }
}
