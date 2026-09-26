import RegattaCore

/// What a bot plays beyond sailing the groove to the marks (#231): when she tacks or gybes, and when she
/// leaves the groove. Set by a bot-suite profile (`BotProfile`), or for a live bot by its skill until #102
/// grows the tiers and #234 the fleet tactics.
struct Tactics: Sendable, Equatable {
    /// She tacks on a header past this, radians, against the course axis; nil: never on a header.
    var headerThreshold: Double?
    /// Seconds after a tack or gybe before a shift, a puff or dirty air turns her again.
    var tackInterval: Double
    /// Seconds ahead she reads the shift at the rate the wind is turning: she tacks on the header coming.
    var anticipation: Double
    /// How far across the wind from her mark she sails before she turns back, as a share of her distance to
    /// it: the corridor. The baseline's narrow one funnels her in with a tack or gybe each time it halves; a
    /// wide one leaves the turns to the laylines and the shifts.
    var corridor: Double
    /// Downwind, she gybes on a shift past this that swings her away from her mark, radians; nil: never.
    var downwindShiftThreshold: Double?
    /// Off the plane, she heads up to plane again, then bears away to the groove.
    var replanes: Bool
    /// On the plane in a lull, she heads up to stay on it.
    var heatsUpInLulls: Bool
    /// Close to her mark and just below its layline, she pinches up to fetch it rather than tack twice.
    var pinchesToFetch: Bool
    /// Upwind, she weighs the puffs and lulls drawn on the water ahead on each tack.
    var seeksPuffs: Bool
    /// Upwind, she tacks out of another boat's wind shadow.
    var seeksClearAir: Bool
    /// Upwind, she tacks with the nearest boat close behind her, to stay between it and the mark.
    var covers: Bool

    init(profile: BotProfile?, skill: Double) {
        switch profile {
        case nil:
            // Today's bot: shifts from skill 0.5 up (#19), and she planes as a player would.
            self.init(headerThreshold: skill > 0.5 ? deg2rad(4) : nil, tackInterval: 15, replanes: true)
        case .baseline:
            // The groove only: headers past a threshold, the corridor, and nothing off the groove.
            self.init(headerThreshold: deg2rad(5), tackInterval: 15)
        case .tactician:
            self.init(headerThreshold: deg2rad(4), tackInterval: 20, anticipation: 6, corridor: 0.8,
                      downwindShiftThreshold: deg2rad(5), replanes: true, heatsUpInLulls: true, pinchesToFetch: true,
                      seeksPuffs: true, seeksClearAir: true, covers: true)
        }
    }

    init(headerThreshold: Double?, tackInterval: Double, anticipation: Double = 0, corridor: Double = 0.35,
         downwindShiftThreshold: Double? = nil, replanes: Bool = false, heatsUpInLulls: Bool = false,
         pinchesToFetch: Bool = false, seeksPuffs: Bool = false, seeksClearAir: Bool = false, covers: Bool = false) {
        self.headerThreshold = headerThreshold
        self.tackInterval = tackInterval
        self.anticipation = anticipation
        self.corridor = corridor
        self.downwindShiftThreshold = downwindShiftThreshold
        self.replanes = replanes
        self.heatsUpInLulls = heatsUpInLulls
        self.pinchesToFetch = pinchesToFetch
        self.seeksPuffs = seeksPuffs
        self.seeksClearAir = seeksClearAir
        self.covers = covers
    }
}

/// What a bot has made of her own wind and speed over the decisions so far (`BotBrain.observe`): what a
/// player reads off her readouts and her boat, remembered.
struct Senses: Sendable, Equatable {
    /// The race clock at her last decision.
    var time: Double?
    /// Her reckoning of the wind strength her grooves read (`Boat.grooveWindSpeed`): the class's running
    /// average of what her polar reads, m/s.
    var grooveWind: Double?
    /// Whether she reckons she is on the plane (`BoatClass.PlaningTuning.isPlaning`, from her speed and angle).
    var planing = false
    /// The wind direction at her, smoothed over a few seconds, radians.
    var direction: Double?
    /// How fast it is turning, radians per second, positive veering.
    var directionRate = 0.0
}

extension BotBrain {
    /// Seconds the wind direction is smoothed over before she reads a shift in it.
    static let directionSmoothing = 4.0
    /// Seconds its rate of turn is smoothed over.
    static let rateSmoothing = 8.0

