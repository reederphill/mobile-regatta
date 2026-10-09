import Foundation
import RegattaCore

/// Every threshold the hints fire by (#129), in one value: placeholders, the ticket's numbers where it gives them,
/// each a debug slider (`TuningCatalog`'s Hints group, fun before realism). App-side and never logged.
nonisolated struct HintTuning: Codable, Equatable, Sendable {
    /// Letting go (#219, ruling 3): after the gun, you've steered this many seconds without a break, the autohelm
    /// never holding...
    var lettingGoSeconds = 20.0
    /// ...or this many in your first race (#134), so it shows early there.
    var lettingGoFirstRaceSeconds = 5.0
    /// The wind-shift hint: the fleet-wide wind, smoothed over `shiftSmoothingSeconds`, has turned more than this
    /// from where it was at your start (#23's "shift > 5°"; #221's ~3° wobble is what the smoothing is for).
    var shiftDegrees = 5.0
    var shiftSmoothingSeconds = 5.0
    /// The no-go hint: inside the no-go zone this long, racing and not tacking.
    var noGoSeconds = 1.5
    /// The shadow hint: your `Boat.shadow` below 1 less this, for this long (the sail's starved deadband).
    var shadowDeadband = 0.05
    var shadowSeconds = 1.5
    /// The puff hint: a visible puff's edge within this many hull lengths (#23: "puff ≤ 3 lengths").
    var puffHulls = 3.0
    /// The layline hint: within this many hull lengths of one of your laylines.
    var laylineHulls = 3.0
    /// The glow hints: a glow at least this strong (0 to 1), so it is clearly showing.
    var glowIntensity = 0.5
    /// The start-sequence hint shows only while at least this many seconds are left to the gun.
    var startSequenceLatestSeconds = 10.0
    /// The groove-tick hint: after this much racing, whether or not you've let go (sooner once you have and the
    /// letting-go hint is done).
    var grooveTickRacingSeconds = 60.0
    /// Steered each way: the rudder held past this share of full, for this long each way.
    var steerRudderShare = 0.25
    var steerSeconds = 0.1
    /// Let go: the autohelm holds this long after you've steered.
    var autohelmHoldSeconds = 1.0
    /// A hint shows once per episode of its situation (#129): it shows again only after its trigger has been off this
    /// long. The steering hint shows once per race.
    var rearmSeconds = 5.0

    static let standard = HintTuning()
}

/// Lenient: a field missing from a saved tuning takes its standard value, as `BoatStyle`'s.
nonisolated extension HintTuning {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fields: [(CodingKeys, WritableKeyPath<HintTuning, Double>)] = [
            (.lettingGoSeconds, \.lettingGoSeconds), (.lettingGoFirstRaceSeconds, \.lettingGoFirstRaceSeconds),
            (.shiftDegrees, \.shiftDegrees), (.shiftSmoothingSeconds, \.shiftSmoothingSeconds),
            (.noGoSeconds, \.noGoSeconds), (.shadowDeadband, \.shadowDeadband), (.shadowSeconds, \.shadowSeconds),
            (.puffHulls, \.puffHulls), (.laylineHulls, \.laylineHulls), (.glowIntensity, \.glowIntensity),
            (.startSequenceLatestSeconds, \.startSequenceLatestSeconds),
            (.grooveTickRacingSeconds, \.grooveTickRacingSeconds), (.steerRudderShare, \.steerRudderShare),
            (.steerSeconds, \.steerSeconds), (.autohelmHoldSeconds, \.autohelmHoldSeconds),
            (.rearmSeconds, \.rearmSeconds),
        ]
        var tuning = HintTuning.standard
        for (key, path) in fields {
            if let value = try c.decodeIfPresent(Double.self, forKey: key) { tuning[keyPath: path] = value }
        }
        self = tuning
    }
}

