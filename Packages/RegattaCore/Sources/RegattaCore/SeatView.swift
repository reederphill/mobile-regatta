/// What one seat's sailor can see of a race at the present tick (#19, #98): all a bot's brain is given.
///
/// Built fresh for one seat at one tick (`Race.seatView(for:)`, or for several seats at once with
/// `Race.seatViews(for:)`) and a value: it holds no race and nothing that reaches into one, so a brain can
/// learn from it only what a player in that seat sees on the screen or in the briefing:
/// - the wind as it is now, never later (ADR 0001, #10): the puffs and lulls drawn on the water, the course
///   average they're toned against, the pressure over the race area as the water and minimap tone it (#290, ADR
///   0008), every boat's wind shadow, and the wind at her own boat. No key, and no way to sample the wind at another
///   tick or place: only what is drawn;
/// - the current in full (ADR 0003): a public function of the venue, the tide and the clock, with its tide
///   forecast;
/// - the course, the land, her laylines and the class every boat sails;
/// - the other boats as they're drawn (#15), with her right-of-way relation to each and the rule calls on
///   show. Never their held inputs (#19), rule 18 or rule 17 records beyond the notices told her own boat (#101,
///   #346), incident memory or names;
/// - her own boat's zone, the mark-room notices told her (#101), and the proper-course notice while rule 17 holds
///   her to it (#346: the proper course and tolerance #347 draws for the player);
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

    /// The puffs and lulls on the water now, as drawn, in window and spawn order. `internal(set)`, as `pressure` is, so
    /// a test can clear the water around a field it draws.
    public internal(set) var puffs: [DrawnPuff]
    /// The wind speed now away from any puff or lull, m/s: what the puffs are toned against (#15). Nil
    /// only in a race without the key for now.
    public let courseWindSpeed: Double?
    /// The backwind every boat casts now, in seat order, hers included, each with its level and held side (#377); a
    /// ghost casts none.
    public let shadowCones: [ShadowCone]
    /// The wind shadow (#377): every boat's ribbon wake now, as the race steps it (`Race.wake`): a bot reads the point
    /// map (`TurbulenceRibbons.pointMap(of:tick:)`) or the loss it leaves anywhere.
    public let wake: TurbulenceRibbons
    /// Each seat's backwind header now, radians (`Race.header(ofSeat:)`), by seat: 0 for a class without a header.
    public let headers: [Double]
    /// The pressure over the race area, as the water and the minimap draw it (#290, ADR 0008): a coarse grid of the
    /// field as it was at most `PressureMap.refreshTicks` ago, and never later. Nil in a race without the keys for it.
    public internal(set) var pressure: PressureMap?

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

        let zone = shared.course.markZone(of: boat, hull: boat.hull(outline: boatClass.hull.outline))
        own = OwnBoat(boat, ease: race.heldInputs[seat].ease, boatClass: boatClass, penalty: race.rules.raceFormat.penalty,
                      zone: zone.map(Zone.init), markRoom: race.markRoomNotices(of: seat),
                      properCourse: race.properCourseNotice(of: seat, course: shared.course, boatClass: boatClass))
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
        wake = shared.wake
        headers = shared.headers
        pressure = shared.pressure

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
        let wake: TurbulenceRibbons
        let headers: [Double]
        let pressure: PressureMap?
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
            wake = race.wake
            headers = race.boats.indices.map(race.header(ofSeat:))
            pressure = race.pressureMap()
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
        /// Her owed penalty turns as the HUD shows them (G4, #89): how many, and the current turn's deadlines
        /// and progress (`Race.owedPenalty(ofSeat:)`); nil while she owes none.
        public let penalty: OwedPenalty?
        /// The wind over the ground at her, before her wind shadow: what the wind readouts show (#15).
        public let windOverGround: Wind
        /// The wind she sails in, over the water (the ground wind less the current): what her wind angle
        /// reads (#14).
        public let sailingWind: Wind
        /// Her wind shadow's multiplier, 1 in clean air: the HUD's shadow cue (#10). On the sailing wind's speed, or on
        /// her target speed for a class whose shadow is a speed loss (#263, `speedShadow`).
        public let shadow: Double
        /// The wind speed her polar reads, m/s (`Boat.polarWindSpeed(in:)`): the sailing wind's, less any shadow on it.
        public let polarWindSpeed: Double
        /// The shadow's multiplier on her target speed (`Boat.speedShadow(in:)`): 1 for a class whose shadow slows
        /// the wind instead.
        public let speedShadow: Double
        /// The zone of the mark rule 18 tests her against (#91, #101), as the scene draws it around the mark; nil
        /// unless she is racing.
        public let zone: Zone?
        /// The mark-room notices told her (#91, #101): each rule 18 record naming her, while it lasts. The umpire's
        /// alone, so none in a prediction (ADR 0005).
        public let markRoom: [MarkRoomNotice]
        /// The proper-course notice told her (rule 17, #346): while the umpire's rule 17 records name her the leeward
        /// boat that came up from astern, the proper course she is held to and how far above it she may sail. The
        /// umpire's alone, so nil in a prediction (ADR 0005), and nil while no record names her leeward.
        public let properCourse: ProperCourseNotice?

        init(_ boat: Boat, ease: Bool, boatClass: BoatClass, penalty: RulesConfig.Penalty, zone: Zone?,
             markRoom: [MarkRoomNotice], properCourse: ProperCourseNotice?) {
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
            self.penalty = OwedPenalty(boat, penalty: penalty)
            windOverGround = boat.windOverGround
            sailingWind = boat.sailingWind
            shadow = boat.shadow
            polarWindSpeed = boat.polarWindSpeed(in: boatClass)
            speedShadow = boat.speedShadow(in: boatClass)
            self.zone = zone
            self.markRoom = markRoom
            self.properCourse = properCourse
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
        /// the right-of-way glyphs show it (#123), or under rule 21 when she is taking a penalty or returning and
        /// this view's seat isn't (`Race.rightsOfWay(of:)`, #337); nil if either is a ghost.
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

    /// The zone of the mark rule 18 tests her against (`CourseLayout.markZone(of:hull:)`, #91): the mark of the leg
    /// she is racing, the nearer of a gate's two, or the nearer end of the finish line. What the scene draws: the
    /// mark and its zone's circle.
    public struct Zone: Sendable, Equatable {
        /// The mark's centre.
        public let mark: Vec2
        /// The side she leaves it on.
        public let side: RoundingSide
        /// Metres from the mark's centre to the nearest point of her hull.
        public let distance: Double
        /// Whether any part of her hull is in the zone.
        public let isIn: Bool

        init(_ zone: MarkZone) {
            mark = zone.mark.position
            side = zone.side
            distance = zone.distance
            isIn = zone.isIn
        }
    }

    /// A mark-room notice (#91): a rule 18 record between the seat and another boat, read from the umpire (no event
    /// announces it, #403) while it lasts (`UmpireState.markRoom(_:)`). Which boat is entitled to mark-room at the mark they are both
    /// racing to, and which must give it. Mark-room is not right of way: rules 10–13 still say who keeps clear.
    public struct MarkRoomNotice: Sendable, Equatable {
        /// The boat entitled to mark-room.
        public let entitled: Int
        /// The boat that must give it to her.
        public let owing: Int
        /// `.givingMarkRoom` (18.2) or `.tackingInTheZone` (18.3).
        public let rule: RacingRule

        public init(entitled: Int, owing: Int, rule: RacingRule) {
            self.entitled = entitled
            self.owing = owing
            self.rule = rule
        }
    }

    /// A proper-course notice (rule 17, #346): the umpire's rule 17 records naming her the leeward boat that became
    /// overlapped from clear astern (`Race.properCourseRestrictions(of:)`), with the proper course they hold her to
    /// now (`ProperCourse`, the umpire's own function, in the wind at her) and the rules file's tolerance for it.
    /// "Above" it, which rule 17 forbids, is closer to the wind than `sailingAngle - tolerance`. Not on the wire and
    /// no event: a bot reads it, the player's own screen has its own cue (#347).
    public struct ProperCourseNotice: Sendable, Equatable {
        /// The windward boats she is held to her proper course against, in seat order.
        public let windward: [Int]
        /// Her proper course as a sailing angle on her tack (`ProperCourse.sailingAngle`), radians.
        public let sailingAngle: Double
        /// Her proper course as a compass heading (`ProperCourse.heading`), radians.
        public let heading: Double
        /// How far closer to the wind than her proper course she may sail (`RulesConfig.ProperCourseLimits
        /// .tolerance(_:)` for the leg), radians.
        public let tolerance: Double

        public init(windward: [Int], sailingAngle: Double, heading: Double, tolerance: Double) {
            self.windward = windward
            self.sailingAngle = sailingAngle
            self.heading = heading
            self.tolerance = tolerance
        }

        /// The highest she may sail, as a sailing angle on her tack (`ProperCourse.edgeSailingAngle(tolerance:)`).
        public var edgeSailingAngle: Double { max(0, sailingAngle - tolerance) }
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

    /// The pressure over the race area (`Pressure`), as the minimap draws it at course scale (#290, ADR 0008): the
    /// field without its puffs, sampled on a grid of nodes over the race area's rectangle, its sides included, and
    /// nothing beyond it. The geography (#287) is in it, public as the venue file is; the puffs are `puffs`.
    public struct PressureMap: Sendable, Equatable {
        /// The rectangle the grid covers.
        public let area: RaceArea
        /// The tick of the field it shows.
        public let tick: Int
        /// Nodes across the area, from its left side looking upwind to its right, and along it from its bottom up.
        public let columns: Int
        public let rows: Int
        /// The pressure at each node, row by row from the bottom, each row from the left.
        public let nodes: [Pressure]

        /// The grid a view's map has: nodes across and along the race area.
        public static let gridColumns = 16
        public static let gridRows = 16
        /// A view's map shows the field at the latest multiple of this many ticks, at or before now: refreshed as
        /// often as a player's glance at the minimap.
        public static let refreshTicks = 2 * Race.tickRate
        /// Metres past a side within which a point still reads the side's nodes: rounding, no more.
        static let edgeTolerance = 1e-6

        public init(area: RaceArea, tick: Int, columns: Int, rows: Int, nodes: [Pressure]) {
            precondition(columns >= 2 && rows >= 2 && nodes.count == columns * rows, "a pressure map needs a grid of nodes")
            self.area = area
            self.tick = tick
            self.columns = columns
            self.rows = rows
            self.nodes = nodes
        }

        /// The refresh tick a view at `tick` shows the field at: the latest multiple of `refreshTicks` at or before it.
        static func refreshTick(atOrBefore tick: Int) -> Int {
            let every = refreshTicks
            return tick >= 0 ? tick / every * every : -((every - 1 - tick) / every * every)
        }

        /// `race`'s map at refresh tick `tick`, or nil if its wind can't be read there.
        init?(race: Race, tick: Int) {
            guard let pressure = try? race.wind.pressure(atTick: tick) else { return nil }
            let area = race.course.raceArea
            var nodes: [Pressure] = []
            nodes.reserveCapacity(Self.gridColumns * Self.gridRows)
            for row in 0..<Self.gridRows {
                for column in 0..<Self.gridColumns {
                    nodes.append(pressure(Self.position(column: column, row: row, area, Self.gridColumns, Self.gridRows)))
                }
            }
            self.init(area: area, tick: tick, columns: Self.gridColumns, rows: Self.gridRows, nodes: nodes)
        }

        /// Where node (`column`, `row`) lies.
        public func position(column: Int, row: Int) -> Vec2 {
            Self.position(column: column, row: row, area, columns, rows)
        }

        static func position(column: Int, row: Int, _ area: RaceArea, _ columns: Int, _ rows: Int) -> Vec2 {
            let up = Vec2.heading(area.axis)
            let across = area.halfWidth * (2 * Double(column) / Double(columns - 1) - 1)
            let along = area.halfLength * (2 * Double(row) / Double(rows - 1) - 1)
            return area.centre + up.rightPerp * across + up * along
        }

        /// The pressure at node (`column`, `row`).
        public func node(column: Int, row: Int) -> Pressure { nodes[row * columns + column] }

        /// The pressure at `p`, between the nodes around it; nil outside the area, where the map shows nothing.
        public func sample(at p: Vec2) -> Pressure? {
            let offset = p - area.centre
            let up = Vec2.heading(area.axis)
            let across = offset.dot(up.rightPerp), along = offset.dot(up)
            // Its sides included, to rounding.
            guard abs(across) <= area.halfWidth + Self.edgeTolerance, abs(along) <= area.halfLength + Self.edgeTolerance
            else { return nil }
            func cell(_ x: Double, _ half: Double, _ count: Int) -> (Int, Double) {
                let u = (x / half + 1) / 2 * Double(count - 1)
                let lower = min(max(Int(u.rounded(.down)), 0), count - 2)
                return (lower, min(max(u - Double(lower), 0), 1))
            }
            let (c, s) = cell(across, area.halfWidth, columns)
            let (r, t) = cell(along, area.halfLength, rows)
            let a = node(column: c, row: r), b = node(column: c + 1, row: r)
            let d = node(column: c, row: r + 1), e = node(column: c + 1, row: r + 1)
            func blend(_ value: (Pressure) -> Double) -> Double {
                let low = value(a) + (value(b) - value(a)) * s
                let high = value(d) + (value(e) - value(d)) * s
                return low + (high - low) * t
            }
            return Pressure(factor: blend(\.factor), turn: blend(\.turn))
        }
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

    /// The mark-room notices told `seat` (`SeatView.OwnBoat.markRoom`): each rule 18 record naming her now, in seat
    /// order of the other boat. None in a prediction, which holds no umpire (ADR 0005).
    func markRoomNotices(of seat: Int) -> [SeatView.MarkRoomNotice] {
        guard let umpire else { return [] }
        return boats.indices.compactMap { other in
            guard other != seat, let record = umpire.markRoom(SeatPair(seat, other)) else { return nil }
            return SeatView.MarkRoomNotice(entitled: record.entitled, owing: record.owing, rule: record.rule)
        }
    }

    /// The proper-course notice told `seat` (`SeatView.OwnBoat.properCourse`): while any rule 17 record names her the
    /// leeward boat (`properCourseRestrictions(of:)`), her proper course on `course` in `boatClass` now and the rules
    /// file's tolerance for it. Nil in a prediction, which holds no umpire (ADR 0005), under rules without rule 17's
    /// limits, and while she has no proper course (`ProperCourse.of`).
    func properCourseNotice(of seat: Int, course: CourseLayout, boatClass: BoatClass) -> SeatView.ProperCourseNotice? {
        guard let limits = rules.incidents.properCourse else { return nil }
        let windward = properCourseRestrictions(of: seat)
        guard !windward.isEmpty, let proper = boats[seat].properCourse(on: course, boatClass: boatClass) else { return nil }
        return SeatView.ProperCourseNotice(windward: windward, sailingAngle: proper.sailingAngle, heading: proper.heading,
                                           tolerance: limits.tolerance(proper.kind))
    }

    /// What each of `seats` sees now, in order: each the view `seatView(for:)` gives, with what they see alike
    /// made once. How a fleet of bots looks at a tick (`SeatControllers.drive`).
    public func seatViews(for seats: [Int]) -> [SeatView] {
        guard !seats.isEmpty else { return [] }
        let shared = SeatView.Shared(race: self)
        return seats.map { SeatView(race: self, seat: $0, shared: shared) }
    }

    /// The pressure map a view shows now (`SeatView.PressureMap`): made once per refresh tick, and kept for the views
    /// until the next.
    func pressureMap() -> SeatView.PressureMap? {
        let refresh = SeatView.PressureMap.refreshTick(atOrBefore: tick)
        if let drawn = pressureMapDrawn, drawn.tick == refresh { return drawn }
        let map = SeatView.PressureMap(race: self, tick: refresh)
        if map != nil { pressureMapDrawn = map }
        return map
    }
}
