/// What one seat's sailor can see of a race at the present tick (#19, #98): all a bot's brain is given.
///
/// Built fresh for one seat at one tick (`Race.seatView(for:)`, or for several seats at once with
/// `Race.seatViews(for:)`) and a value: it holds no race and nothing that reaches into one, so a brain can
/// learn from it only what a player in that seat sees on the screen or in the briefing:
/// - the wind as it is now, never later (ADR 0001, #10): the puffs and lulls drawn on the water, the course
///   average they're toned against, every boat's wind shadow, and the wind at her own boat. No key, and
///   no way to sample the wind at another tick or place: only what is drawn;
/// - the current in full (ADR 0003): a public function of the venue, the tide and the clock, with its tide
///   forecast;
/// - the course, the land, her laylines and the class every boat sails;
/// - the other boats as they're drawn (#15), with her right-of-way relation to each and the rule calls on
///   show. Never their held inputs (#19), rule 18 records, incident memory or names;
/// - the clock, her place, the fleet's size and the finish window's countdown.
///
/// Two equal views hold the same information.
public struct SeatView: Sendable, Equatable {
    /// Whose view it is: the seat `own` sails.
    public let seat: Int
    /// Race clock in ticks: negative in the start sequence, 0 at the gun.
    public let tick: Int
    /// Race clock in seconds.
    public let time: Double
    /// Where she stands in the fleet, from 1 (`Race.place(of:)`).
    public let place: Int
    public let fleetSize: Int
    /// Seconds until the race closes (`Race.closeTick`: the finish window after the first finish, capped by
    /// the time limit), once a boat has finished; nil until then.
    public let finishWindowRemaining: Double?

    /// Her own boat.
    public let own: OwnBoat
    /// Every other seat's boat, in seat order.
    public let others: [OtherBoat]
    /// The rule calls on show: each from its call for the rules' penalty completion window (30 s), which is
    /// its offender's completion deadline whenever the call fixed one (`RuleCall.completeDeadlineTick`).
    public let ruleCallLines: [RuleCallLine]

    /// The puffs and lulls on the water now, as drawn, in window and spawn order.
    public let puffs: [DrawnPuff]
    /// The wind speed now away from any puff or lull, m/s: what the puffs are toned against (#15). Nil
    /// only in a race without the key for now.
    public let courseWindSpeed: Double?
    /// The wind shadow and backwind every boat casts now, in seat order, hers included; a ghost casts none.
    public let shadowCones: [ShadowCone]

    /// The water's motion over the venue at any place and tick (ADR 0003): public, so given whole.
    public let current: CurrentField

    public let course: CourseLayout
    /// The venue's land, which bounds the water with the race area.
    public let land: [Venue.LandPolygon]
    /// Her laylines: to the mark she's sailing for, in the wind at it now; nil on a leg without.
    public let laylines: Laylines?

    /// The class every boat sails (ADR 0004): hull, polar and handling, all public.
    public let boatClass: BoatClass

    /// The tide forecast (ADR 0003, #78) over race ticks `window` for `points` and every wet node: what the
    /// briefing shows, worked out from the public `current`.
    public func tideForecast(window: ClosedRange<Int>, points: [Vec2] = []) -> TideForecast {
        TideForecast(field: current, window: window, points: points)
    }

    /// `seat`'s view, with what every seat sees alike (`shared`) made once for all the views built at this tick.
    init(race: Race, seat: Int, shared: Shared) {
        let boats = race.boats
        let boat = boats[seat]
        let boatClass = shared.boatClass
        self.seat = seat
        tick = shared.tick
        time = shared.time
        place = race.place(of: seat)
        fleetSize = boats.count
        finishWindowRemaining = shared.finishWindowRemaining

        own = OwnBoat(boat, ease: race.heldInputs[seat].ease, boatClass: boatClass)
        let rights = race.rightsOfWay(of: seat)
        var others: [OtherBoat] = []
        others.reserveCapacity(boats.count - 1)
        for other in boats.indices where other != seat {
            others.append(OtherBoat(boats[other], isGhost: race.isGhost(seat: other), rightOfWay: rights[other]))
        }
        self.others = others
        ruleCallLines = shared.ruleCallLines

        puffs = shared.puffs
        courseWindSpeed = shared.courseWindSpeed
        shadowCones = shared.shadowCones

        current = shared.current
        course = shared.course
        land = shared.land
        laylines = Laylines(for: shared.course.legSailed(status: boat.status, legIndex: boat.legIndex), in: shared.course,
                            polar: boatClass.polar, wind: race.heldGroundWind(at:))
        self.boatClass = boatClass
    }