/// What the hints' triggers read (#23: "a trigger on public sim state"): your boat in the driver's frame (online, the
/// prediction) and what this race has seen of it so far, worked out once per evaluation. A value, so a test builds one
/// by hand; nothing in it reaches the race.
struct HintSnapshot: Equatable {
    var status = BoatStatus.prestart
    /// Race clock, seconds: negative before the gun.
    var raceTime = 0.0
    var isGhost = false
    /// Tacking, gybing or turning a penalty.
    var inManoeuvre = false
    /// How long you've been inside the no-go zone, racing, seconds.
    var noGoSeconds = 0.0
    /// How far the smoothed fleet-wide wind has turned since your start, degrees; nil before it or with no wind yet.
    var shiftDegrees: Double?
    /// The nearest visible puff whose edge is within the tuning's hull lengths: its centre.
    var nearPuff: Vec2?
    /// How long your wind has been shadowed, seconds, and the nearest boat to windward that may shadow it.
    var shadowSeconds = 0.0
    var shadowSource: Int?
    /// The nearest point of one of your drawn laylines, when you're close to it.
    var nearLayline: Vec2?
    /// The boat with the strongest clearly showing red / green glow.
    var redGlow: Int?
    var greenGlow: Int?
    /// The mark whose zone you're in, racing.
    var markZone: Vec2?
    /// How long you've held the rudder off centre without a break (the autohelm not holding) since the gun, seconds.
    var steeringSeconds = 0.0
    /// Your first race (#134): letting go shows earlier.
    var isFirstRace = false
    /// You've let the autohelm hold after steering, this race.
    var hasLetGo = false
    var racingSeconds = 0.0
    /// Your vane and its groove tick are drawn.
    var vaneShows = false
    /// The letting-go hint is done on this device: the groove-tick hint follows it.
    var lettingGoRetired = false
    /// The race's class's autohelm holds a centred rudder (`holdsWhenCentred`, #434). Off, she steers by hand: a
    /// centred rudder sails straight on, so the centred-rudder hint shows in place of letting go (#436).
    var autohelmHolds = true
}

/// The catalogue's triggers: pure functions of a snapshot and the tuning.
enum HintTriggers {
    static func raceStart(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        s.isGhost ? nil : HintFiring(leader: nil)
    }

    static func startSequence(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        s.status == .prestart && s.raceTime <= -t.startSequenceLatestSeconds ? HintFiring(leader: nil) : nil
    }

    static func noGo(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        s.status == .racing && !s.inManoeuvre && s.noGoSeconds >= t.noGoSeconds ? HintFiring(leader: .vane) : nil
    }

    static func markZone(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing else { return nil }
        return s.markZone.map { HintFiring(leader: .point($0)) }
    }

    static func redGlow(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing else { return nil }
        return s.redGlow.map { HintFiring(leader: .boat($0)) }
    }

    static func greenGlow(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing else { return nil }
        return s.greenGlow.map { HintFiring(leader: .boat($0)) }
    }

    /// After the gun (started or still behind the line): you've steered `hold` seconds without a break. Only once
    /// it's relevant (owner ruling 2026-10-05): a player who never steers never sees it.
    /// Only while the class's autohelm holds a centred rudder: off, the centred-rudder hint says what letting go does.
    static func lettingGo(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.autohelmHolds else { return nil }
        return afterSteering(s, t)
    }

    /// Letting go's place when the class's autohelm doesn't hold (#436): when a centred rudder sails straight on, on
    /// the same timing, once a race (`HintEngine.oncePerRace`) and retired once shown.
    static func centredRudder(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        s.autohelmHolds ? nil : afterSteering(s, t)
    }

    private static func afterSteering(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        let hold = s.isFirstRace ? t.lettingGoFirstRaceSeconds : t.lettingGoSeconds
        guard s.raceTime >= 0, s.status != .finished, !s.isGhost, !s.hasLetGo else { return nil }
        return s.steeringSeconds >= hold ? HintFiring(leader: .vane) : nil
    }

    /// Racing with the vane drawn: after a minute's racing, or sooner once you've let go and the letting-go hint is
    /// done. Sparse: it shows once a race at most, twice in all.
    static func grooveTick(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing, s.vaneShows,
              s.racingSeconds >= t.grooveTickRacingSeconds || (s.lettingGoRetired && s.hasLetGo) else { return nil }
        return HintFiring(leader: .vane)
    }

    static func windShift(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing, let shift = s.shiftDegrees, shift > t.shiftDegrees else { return nil }
        return HintFiring(leader: .vane)
    }

    static func puff(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing, !s.isGhost, let centre = s.nearPuff else { return nil }
        return HintFiring(leader: .point(centre))
    }

    static func windShadow(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing, !s.isGhost, s.shadowSeconds >= t.shadowSeconds else { return nil }
        return HintFiring(leader: s.shadowSource.map { .boat($0) })
    }

    static func layline(_ s: HintSnapshot, _ t: HintTuning) -> HintFiring? {
        guard s.status == .racing, let point = s.nearLayline else { return nil }
        return HintFiring(leader: .point(point))
    }
}

/// What one race has seen of your boat, for the hints (#129): dwell times and what you've done, kept by race time
/// from the frames the session refreshes on, never by display frame. Online, the prediction's frames.
struct HintObservations: Equatable {
    private(set) var lastTick: Int?
    private(set) var portSteerSeconds = 0.0
    private(set) var starboardSteerSeconds = 0.0
    private(set) var noGoSeconds = 0.0
    private(set) var shadowSeconds = 0.0
    private(set) var steeringSeconds = 0.0
    private(set) var autohelmSeconds = 0.0
    private(set) var hasSteered = false
    private(set) var hasLetGo = false
    private(set) var racingSeconds = 0.0
    /// The fleet-wide wind smoothed, as a unit vector towards where it blows from; and its direction at your start.
    private(set) var smoothedWind: Vec2?
    private(set) var referenceWind: Double?
    private(set) var wasRacing = false
    /// You've started (the gun, or clearing an OCS) and the reference wind waits for a tick with wind (online, the
    /// wind may come after the start).
    private var wantsReference = false

