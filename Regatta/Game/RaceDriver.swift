import RegattaCore

/// Runs a race for the app at the fixed 30 Hz tick (#18, #61) and hands the scene and HUD what to draw.
/// The scene never touches a `Race`: it reads `renderWorld` and sends input through `submit` and `tap`.
///
/// `PracticeDriver` sails an offline practice race on the device, bots included (#16, #19). `OnlineDriver`
/// (#68) wraps the client's `PredictedRace` (#64) behind the same protocol, easing its corrections with
/// `VisualCorrection`, and isn't pausable.
protocol RaceDriver: AnyObject {
    /// Your seat. Every "you" in the scene, HUD and results reads it, never seat 0.
    var myBoatIndex: Int { get }
    var course: CourseLayout { get }
    /// The venue the race is sailed at: its land, landmarks and depths, for the chart (#115).
    var venue: Venue { get }
    var boatClass: BoatClass { get }
    /// Whether the race can stop while you pause: a practice race can, an online one can't.
    var isPausable: Bool { get }

    /// The last tick simulated, and the one before it: the renderer draws between them.
    var currentFrame: TickFrame { get }
    var previousFrame: TickFrame { get }
    /// How far the clock has run past `currentFrame`'s tick, 0…1 of a tick. The renderer draws that far
    /// from `previousFrame` to `currentFrame`: one tick behind the simulation, never ahead of it.
    var alpha: Double { get }

    /// Runs the fixed ticks that `dt` seconds of real time cover, and returns their frames in order
    /// (none if `dt` doesn't reach the next tick).
    @discardableResult func tick(_ dt: Double) -> [TickFrame]
    /// `tick(dt)`, but it stops starting ticks once `budget` of wall-clock time has gone, so a frame
    /// always leaves the main thread time to draw and answer (a fast `-timescale` in a slow simulator
    /// saturated it in the iOS 27 CI run). The ticks it doesn't run are dropped, not owed: the race
    /// falls behind real time instead of catching up, and runs the same ticks in the same order, only
    /// later. Nil runs them all.
    @discardableResult func tick(_ dt: Double, within budget: Duration?) -> [TickFrame]

    /// Your held input. Call it as often as you like: the driver latches the latest value and applies
    /// it once per tick, from the next tick. Ignored while a bot sails your seat (`-demo`).
    func submit(_ input: BoatInput)
    /// Applies `tap` for your seat at the next tick. Returns false if it can't: a bot sails your seat,
    /// or the race is over.
    @discardableResult func tap(_ tap: BoatTap) -> Bool

    /// The race events to show since the last call, oldest first. Online these are the server's only (#68).
    func drainEvents() -> [RaceEvent]

    /// The world to draw this display frame.
    var renderWorld: RenderWorld { get }

    /// Whether the race stands still at one tick for a render fixture (`FixtureDriver`, #62): the scene
    /// draws it settled, with no easing or animation, and hides the controls (and the HUD, unless the
    /// fixture asks for it, #114).
    var isFrozen: Bool { get }

    /// The round trip to the server has stayed over 250 ms for about 5 s (#18, #68): the HUD's warning (#124).
    var lagWarning: Bool { get }

    /// Each seat's livery (#21, #119): presentation only, never the simulation's.
    var liveries: FleetLiveries { get }

    /// The race's incident index (#94), for the results' Your race card (#132): a practice race's own. Nil where the
    /// device holds none: online, the server's stream carries it (#133); a render fixture.
    var incidents: IncidentIndex? { get }
}

extension RaceDriver {
    var isFrozen: Bool { false }
    /// The RTT warning (#18, #68): only an online race (`OnlineDriver.lagWarning`) has one.
    var lagWarning: Bool { false }
    /// A driver with no fleet liveries draws every seat in `FleetLiveries.yours`.
    var liveries: FleetLiveries { FleetLiveries(liveries: []) }
    var incidents: IncidentIndex? { nil }