    /// What every seat sees alike at one tick: the clock, the rule calls, the wind on the water, the water, the
    /// course and the class. Made once for all the views built together (`Race.seatViews(for:)`), since a
    /// fleet of bots looks at the same tick several at a time.
    struct Shared {
        let tick: Int
        let time: Double
        let finishWindowRemaining: Double?
        let ruleCallLines: [RuleCallLine]
        let puffs: [DrawnPuff]
        let courseWindSpeed: Double?
        let shadowCones: [ShadowCone]
        let current: CurrentField
        let course: CourseLayout
        let land: [Venue.LandPolygon]
        let boatClass: BoatClass

        init(race: Race) {
            tick = race.tick
            time = race.time
            finishWindowRemaining = race.firstFinishTime == nil ? nil : Double(race.closeTick - race.tick) / Double(Race.tickRate)
            let shown = RulesConfig.ticks(race.rules.raceFormat.penalty.complete)
            ruleCallLines = race.incidents.incidents.compactMap { incident in
                guard case .called(let call) = incident.outcome, call.tick + shown >= race.tick else { return nil }
                return RuleCallLine(offender: call.offender, victim: call.victim, rule: call.rule, tick: call.tick)
            }
            let wind = race.wind
            puffs = wind.activePuffs(atTick: race.tick).map(DrawnPuff.init)
            courseWindSpeed = try? wind.courseAverageSpeed(atTick: race.tick)
            var cones: [ShadowCone] = []
            cones.reserveCapacity(race.boats.count)
            for caster in race.boats.indices { if let cone = race.shadowCone(ofSeat: caster) { cones.append(cone) } }
            shadowCones = cones
            current = race.current
            course = race.course
            land = race.files.venue.content.land
            boatClass = race.boatClass
        }
    }

    /// Her own boat: what her screen shows of it, and her own held input's ease.
    public struct OwnBoat: Sendable, Equatable {
        public let position: Vec2
        /// Compass heading, radians.
        public let heading: Double
        /// Metres per second through the water: her wake and speed readout (#15).
        public let speed: Double
        /// Metres per second over the ground: through the water plus the current, which carries her (#11).
        public let velocityOverGround: Vec2
        /// Her rudder, −1 (hard to port) … 1 (hard to starboard): it follows the helm at the class's rate.
        public let rudder: Double
        /// Whether her held input lets the sheets out (#13).
        public let ease: Bool
        /// Which side her boom is on; her tack is the other side.
        public let boomSide: BoomSide
        /// What her autohelm holds (ADR 0007): the wind angle held or the groove, whether it's sailing the
        /// tap, and how far off the groove, as the vane shows it (#122); nil while her rudder is held off centre.
        public let autohelm: Autohelm.Reading?
        public let status: BoatStatus
        /// The leg she's sailing: an index into the course's `legs`.
        public let legIndex: Int
        /// How many of that leg's rounding stages she has crossed (`CourseLayout.roundingStages(of:)`).
        public let roundingStage: Int
        /// Penalty turns she owes, as the HUD counts them (#9).
        public let penaltyTurnsOwed: Int
        /// The wind over the ground at her, before her wind shadow: what the wind readouts show (#15).
        public let windOverGround: Wind
        /// The wind she sails in, over the water (the ground wind less the current): what her wind angle
        /// reads (#14).
        public let sailingWind: Wind
        /// Her wind shadow's multiplier on the sailing wind's speed, 1 in clean air: the HUD's shadow cue (#10).
        public let shadow: Double