    /// You've held the rudder each way.
    func steeredBothWays(_ t: HintTuning) -> Bool {
        portSteerSeconds >= t.steerSeconds && starboardSteerSeconds >= t.steerSeconds
    }

    /// How far the smoothed wind has turned since your start, degrees.
    var shiftDegrees: Double? {
        guard let smoothedWind, let referenceWind else { return nil }
        return abs(rad2deg(wrapAngle(atan2(smoothedWind.x, smoothedWind.y) - referenceWind)))
    }

    /// A groove snap (`RaceEvent.grooveSnap`) for you: you've let go.
    mutating func noteGrooveSnap() {
        hasLetGo = true
    }

    /// Hints are off: nothing is observed meanwhile, and the next tick seen after they're back adds no time, so no
    /// long gap lands in the dwell counters or the wind smoothing.
    mutating func pause() {
        lastTick = nil
    }

    /// Takes `world`'s latest tick. A tick already seen adds nothing; one before it (an online re-prediction) starts
    /// the clock again from there.
    mutating func observe(_ world: RenderWorld, tuning t: HintTuning) {
        let frame = world.frame
        let dt = lastTick.map { max(0, Double(frame.tick - $0)) / Double(Race.tickRate) } ?? 0
        if let lastTick, frame.tick == lastTick { return }
        lastTick = frame.tick
        let seat = world.myBoatIndex
        guard frame.boats.indices.contains(seat) else { return }
        let me = frame.boats[seat]
        let racing = me.status == .racing

        let rudder = frame.heldInputs.indices.contains(seat) ? frame.heldInputs[seat].rudderValue : 0
        if rudder <= -t.steerRudderShare { portSteerSeconds += dt }
        if rudder >= t.steerRudderShare { starboardSteerSeconds += dt }

        // Steering is a held rudder past the autohelm's dead band, as `Race` lets go of it: a boat with no autohelm
        // yet (the first frame, before the race's first step) and a centred rudder hasn't steered.
        let steering = abs(rudder) > Autohelm.deadBand && me.autohelm == nil && !me.isGhost
        if steering { hasSteered = true }
        let afterGun = frame.time >= 0 && !me.isGhost
        steeringSeconds = steering && afterGun ? steeringSeconds + dt : 0
        if me.autohelm != nil {
            autohelmSeconds += dt
            if hasSteered && autohelmSeconds >= t.autohelmHoldSeconds { hasLetGo = true }
        } else {
            autohelmSeconds = 0
        }

        let noGo = me.twa < BoatDynamics.noGoAngle(world.boatClass.polar)
        noGoSeconds = racing && noGo && !me.isTacking && !me.isTakingPenalty ? noGoSeconds + dt : 0
        shadowSeconds = me.shadow < 1 - t.shadowDeadband && !me.isGhost ? shadowSeconds + dt : 0
        if racing { racingSeconds += dt }

        if let wind = world.courseWind {
            let v = Vec2.heading(wind.direction)
            if let smoothed = smoothedWind {
                let k = t.shiftSmoothingSeconds > 0 ? 1 - exp(-dt / t.shiftSmoothingSeconds) : 1
                let mixed = smoothed + (v - smoothed) * k
                smoothedWind = mixed.length > 1e-9 ? mixed / mixed.length : v
            } else {
                smoothedWind = v
            }
        }
        // The reference is the smoothed wind as you start (the gun, or as you clear an OCS and start), or on the first
        // racing tick after that with a wind.
        if racing && !wasRacing { wantsReference = true }
        if !racing { wantsReference = false }
        if wantsReference, let s = smoothedWind, world.courseWind != nil {
            referenceWind = atan2(s.x, s.y)
            wantsReference = false
        }
        wasRacing = racing
    }
}

extension HintSnapshot {
    /// The water's ripple tone: a puff any fainter than it isn't visible (`WaterStyle.rippleAlpha`, "fainter than any
    /// visible puff or lull").
    nonisolated static let visiblePuffDelta = abs(WaterTone.rippleDelta(style: .standard))