    /// Takes in what she sees of her own boat now.
    mutating func observe(_ b: SeatView.OwnBoat, _ view: SeatView) {
        let dt = senses.time.map { max(0, view.time - $0) } ?? 0
        senses.time = view.time
        let tws = b.windSpeed * b.shadow
        let average = view.boatClass.steering.autohelm.grooveWindAverage
        if let groove = senses.grooveWind, average > 0 {
            senses.grooveWind = groove + (tws - groove) * min(1, dt / average)
        } else {
            senses.grooveWind = tws
        }
        if let planing = view.boatClass.planing {
            senses.planing = b.isOnCourse && planing.isPlaning(was: senses.planing, twa: b.twa, speed: b.speed, tws: tws)
        }
        if let direction = senses.direction, dt > 0 {
            let next = wrapAngle(direction + wrapAngle(b.windDirection - direction) * min(1, dt / Self.directionSmoothing))
            let rate = wrapAngle(next - direction) / dt
            senses.directionRate += (rate - senses.directionRate) * min(1, dt / Self.rateSmoothing)
            senses.direction = next
        } else {
            senses.direction = b.windDirection
        }
    }

    /// Her reckoning of `groove`'s sailing angle: at the wind strength her grooves read.
    func grooveAngle(_ groove: Autohelm.Groove, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        Autohelm.grooveAngle(groove, tws: senses.grooveWind ?? b.windSpeed * b.shadow, boatClass: view.boatClass)
    }

    // MARK: - Upwind

    /// The tack to beat on inside the corridor to her mark, starting from `planned`: the other one on a
    /// header past her threshold, and for a tactician, when the other side's puffs, clear air or a boat to
    /// cover make it worth a tack.
    mutating func upwindTack(_ b: SeatView.OwnBoat, _ view: SeatView, planned tack: Tack) -> Tack {
        guard let threshold = tactics.headerThreshold, view.time - lastTackTime > tactics.tackInterval else { return tack }
        let direction = (senses.direction ?? b.windDirection) + senses.directionRate * tactics.anticipation
        let shift = wrapAngle(direction - view.course.axis)
        // Headed: backed on starboard, veered on port.
        var headed = tack == .starboard ? -shift : shift
        if tactics.seeksPuffs { headed += puffAdvantage(b, view, over: tack) }
        if tactics.seeksClearAir && tack == b.tack && b.shadow < Self.dirtyAir { headed += Self.dirtyAirWeight }
        if tactics.covers, let rival = coverTarget(b, view), rival.tack != tack, headed > -threshold {
            return rival.tack
        }
        return headed > threshold ? tack.other : tack
    }

    /// Her wind shadow factor under which she is in another boat's dirty air.
    static let dirtyAir = 0.85
    /// Dirty air, worth this much header: enough to tack out of on a header short of her threshold.
    static let dirtyAirWeight = deg2rad(2)
    /// A puff on the water ahead, per unit of its tone averaged along her track, is worth this much shift: a
    /// tenth more wind makes about 5% more VMG upwind, as about a degree and a half of shift does.
    static let puffWeight = deg2rad(14)
    /// Hull lengths within which she covers a boat behind her.
    static let coverRange = 5.0
    /// How far ahead she looks along each tack for puffs, metres, in steps.
    static let puffLookAhead: [Double] = [30, 60, 90, 120, 150]

    /// How much better, as degrees of shift, the wind drawn on the water ahead is on the other tack than on
    /// `tack`: positive when the puffs are that way, or the lulls this way.
    func puffAdvantage(_ b: SeatView.OwnBoat, _ view: SeatView, over tack: Tack) -> Double {
        guard !view.puffs.isEmpty else { return 0 }
        let up = grooveAngle(.upwind, b, view)
        let speed = max(b.speed, 2)
        func tone(_ tack: Tack) -> Double {
            let ahead = Vec2.heading(Aim(angle: up, tack: tack).heading(wind: b.windDirection))
            var total = 0.0
            for distance in Self.puffLookAhead {
                let point = b.position + ahead * distance
                let seconds = distance / speed
                for puff in view.puffs {
                    let offset = point - (puff.center + puff.drift * seconds)
                    let d2 = offset.lengthSquared / (puff.radius * puff.radius)
                    guard d2 < 1 else { continue }
                    total += puff.tone * (1 - d2) * (1 - d2)
                }
            }
            return total / Double(Self.puffLookAhead.count)
        }
        return (tone(tack.other) - tone(tack)) * Self.puffWeight
    }

    /// The boat close behind her on the beat she'd cover: sailing upwind, within a few lengths and not
    /// ahead of her up the course, and far enough abeam that a tack onto her tack is clear of her.
    func coverTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> SeatView.OtherBoat? {
        let length = view.boatClass.hull.length
        let up = view.course.upwind
        var nearest: (boat: SeatView.OtherBoat, distance: Double)?
        for other in view.others where !other.isGhost {
            let offset = other.position - b.position
            let distance = offset.length
            guard distance < length * Self.coverRange, abs(wrapAngle(b.windDirection - other.heading)) < .pi / 3 else { continue }
            let behind = -offset.dot(up)
            guard behind > length, abs(offset.dot(up.rightPerp)) > length * 2 else { continue }
            if distance < nearest?.distance ?? .infinity { nearest = (other, distance) }
        }
        return nearest?.boat
    }