    /// A driver that keeps real time (online) or runs no ticks (a fixture) runs them all.
    @discardableResult func tick(_ dt: Double, within budget: Duration?) -> [TickFrame] { tick(dt) }

    /// Interpolates the fleet from `previousFrame` to `currentFrame` by `alpha`.
    var renderWorld: RenderWorld {
        RenderWorld(course: course, boatClass: boatClass, myBoatIndex: myBoatIndex,
                    previous: previousFrame, current: currentFrame, alpha: alpha)
    }
}

/// One simulated tick as the app sees it: the whole fleet after the tick, and the wind that sailed it.
struct TickFrame {
    let tick: Int
    let boats: [Boat]
    /// Seats from first to last.
    let standings: [Int]
    /// The keyed wind as the race held it at `tick` (ADR 0001).
    let wind: WindField
    let isOver: Bool
    /// Each seat's held input at `tick` (`Race.heldInputs`): its ease is what the boat's pose draws from (#117).
    /// Every client holds every seat's (ADR 0005).
    let heldInputs: [BoatInput]
    /// The tick the race closes on once a boat has finished (`Race.closeTick`: the earlier of the finish window's
    /// end and the time limit), nil while nobody has: the HUD's yellow countdown (#30, #114). Read from the race,
    /// never worked out here. Online it is the prediction's, so it appears once the server has told it of a finish.
    let closeTick: Int?
    /// Each seat's gap to the leader in ladder metres (`Race.gapsToLeader()`, #267, #268), by seat, nil where the race
    /// gives none: the live leaderboard's. Read from the race once per tick, never worked out here. Online it is the
    /// prediction's (#64).
    let gaps: [Double?]
    /// Who must keep clear between the viewing seat and each other seat (`Race.keepClearRelations(of:)`, #123), by
    /// seat: the right-of-way glows. Nil hides them: online until the server sends its own (#96, ADR 0005), never
    /// worked out from the client's world.
    let keepClear: [RightOfWay?]?
    /// Each seat's owed penalty (`Race.owedPenalty(ofSeat:)`), by seat: the penalty arc and Turn notice (#123).
    /// Online it is the prediction's, which holds the server's penalty state.
    let owed: [OwedPenalty?]
    /// The rules' penalty windows (`raceFormat.penalty`): the arc's and notice's deadlines, never literals.
    let penalty: RulesConfig.Penalty?

    /// Race clock in seconds.
    var time: Double { Double(tick) / Double(Race.tickRate) }

    /// `race` after its tick, with the right-of-way glows `keepClearOf` that seat sees (none when nil).
    init(race: Race, keepClearOf seat: Int? = nil) {
        self.init(race: race, isOver: race.isOver, keepClearOf: seat)
    }

    /// `race` after its tick, over when `isOver` says: online, the server decides that, not the
    /// prediction (#68).
    init(race: Race, isOver: Bool, keepClearOf seat: Int? = nil) {
        tick = race.tick
        boats = race.boats
        standings = race.standings()
        wind = race.wind
        self.isOver = isOver
        heldInputs = race.heldInputs
        closeTick = race.firstFinishTime != nil ? race.closeTick : nil
        gaps = race.gapsToLeader()
        keepClear = seat.map { race.keepClearRelations(of: $0) }
        owed = race.boats.indices.map { race.owedPenalty(ofSeat: $0) }
        penalty = race.rules.raceFormat.penalty
    }

    /// `heldInputs` nil holds every seat neutral; `gaps` nil gives every seat none.
    init(tick: Int, boats: [Boat], standings: [Int], wind: WindField, isOver: Bool, heldInputs: [BoatInput]? = nil,
         closeTick: Int? = nil, gaps: [Double?]? = nil, keepClear: [RightOfWay?]? = nil, owed: [OwedPenalty?]? = nil,
         penalty: RulesConfig.Penalty? = nil) {
        self.tick = tick
        self.boats = boats
        self.standings = standings
        self.wind = wind
        self.isOver = isOver
        self.heldInputs = heldInputs ?? Array(repeating: .neutral, count: boats.count)
        self.closeTick = closeTick
        self.gaps = gaps ?? Array(repeating: nil, count: boats.count)
        self.keepClear = keepClear
        self.owed = owed ?? Array(repeating: nil, count: boats.count)
        self.penalty = penalty
    }