        init(_ boat: Boat, ease: Bool, boatClass: BoatClass) {
            position = boat.position
            heading = boat.heading
            speed = boat.speed
            velocityOverGround = boat.velocityOverGround
            rudder = boat.rudder
            self.ease = ease
            boomSide = boat.boomSide
            autohelm = boat.autohelmReading(in: boatClass)
            status = boat.status
            legIndex = boat.legIndex
            roundingStage = boat.roundingStage
            penaltyTurnsOwed = boat.penaltyTurnsOwed
            windOverGround = boat.windOverGround
            sailingWind = boat.sailingWind
            shadow = boat.shadow
        }

        /// Where the sailing wind blows from, radians.
        public var windDirection: Double { sailingWind.direction }
        /// The sailing wind's speed, m/s, before any shadow.
        public var windSpeed: Double { sailingWind.speed }
        /// Sailing wind direction relative to the bow; positive = wind over the starboard side.
        public var relativeWind: Double { wrapAngle(windDirection - heading) }
        /// Her wind angle, 0…π: the HUD's readout.
        public var twa: Double { abs(relativeWind) }
        public var tack: Tack { boomSide == .port ? .starboard : .port }
        public var forward: Vec2 { .heading(heading) }
        /// Velocity through the water, m/s.
        public var velocity: Vec2 { forward * speed }
        public var isOnCourse: Bool { status == .prestart || status == .ocs || status == .racing }
    }

    /// Another seat's boat as it is drawn (#15): nothing of its helm's input.
    public struct OtherBoat: Sendable, Equatable {
        public let seat: Int
        public let position: Vec2
        /// Compass heading, radians.
        public let heading: Double
        /// Metres per second through the water: her wake.
        public let speed: Double
        /// Which side her boom is on; her tack is the other side.
        public let boomSide: BoomSide
        /// Stopped racing (CONTEXT.md, "Ghost"; `Race.isGhost(seat:)`): drawn faded, with no shadow and no
        /// rights or obligations.
        public let isGhost: Bool
        /// Which of her and this view's seat must keep clear now under rules 10–13 (`Race.rightOfWay`), as
        /// the right-of-way glyphs show it (#123); nil if either is a ghost.
        public let rightOfWay: RightOfWay?

        init(_ boat: Boat, isGhost: Bool, rightOfWay: RightOfWay?) {
            seat = boat.id
            position = boat.position
            heading = boat.heading
            speed = boat.speed
            boomSide = boat.boomSide
            self.isGhost = isGhost
            self.rightOfWay = rightOfWay
        }

        public var tack: Tack { boomSide == .port ? .starboard : .port }
        public var forward: Vec2 { .heading(heading) }
        /// Velocity through the water, m/s.
        public var velocity: Vec2 { forward * speed }
    }

    /// A rule call's line between its two boats (#15): who, under which rule, since when. The call alone,
    /// never the incident behind it.
    public struct RuleCallLine: Sendable, Equatable {
        public let offender: Int
        public let victim: Int
        public let rule: RacingRule
        /// The tick of the call.
        public let tick: Int
    }

    /// A puff or lull on the water now, as drawn (#15, #76).
    public struct DrawnPuff: Sendable, Equatable {
        public let center: Vec2
        /// Metres.
        public let radius: Double
        /// Its change in wind speed at its centre now, as a fraction of the course average: positive for a
        /// puff, negative for a lull. What its tone shows (`Puff.intensity`).
        public let tone: Double
        /// How it moves over the ground, m/s: downwind with the breeze.
        public let drift: Vec2

        init(_ puff: Puff) {
            center = puff.center
            radius = puff.radius
            tone = puff.intensity
            drift = puff.velocity
        }
    }
}

extension Race {
    /// What `seat`'s sailor sees now (`SeatView`): a bot's brain sees the race through this alone (#98).
    public func seatView(for seat: Int) -> SeatView {
        SeatView(race: self, seat: seat, shared: SeatView.Shared(race: self))
    }

    /// What each of `seats` sees now, in order: each the view `seatView(for:)` gives, with what they see alike
    /// made once. How a fleet of bots looks at a tick (`SeatControllers.drive`).
    public func seatViews(for seats: [Int]) -> [SeatView] {
        guard !seats.isEmpty else { return [] }
        let shared = SeatView.Shared(race: self)
        return seats.map { SeatView(race: self, seat: $0, shared: shared) }
    }
}