    /// The upwind groove on `tack`.
    func upwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, tack: Tack) -> Aim {
        .groove(.upwind, tack: tack, angle: grooveAngle(.upwind, b, view))
    }

    /// Metres from her mark inside which she pinches to fetch it.
    static let pinchRange = 60.0
    /// The highest she pinches: this far off the wind, radians, well clear of the no-go zone.
    static let pinchAngle = deg2rad(38)

    /// The upwind aim on `tack` for a target `distance` metres off, bearing `relative` to the wind (to the right
    /// positive): the groove, or for a tactician close to it and just below its layline, the pinch that fetches it.
    func upwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, tack: Tack, relative: Double, distance: Double) -> Aim {
        let groove = upwindAim(b, view, tack: tack)
        guard tactics.pinchesToFetch, distance < Self.pinchRange, tack == b.tack else { return groove }
        let off = tack == .starboard ? -relative : relative
        guard off >= Self.pinchAngle && off < groove.angle - view.boatClass.steering.autohelm.upwindSnap else { return groove }
        return Aim(angle: off, tack: tack)
    }

    // MARK: - Downwind

    /// The gybe to run on inside the corridor to her mark, starting from `planned`: the other one when the
    /// wind has shifted past her threshold the way that swings her heading away from the mark. Downwind that
    /// is a veer on starboard (her heading turns further from dead downwind) and a back on port: the mirror
    /// of a header upwind.
    mutating func downwindGybe(_ b: SeatView.OwnBoat, _ view: SeatView, planned gybe: Tack) -> Tack {
        guard let threshold = tactics.downwindShiftThreshold, view.time - lastTackTime > tactics.tackInterval else { return gybe }
        let direction = (senses.direction ?? b.windDirection) + senses.directionRate * tactics.anticipation
        let shift = wrapAngle(direction - view.course.axis)
        let away = gybe == .starboard ? shift : -shift
        return away > threshold ? gybe.other : gybe
    }

    /// How far above the groove she sails in a lull to stay on the plane: past the downwind snap.
    static let lullHeatUp = deg2rad(12)
    /// On the plane, she is in a lull when her speed is within this share above the class's off-plane speed.
    static let lullSpeedMargin = 1.25
    /// She heads up to plane at an angle where her speed off the plane reaches this share of the class's
    /// on-plane speed, so she gets there soon.
    static let planingSpeedMargin = 1.08
    /// The steps she searches for that angle in.
    static let planingSearchStep = deg2rad(2)

    /// `aim`, a groove or an angle off the wind, as her tactics sail it: headed up to get back on the plane
    /// when she has come off it and the wind is strong enough to plane, or above the groove in a lull on it.
    func downwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, aim: Aim) -> Aim {
        guard let planing = view.boatClass.planing, aim.angle >= planing.fromTWA else { return aim }
        let tws = b.windSpeed * b.shadow
        if !senses.planing {
            guard tactics.replanes, let angle = Self.planingAngle(tws: tws, deepest: aim.angle, view.boatClass),
                  aim.angle - angle > view.boatClass.steering.autohelm.downwindSnap else { return aim }
            return Aim(angle: angle, tack: aim.tack, tolerance: deg2rad(3))
        }
        if tactics.heatsUpInLulls && b.speed < planing.offSpeed * Self.lullSpeedMargin {
            return aim.offset(by: -Self.lullHeatUp, tolerance: deg2rad(3))
        }
        return aim
    }

    /// The deepest angle, no deeper than `deepest`, from which a boat of `boatClass` off the plane gets on
    /// it in `tws` (m/s): where her speed off the plane reaches the on-plane speed, with the margin, and the
    /// apparent wind comes no further aft than the class lets her plane with. Nil when the wind is too light
    /// to plane at any angle.
    static func planingAngle(tws: Double, deepest: Double, _ boatClass: BoatClass) -> Double? {
        guard let planing = boatClass.planing else { return nil }
        var angle = deepest
        while angle >= planing.fromTWA {
            var speed = planing.offPlaneSpeed(twa: angle, tws: tws, polar: boatClass.polar)
            // Heading up past the spinnaker's drop she sails on two sails.
            if let spinnaker = boatClass.spinnaker, angle < spinnaker.dropBelowTWA { speed *= spinnaker.twoSailFactor(twa: angle) }
            // Her apparent wind: the true wind plus her own, over the bow. RegattaCore's sine and cosine
            // (`Vec2.heading`), so a debug build decides as a release build does.
            let wind = Vec2.heading(angle) * tws
            let ahead = wind.y + speed
            let apparent = (ahead * ahead + wind.x * wind.x).squareRoot()
            if speed >= planing.onSpeed * planingSpeedMargin && apparent > 0 && ahead / apparent >= Vec2.heading(planing.onMaxAWA).y {
                return angle
            }
            angle -= planingSearchStep
        }
        return nil
    }
}

extension Tack {
    /// The other tack.
    var other: Tack { self == .port ? .starboard : .port }
}