    /// This frame a tick earlier, each boat moved back along its velocity: what the renderer draws from
    /// when the tick before isn't on the same track, after a correction or a jump of more than a tick (#68).
    func extrapolatedBackOneTick() -> TickFrame {
        let moved = boats.map { boat in
            var boat = boat
            boat.position -= boat.velocity * Race.dt
            return boat
        }
        return TickFrame(tick: tick - 1, boats: moved, standings: standings, wind: wind, isOver: isOver, heldInputs: heldInputs,
                         closeTick: closeTick, gaps: gaps, keepClear: keepClear, owed: owed, penalty: penalty)
    }

    /// Where `seat` stands in the fleet, from 1.
    func place(of seat: Int) -> Int {
        (standings.firstIndex(of: seat) ?? 0) + 1
    }
}

/// What the scene draws for one display frame: the fleet between the last two ticks, and everything
/// else from the latest. Read-only: nothing here can change the race.
struct RenderWorld {
    let course: CourseLayout
    let boatClass: BoatClass
    let myBoatIndex: Int
    /// The latest tick: statuses, standings, wind and puffs come from it.
    let frame: TickFrame
    /// Each boat's position, heading and wind interpolated from the previous tick to `frame`.
    private(set) var boats: [Boat]
    /// Race clock in seconds, between the two ticks.
    let time: Double

    init(course: CourseLayout, boatClass: BoatClass, myBoatIndex: Int, previous: TickFrame, current: TickFrame, alpha: Double) {
        self.course = course
        self.boatClass = boatClass
        self.myBoatIndex = myBoatIndex
        frame = current
        let t = alpha.clamped(to: 0...1)
        if previous.boats.count == current.boats.count {
            boats = zip(previous.boats, current.boats).map { Interpolation.boat(from: $0, to: $1, t) }
        } else {
            boats = current.boats
        }
        time = Interpolation.value(from: previous.time, to: current.time, t)
    }

    var me: Boat { boats[myBoatIndex] }

    /// What `seat`'s autohelm holds (ADR 0007): the angle or the groove, and how far off the groove, in
    /// the wind at her; nil while her rudder is held off centre. For the vane's tick and arc (#122).
    func autohelm(ofSeat seat: Int) -> Autohelm.Reading? {
        boats[seat].autohelmReading(in: boatClass)
    }

    /// What `seat`'s boat does with her sails (#248): whether she planes, for the wake and spray (#117,
    /// #121), and her spinnaker (down, going up, up or coming down, and collapsed by the lee), for its
    /// drawing (#120). All three are the latest tick's (`frame`): none of them interpolates.
    func sails(ofSeat seat: Int) -> SailState {
        let boat = frame.boats[seat]
        return SailState(isPlaning: boat.isPlaning, spinnaker: boat.spinnaker,
                         isSpinnakerCollapsed: boat.isSpinnakerCollapsed(in: boatClass))
    }

    /// Whether `seat` holds her sheets eased at the latest tick (`frame`): what her pose flaps the sail for (#117).
    func ease(ofSeat seat: Int) -> Bool {
        frame.heldInputs.indices.contains(seat) && frame.heldInputs[seat].ease
    }

    /// Whether `seat`'s boat is a ghost at the latest tick, as `Race.isGhost(seat:)` says it: finished or DSQ, and
    /// once the race is over also still OCS or never started (#30, #86).
    func isGhost(ofSeat seat: Int) -> Bool {
        let boat = frame.boats[seat]
        return boat.isGhost || (frame.isOver && (boat.status == .ocs || boat.status == .prestart))
    }

    /// This world with each seat's boat drawn as `draw` says: the online driver's visual corrections (#68).
    func drawing(_ draw: (_ seat: Int, Boat) -> Boat) -> RenderWorld {
        var world = self
        world.boats = boats.enumerated().map { draw($0.offset, $0.element) }
        return world
    }