    /// `world` from your seat, with what `observations` has seen this race.
    init(world: RenderWorld, observations o: HintObservations, showsLaylines: Bool, isFirstRace: Bool,
         lettingGoRetired: Bool, tuning t: HintTuning) {
        let seat = world.myBoatIndex
        let me = world.me
        let hull = world.boatClass.hull.length
        let ghost = world.isGhost(ofSeat: seat)
        status = me.status
        raceTime = world.time
        isGhost = ghost
        inManoeuvre = me.isTacking || me.isTakingPenalty || me.roll != nil
        noGoSeconds = o.noGoSeconds
        shiftDegrees = o.shiftDegrees
        shadowSeconds = o.shadowSeconds
        steeringSeconds = o.steeringSeconds
        self.isFirstRace = isFirstRace
        hasLetGo = o.hasLetGo
        racingSeconds = o.racingSeconds
        self.lettingGoRetired = lettingGoRetired
        autohelmHolds = world.boatClass.steering.autohelm.holdsWhenCentred
        guard !ghost else { return }
        vaneShows = VaneCue(me, reading: world.autohelm(ofSeat: seat), isGhost: ghost, boatClass: world.boatClass) != nil

        nearPuff = Self.nearPuff(world.puffs, to: me.position, within: t.puffHulls * hull)
        if o.shadowSeconds > 0 {
            shadowSource = Self.nearestToWindward(of: seat, in: world, within: BoatStyle.standard.glowRangeHulls * hull)
        }
        if showsLaylines, me.status == .racing {
            let leg = world.course.legSailed(status: me.status, legIndex: me.legIndex)
            let lines = LaylineCue.segments(for: leg, in: world.course, polar: world.boatClass.polar,
                                            wind: world.groundWind(at:))
            nearLayline = Self.nearestPoint(on: lines, to: me.position, within: t.laylineHulls * hull)
        }
        let glows = GlowSelection.glows(keepClear: world.frame.keepClear, positions: world.boats.map(\.position),
                                        me: seat, isGhost: ghost, rangeHulls: BoatStyle.standard.glowRangeHulls,
                                        fullHulls: BoatStyle.standard.glowFullHulls, hullLength: hull)
        redGlow = Self.strongest(.giveWay, in: glows, atLeast: t.glowIntensity)
        greenGlow = Self.strongest(.hasRight, in: glows, atLeast: t.glowIntensity)
        if let zone = world.course.markZone(of: me, hull: me.hull(outline: world.boatClass.hull.outline)), zone.isIn {
            markZone = zone.mark.position
        }
    }

    /// The centre of the nearest puff (more wind, not a lull) visible on the water whose edge is within `reach` of
    /// `p`, metres.
    static func nearPuff(_ puffs: [Puff], to p: Vec2, within reach: Double) -> Vec2? {
        var best: (centre: Vec2, gap: Double)?
        for puff in puffs where puff.intensity > 0 {
            guard abs(WaterTone.puffDelta(intensity: puff.intensity, style: .standard)) > visiblePuffDelta else { continue }
            let gap = (puff.center - p).length - puff.radius
            if gap <= reach, best.map({ gap < $0.gap }) ?? true { best = (puff.center, gap) }
        }
        return best?.centre
    }

    /// The nearest point of `lines` to `p`, if one is within `reach`.
    static func nearestPoint(on lines: [(from: Vec2, to: Vec2)], to p: Vec2, within reach: Double) -> Vec2? {
        var best: (point: Vec2, distance: Double)?
        for line in lines {
            let d = line.to - line.from
            let l2 = d.lengthSquared
            let s = l2 > 0 ? min(1, max(0, (p - line.from).dot(d) / l2)) : 0
            let q = line.from + d * s
            let distance = (q - p).length
            if distance <= reach, best.map({ distance < $0.distance }) ?? true { best = (q, distance) }
        }
        return best?.point
    }

    /// The seat with the strongest `kind` glow at least `minimum` strong.
    static func strongest(_ kind: RightOfWayGlyph, in glows: [RightOfWayGlow?], atLeast minimum: Double) -> Int? {
        var best: (seat: Int, intensity: Double)?
        for (seat, glow) in glows.enumerated() {
            guard let glow, glow.kind == kind, glow.intensity >= minimum else { continue }
            if best.map({ glow.intensity > $0.intensity }) ?? true { best = (seat, glow.intensity) }
        }
        return best?.seat
    }

    /// The nearest other boat on the water to windward of `seat` (in her wind), within `reach` metres.
    static func nearestToWindward(of seat: Int, in world: RenderWorld, within reach: Double) -> Int? {
        let me = world.boats[seat]
        let up = Vec2.heading(me.windOverGround.direction)
        var best: (seat: Int, distance: Double)?
        for (other, boat) in world.boats.enumerated() where other != seat && !world.isGhost(ofSeat: other) {
            let offset = boat.position - me.position
            let distance = offset.length
            guard offset.dot(up) > 0, distance <= reach else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (other, distance) }
        }
        return best?.seat
    }
}