    /// The ground wind at `p` at the latest tick, or nil if the race doesn't hold its key yet (online).
    func groundWind(at p: Vec2) -> GroundWind? {
        try? frame.wind.sample(p, tick: frame.tick)
    }

    /// The ground wind at the latest tick, to sample at many places: `groundWind(at:)` at each, bit for bit, for
    /// a fraction of the cost (the water's ripple tiles, #116). Nil if the race doesn't hold its key yet (online).
    var windSampler: WindSampler? { try? frame.wind.sampler(atTick: frame.tick) }

    var puffs: [Puff] { frame.wind.activePuffs(atTick: frame.tick) }

    /// The fleet-wide wind at the latest tick: the mean direction turned by the shift, at the course average
    /// speed, with no puff and no venue bend. What puffs are shaded against (#15) and the ripple drifts on
    /// (#116). Nil if the race doesn't hold its key yet (online).
    var courseWind: GroundWind? {
        let wind = frame.wind
        guard let shift = try? wind.shift(atTick: frame.tick),
              let speed = try? wind.courseAverageSpeed(atTick: frame.tick) else { return nil }
        return GroundWind(direction: wrapAngle(wind.setup.meanDirection + shift), speed: speed)
    }

    /// The conditions the race is sailed in.
    var conditions: Conditions { frame.wind.setup.conditions }
}

/// A boat's sails as the scene draws them (`RenderWorld.sails(ofSeat:)`, #248).
struct SailState: Equatable {
    var isPlaning: Bool
    var spinnaker: Spinnaker
    var isSpinnakerCollapsed: Bool
}

/// Rendering between ticks (#18). Presentation only: none of it feeds back into a race.
enum Interpolation {
    static func value(from a: Double, to b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func position(from a: Vec2, to b: Vec2, _ t: Double) -> Vec2 {
        a + (b - a) * t
    }

    /// Turns the short way round: from −179° to 179° passes through ±180°, never through 0°.
    static func angle(from a: Double, to b: Double, _ t: Double) -> Double {
        wrapAngle(a + wrapAngle(b - a) * t)
    }

    /// `to`, with its position, heading and winds' directions eased back towards `from`. Everything else,
    /// such as status and penalties, is the latest tick's.
    static func boat(from a: Boat, to b: Boat, _ t: Double) -> Boat {
        var boat = b
        boat.position = position(from: a.position, to: b.position, t)
        boat.heading = angle(from: a.heading, to: b.heading, t)
        boat.windOverGround.direction = angle(from: a.windOverGround.direction, to: b.windOverGround.direction, t)
        boat.sailingWind.direction = angle(from: a.sailingWind.direction, to: b.sailingWind.direction, t)
        boat.apparentWind.direction = angle(from: a.apparentWind.direction, to: b.apparentWind.direction, t)
        return boat
    }
}

/// The fixed 30 Hz tick accumulator: how many ticks each display frame runs, never a longer tick
/// (#18). Real time is scaled by `timescale` (`-timescale`).
struct TickClock {
    /// A frame that leaves the accumulator this close under a whole tick runs it: display frame times
    /// in binary floating point sum to just under a tick (60 × 1/60 < 1), and would drop one.
    static let tolerance = 1e-6

    let timescale: Double
    /// Simulated time run past the last tick, in ticks.
    private var remainder = 0.0

    init(timescale: Double = 1) {
        self.timescale = timescale
    }

    /// Adds `seconds` of real time and returns the whole ticks now due.
    mutating func advance(by seconds: Double) -> Int {
        guard seconds > 0, seconds.isFinite else { return 0 }
        remainder += seconds * timescale * Double(Race.tickRate)
        let due = Int((remainder + TickClock.tolerance).rounded(.down))
        remainder -= Double(due)
        return due
    }

    /// How far past the last tick the clock is, 0…1 of a tick.
    var alpha: Double { remainder.clamped(to: 0...1) }
}
