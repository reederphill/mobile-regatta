import RegattaCore

// "Avoid a boat that clearly isn't keeping clear" (#537): the right-of-way side of a bot's conduct. Holding her course
// (#228, `holdingCourse`) keeps her rudder centred rather than take room from a boat that must keep clear of her; that
// boat may not be able to keep clear at all. A boat stopped below the line, or one sailing straight on into her, is
// "clearly not keeping clear" (`notKeepingClear`: stopped, or not responding, rule 14), and once contact with her,
// hull to hull (`hullGap`), is inside the escape horizon on the courses both are sailing, the bot turns away from her: the least turn that passes her clear, never towards any boat
// (`avoidingContact`). Nothing changes before that trigger: no lane is given up early, no slowing, no keeping station
// ("no orderly bots"), and a turn away from a boat that had no escape is no 16.1 foul on the bot.
//
// Before the gun the turn keeps her start (#541): against a port boat she luffs to hold, as close as her start luff
// goes, rather than bear away to pass, and no turn or centred hold of hers carries her over the line early at her own
// sheeting (`crossesEarly`). Racing, the least turn, as #537 has it.
//
// Racing and before her start, for every live bot and the cautious bot. The suite's hunter avoids so only before her
// start: racing, her hunting stays as #355 has it (#537 Q1, placeholder). Internal: nothing shows it.
extension BotBrain {
    /// Why a boat that must keep clear of her is clearly not keeping clear (`notKeepingClear`, #537). The definition
    /// #531's roll-out reuses: `.cannot` is its "can't" state (a stopped boat doesn't react), `.isNot` its "won't".
    enum NotKeepingClear: Hashable, Sendable {
        /// Under `stoppedShare` of her close-hauled-or-better polar speed: she can't get out of the way.
        case cannot
        /// Sailing on, she isn't turning away: going on as she has been turning, she still comes inside the contact
        /// distance within the horizon.
        case isNot
    }

    /// Seconds ahead she looks for contact with a boat not keeping clear (`notKeepingClear`): the rules' escape horizon
    /// (`RulesConfig.Escape.horizon`, 2 s), mirrored here because a bot never reads the rules' umpire (#537 Q3,
    /// placeholder).
    static let avoidHorizon = 2.0
    /// The share of her polar speed under which a boat is stopped, `.cannot` (#537: "under 30% of polar").
    static let stoppedShare = 0.3
    /// Seconds between the moments she weighs a turning boat's track at (`notKeepingClear`).
    static let avoidStep = 0.1
    /// Metres a second, the least a boat closes on her at to be coming into her (`notKeepingClear`): one alongside,
    /// holding her distance, isn't.
    static let closingSpeed = 0.2

    /// Notes every boat as she sees it now, for `notKeepingClear` at her next decision (#537): every bot's, kept apart
    /// from the cautious bot's `seen` so nothing of hers moves.
    /// The memory keeps `memorySeconds` of sightings by seat (#531's measured motion, `measuredMotion`); the last is her
    /// last decision's.
    mutating func glimpse(_ view: SeatView) {
        for other in view.others {
            if other.seat >= glimpsed.count { glimpsed += Array(repeating: [], count: other.seat + 1 - glimpsed.count) }
            var sightings = glimpsed[other.seat]
            sightings.append(Glimpse(time: view.time, position: other.position, heading: other.heading, speed: other.speed))
            if let kept = sightings.firstIndex(where: { view.time - $0.time <= Self.memorySeconds + 1e-9 }), kept > 0 {
                sightings.removeFirst(kept)
            }
            glimpsed[other.seat] = sightings
        }
    }

    /// The rate `other` has been turning at since her last decision, radians a second (positive to starboard), clamped
    /// to `guardTurnRate`: 0 at a first sighting (`glimpsed`).
    func observedTurnRate(of other: SeatView.OtherBoat, _ view: SeatView) -> Double {
        guard other.seat < glimpsed.count, let last = glimpsed[other.seat].last, view.time > last.time else { return 0 }
        return (wrapAngle(other.heading - last.heading) / (view.time - last.time))
            .clamped(to: -Self.guardTurnRate...Self.guardTurnRate)
    }

    /// Metres, as a share of the class's beam, the gap between two hulls under which they count as in contact
    /// (`hullGap`, #537 fix round 2: "hull geometry with a small margin", placeholder).
    static let contactMarginBeams = 0.5
    /// Metres a second squared: the least rate a boat's own change of course or speed opens the distance to her at
    /// for her to be responding (`notKeepingClear`, #537 fix round 2, placeholder): one being luffed and dropping
    /// astern, or turning away, is keeping clear.
    static let respondingRate = 0.3
    /// The hull-to-hull gap, as a share of the beam, a turn away passes her at to be clear (`avoidingContact`, #537
    /// fix round 2, placeholder): twice `contactMarginBeams`.
    static let clearMarginBeams = 1.0
    /// Radians between the headings of her bow's swing through a tack or gybe that `tapMeetsBoatNotKeepingClear`
    /// weighs (#537 fix round 2).
    static let sweepStep = deg2rad(10)

    /// The gap between two hulls of the class, metres (negative overlapping), `offset` apart centre to centre, the
    /// other heading `otherHeading` and hers `heading`: each hull a capsule its length fore and aft and its beam abeam
    /// (#537 fix round 2: the contact distance is the hull's, not a circle's). Hull to hull, a boat nearly alongside at
    /// four beams is a long way off; bow to stern, a hull length apart is touching.
    static func hullGap(offset: Vec2, heading: Double, otherHeading: Double, hull: BoatClass.Hull) -> Double {
        let half = max(hull.length - hull.beam, 0) / 2
        let own = Segment(Vec2.heading(heading) * -half, Vec2.heading(heading) * half)
        let theirs = Segment(offset - Vec2.heading(otherHeading) * half, offset + Vec2.heading(otherHeading) * half)
        if Collision.intersects(own, theirs) { return -hull.beam }
        let distance = [
            (Collision.closestPoint(on: own, to: theirs.a) - theirs.a).length,
            (Collision.closestPoint(on: own, to: theirs.b) - theirs.b).length,
            (Collision.closestPoint(on: theirs, to: own.a) - own.a).length,
            (Collision.closestPoint(on: theirs, to: own.b) - own.b).length,
        ].min() ?? .infinity
        return distance - hull.beam
    }

    /// The gap under which two hulls are in contact (`hullGap`): `contactMarginBeams` of the beam.
    static func contactGap(_ hull: BoatClass.Hull) -> Double { hull.beam * contactMarginBeams }

    /// Whether `other` is clearly not keeping clear of her (#537), and why; nil when she is keeping clear, or needn't.
    /// Rule 14's test: a right-of-way boat need not act until it is clear the other is not keeping clear, so the trigger
    /// is "stopped, or not responding". `other` is a boat that must keep clear of her (rules 10–13, or 21:
    /// `OtherBoat.rightOfWay`), not a ghost, closing on her, and on the courses both sail now (`heading`, hers, by
    /// default her current one) her hull comes within `contactGap` of hers inside `avoidHorizon` (`hullGap`); and then
    /// either `.cannot`, under `stoppedShare` of the polar's speed at her wind angle or close-hauled, whichever is the
    /// faster (a boat stalled head to wind reads a polar of nothing there), or `.isNot`: not responding (her own change
    /// of course or speed since her last decision opens the distance at under `respondingRate`: a boat being luffed and
    /// dropping astern responds, whichever bot luffs her), and still coming that close going on turning as she has been
    /// (`observedTurnRate`): a boat already bearing away to duck her isn't in it. Her wind angle is read in this boat's
    /// wind: a stated approximation, as a seat sees no other boat's wind.
    func notKeepingClear(_ other: SeatView.OtherBoat, _ b: SeatView.OwnBoat, _ view: SeatView,
                         heading: Double? = nil) -> NotKeepingClear? {
        guard !other.isGhost, other.rightOfWay?.keepClear == other.seat else { return nil }
        let hull = view.boatClass.hull
        let contact = Self.contactGap(hull)
        let heading = heading ?? b.heading
        let horizon = Self.avoidHorizon
        let offset = other.position - b.position
        // Closing on her: a boat sailing alongside, overlapped and holding her distance, is keeping clear.
        let closing = -offset.dot(other.velocity - Vec2.heading(heading) * b.speed) / max(offset.length, 1e-6)
        guard offset.length < hull.length + contact + (b.speed + other.speed) * horizon, closing > Self.closingSpeed,
              Self.pass(of: track(of: other, view, turning: false), b, heading: heading, hull: hull) < contact
        else { return nil }
        let polar = view.boatClass.polar
        let twa = abs(wrapAngle(b.windDirection - other.heading))
        let reference = polar.speed(twa: max(twa, BoatDynamics.noGoAngle(polar) + deg2rad(5)), tws: b.polarWindSpeed)
        if other.speed < Self.stoppedShare * reference { return .cannot }
        guard !isResponding(other, view) else { return nil }
        return Self.pass(of: track(of: other, view), b, heading: heading, hull: hull) < contact ? .isNot : nil
    }

    /// Whether `other` is responding to her (`notKeepingClear`): her own change of velocity since her last decision
    /// (`glimpsed`) opens the distance between them at `respondingRate` or more. Turning away, or slowing to drop
    /// astern, she is keeping clear. Unknown at a first sighting: no.
    func isResponding(_ other: SeatView.OtherBoat, _ view: SeatView) -> Bool {
        guard other.seat < glimpsed.count, let last = glimpsed[other.seat].last, view.time > last.time else { return false }
        let away = (other.position - view.own.position).normalized
        let change = other.velocity - Vec2.heading(last.heading) * last.speed
        return change.dot(away) / (view.time - last.time) >= Self.respondingRate
    }

    /// Where `other` is and her heading every `avoidStep` seconds over `avoidHorizon`, now first, going on at her speed
    /// turning as she has been (`observedTurnRate`), or in a straight line unless `turning`.
    func track(of other: SeatView.OtherBoat, _ view: SeatView, turning: Bool = true) -> [(position: Vec2, heading: Double)] {
        let rate = turning ? observedTurnRate(of: other, view) : 0
        var position = other.position, heading = other.heading
        var track = [(position, heading)]
        for _ in 0..<Int((Self.avoidHorizon / Self.avoidStep).rounded()) {
            heading = wrapAngle(heading + rate * Self.avoidStep)
            position = position + Vec2.heading(heading) * other.speed * Self.avoidStep
            track.append((position, heading))
        }
        return track
    }

    /// The closest a boat sailing `track` (`track(of:)`) comes to her sailing `heading` at her speed, metres between
    /// centres.
    static func approach(track: [(position: Vec2, heading: Double)], _ b: SeatView.OwnBoat, heading: Double) -> Double {
        let step = Vec2.heading(heading) * b.speed * avoidStep
        return track.indices.map { (track[$0].position - (b.position + step * Double($0))).length }.min() ?? .infinity
    }

    /// The least gap between her hull and the hull of a boat sailing `track`, she sailing `heading` at her speed
    /// (`hullGap`), metres.
    static func pass(of track: [(position: Vec2, heading: Double)], _ b: SeatView.OwnBoat, heading: Double,
                     hull: BoatClass.Hull) -> Double {
        let step = Vec2.heading(heading) * b.speed * avoidStep
        return track.indices.map {
            hullGap(offset: track[$0].position - (b.position + step * Double($0)), heading: heading,
                    otherHeading: track[$0].heading, hull: hull)
        }.min() ?? .infinity
    }

    /// What an avoidance was (#541): a turn up towards the wind, a turn down away from it, or her heading held with the
    /// rudder centred. Report-only: the suite counts them before the gun (`BotDriver`); nothing reads it in play.
    enum AvoidTurn: Hashable, Sendable {
        case luff, bearAway, hold
    }

    /// `avoidingContact`'s input, and what the suite counts of it (#541, report-only).
    struct Avoidance: Hashable, Sendable {
        /// Her input avoiding the boat; nil when there is nothing to avoid, or nothing she may do passes her better.
        var input: BoatInput?
        /// What `input` is: nil with no input.
        var turn: AvoidTurn?
        /// The heading she turns to, or holds; nil with no input.
        var heading: Double?
        /// Radians off her heading of the heading she turns to; 0 holding.
        var turnSize = 0.0
        /// Whether, before the gun, she gave up a rudder-centred hold that would have carried her over the line early
        /// (`crossesEarly`, #541 build 2).
        var refusedEarlyHold = false
        /// Whether, before the gun, refused a centred hold as early for a boat on her plan's heading and finding no turn
        /// away that clears, she held centred all the same (#541 fix round 3): her plan's turn was towards that boat.
        var heldEarly = false
        /// Whether, before the gun, tripping on her heading a boat that can't keep clear (`.cannot`) and finding no
        /// heading that clears and isn't early, she luffed early all the same: the least luff that clears (#541 fix
        /// round 4, owner: "Relax the veto").
        var earlyLuff = false
        /// Whether the heading is the one that passes furthest, no turn clearing her.
        var furthest = false
        /// Whether, before the gun, the luff preference chose it (#541 Q3, Q4): a clearing luff taken over a bear-away
        /// that also cleared.
        var preferredLuff = false
    }

    /// Her input avoiding a boat clearly not keeping clear of her (#537), or nil when there is none, or no turn she may
    /// make passes her better than holding on (`avoidance`).
    func avoidingContact(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> BoatInput? {
        avoidance(b, view, input, desired: desired).input
    }

    /// Avoiding a boat clearly not keeping clear of her (#537). The nearest boat that trips `notKeepingClear` on her
    /// heading (one that trips it only on `desired`, she holds her heading for, rudder centred, so once turned clear she
    /// doesn't turn back into her): the least turn off her heading, in `clearingStep`s, that brings that boat's pass
    /// over `avoidHorizon` to `clearMarginBeams` of the beam hull to hull (`hullGap`), both in a straight line and going
    /// on turning as she has been (`track(of:)`); looked for first the way away from the side she passes on, then the
    /// other; failing that, the turn that passes her furthest. Each way only while every degree of it opens both passes
    /// between centres (`closestApproach`, `approach`), so no part of the turn is towards her (#101's invariant). Only on
    /// her own tack, out of the no-go zone and never by the lee (tacks and gybes are the tap's). Never a heading that
    /// brings any other boat closer than holding on would, inside `roomLengths` within `roomLookahead` (`turnsTowards`);
    /// or that `avoidMarks` or `avoidEdges` would turn her off. Holding on already clear of her, she holds: the rudder
    /// centred. Her ease is `input`'s. Not while she owes a turn.
    ///
    /// Before the gun she keeps her start (#541): against a port boat (rule 10) she luffs to hold rather than bear
    /// away to pass whenever a luff clears, however much bigger a turn, as close as `startLuffFloor` (her start luff's
    /// floor, under her hold angle); bearing away she may start from her own angle inside the racing floor. No heading
    /// whose straight line, at her own sheeting, carries her over the line within `luffLineSeconds` (`crossesEarly`): she
    /// would swing through it, so it ends that way's search. Nor a centred hold that would: clear on her heading but
    /// early, she looks for a turn as above (nil if none clears); and so, holding for a boat only on `desired`, she
    /// looks for a turn away from that boat (fix round 2: leaving the helm to her plan was its turn towards her), and
    /// with none clearing holds centred all the same when that hold doesn't pass her clear (`heldEarly`, fix rounds 3
    /// and 4). Tripping on her heading a boat that
    /// can't keep clear (`.cannot`), with no heading that clears and isn't early, she takes the least luff that clears
    /// even though early (`earlyLuff`, fix round 4).
    /// Racing, as #537 has it.
    func avoidance(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> Avoidance {
        // Owing a turn, her clearing for it and her wait are the penalty's (#471, #486), which weigh every boat near.
        guard avoidsContact, b.status == .racing || b.status == .prestart, b.penalty == nil else { return Avoidance() }
        let preGun = b.status == .prestart && view.time < 0
        // Before the gun (#541): sailing `heading` at her own sheeting carries her over the line early.
        func early(_ heading: Double) -> Bool {
            preGun && crossesEarly(b, view, heading: heading, within: Self.luffLineSeconds, ease: input.ease)
        }
        let centred = BoatInput(rudder: 0 as Int8, ease: input.ease)
        func trips(_ other: SeatView.OtherBoat, heading: Double? = nil) -> Bool {
            notKeepingClear(other, b, view, heading: heading) != nil
        }
        func nearer(_ one: SeatView.OtherBoat, _ two: SeatView.OtherBoat) -> Bool {
            (one.position - b.position).lengthSquared < (two.position - b.position).lengthSquared
        }
        let other: SeatView.OtherBoat
        // Before the gun, a centred hold for a boat on her plan's heading refused as early (#541 fix round 2).
        var onPlanRefused = false
        if let tripping = view.others.filter({ trips($0) }).min(by: nearer) {
            other = tripping
        } else {
            // Clear of every such boat on her heading but not on the one her plan sails: she holds her heading, the
            // rudder centred, rather than turn into her (#537 fix round 1: a turn away here, from a boat no threat on
            // her course, was a manoeuvre the autohelm and her hands sailed apart).
            // Only a boat that can't keep clear (`.cannot`) counts on a heading she hasn't sailed yet: whether a sailing
            // boat responds to a turn of hers can't be known before she turns (rule 14, #537 fix round 2).
            guard let onPlan = view.others.filter({ notKeepingClear($0, b, view, heading: desired) == .cannot })
                .min(by: nearer)
            else { return Avoidance() }
            guard early(b.heading) else { return Avoidance(input: centred, turn: .hold, heading: b.heading) }
            // Before the gun, not a hold that carries her over early (#541 Q5), nor the helm left to her plan, whose
            // turn onto `desired` is towards the stopped boat (#541 fix round 2: guard over note): she looks for a
            // turn away from that boat as below, nil only if none clears.
            other = onPlan
            onPlanRefused = true
        }
        // Her pass both ways it may be reckoned: sailing on in a straight line (#101's invariant, every bot's reckoning
        // of room), and going on turning as she has been (a boat turning across her bow moves the closest point).
        // A turn away opens both.
        // Whether a turn opens her pass is weighed between centres; how clear it passes her, hull to hull (`hullGap`).
        let theirs = track(of: other, view)
        let straightOn = track(of: other, view, turning: false)
        let hull = view.boatClass.hull
        let horizon = Self.avoidHorizon
        func passes(_ heading: Double) -> (straight: Double, turning: Double, gap: Double) {
            (Self.closestApproach(of: other, to: b, heading: heading, lookahead: horizon),
             Self.approach(track: theirs, b, heading: heading),
             min(Self.pass(of: straightOn, b, heading: heading, hull: hull),
                 Self.pass(of: theirs, b, heading: heading, hull: hull)))
        }
        let held = passes(b.heading)
        let clear = hull.beam * Self.clearMarginBeams
        // Clear holding on, she holds; before the gun, not on a heading that carries her over early (#541 Q5): then
        // only a turn that clears her and isn't early.
        let refusedEarlyHold = onPlanRefused || held.gap >= clear && early(b.heading)
        if held.gap >= clear && !refusedEarlyHold { return Avoidance(input: centred, turn: .hold, heading: b.heading) }
        // Away from the side she passes on, where she is at their closest (for a stalled boat, the side she is on);
        // dead on, the side she is on now, and failing that, bearing away.
        let offset = other.position - b.position
        let right = b.forward.rightPerp
        let relative = other.velocity - b.velocity
        let vv = relative.lengthSquared
        let t = vv > 1e-6 ? (-offset.dot(relative) / vv).clamped(to: 0...horizon) : 0
        let passing = (offset + relative * t).dot(right)
        let sideways = abs(passing) > 1e-3 ? passing : offset.dot(right)
        let side: Double = b.tack == .port ? 1 : -1 // heading = wind + side × angle
        let bearAway: Double = side // a turn to starboard (+) bears a port-tack boat away
        let luff = -bearAway
        let away: Double = abs(sideways) > 1e-6 ? (sideways > 0 ? -1 : 1) : bearAway
        let closest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5)
        // Before the gun (#541 Q2): luffing, as close as her start luff goes (`startLuffFloor`), under her hold angle;
        // bearing away, from her own angle, inside the racing floor when she holds there.
        let ownAngle = wrapAngle(b.heading - b.windDirection) * side
        func floor(_ way: Double) -> Double {
            guard preGun else { return closest }
            return way == luff ? Self.startLuffFloor(view) : min(closest, ownAngle)
        }
        func isSailable(_ heading: Double, _ way: Double) -> Bool {
            let angle = wrapAngle(heading - b.windDirection) * side
            return angle >= floor(way) && angle <= .pi
        }
        func isAllowed(_ heading: Double, early: Bool = true) -> Bool {
            !turnsTowards(b, view, heading: heading, except: other.seat)
                && avoidMarks(b, view, desired: heading) == nil && avoidEdges(b, view, desired: heading) == nil
                && !(early && crossesEarly(b, view, heading: heading, within: Self.luffLineSeconds))
        }
        var furthest: (heading: Double, distance: Double)?
        var best: (heading: Double, turn: Int)?
        var bestLuff: (heading: Double, turn: Int)?
        // Weighed every degree, so every bit of the turn opens the pass: past where it closes again she would be turning
        // towards her. Turns are taken in `clearingStep`s.
        let fine = deg2rad(1)
        let every = Int((Self.clearingStep / fine).rounded())
        for way in [away, -away] {
            var last = held
            for degree in 1...180 {
                let heading = b.heading + way * Double(degree) * fine
                guard isSailable(heading, way) else { break }
                let pass = passes(heading)
                guard pass.straight > last.straight, pass.turning >= last.turning else { break }
                last = pass
                let distance = pass.gap
                guard degree % every == 0 else { continue }
                let step = degree / every
                // Before the gun, a heading that carries her over early at her own sheeting ends the way: she would
                // swing through it (#541 build 2).
                if early(heading) { break }
                guard isAllowed(heading) else { continue }
                if distance >= clear {
                    if step < best?.turn ?? .max { best = (heading, step) }
                    if way == luff { bestLuff = (heading, step) }
                    break
                }
                if distance > furthest?.distance ?? held.gap { furthest = (heading, distance) }
            }
        }
        // The least luff that clears her, the early veto lifted (#541 fix round 4): the luff way's search above
        // without `early`.
        func clearingLuff() -> Double? {
            var last = held
            for degree in 1...180 {
                let heading = b.heading + luff * Double(degree) * fine
                guard isSailable(heading, luff) else { break }
                let pass = passes(heading)
                guard pass.straight > last.straight, pass.turning >= last.turning else { break }
                last = pass
                guard degree % every == 0, isAllowed(heading, early: false) else { continue }
                if pass.gap >= clear { return heading }
            }
            return nil
        }
        // Before the gun, against a port boat, any luff that clears her (#541 Q3, Q4): rules 12 and 13 keep the least
        // turn (a luff away from a boat astern can make her the windward boat).
        let prefersLuff = preGun && other.rightOfWay?.rule == .portStarboard
        let chosen = (prefersLuff ? bestLuff : nil) ?? best
        // The least clearing turn was the bear-away way's: the preference made the pick (report-only).
        let preferredLuff = prefersLuff && bestLuff != nil && best.map { $0.heading != bestLuff?.heading } == true
        // Before the gun, tripping on her heading a boat that can't keep clear (`.cannot`), with no heading that clears
        // and isn't early: the least luff that clears her, early or not, over the furthest pass (#541 fix round 4, owner:
        // "Relax the veto": a contact ranks worse than an early cross she may still correct). Every degree of it still
        // opens both passes, sailable, and allowed (no boat brought closer, marks and edges).
        if preGun, chosen == nil, !onPlanRefused, notKeepingClear(other, b, view) == .cannot,
           let luffed = clearingLuff() {
            let steered = steer(b, toHeading: luffed, view, closest: Self.startLuffFloor(view))
            return Avoidance(input: BoatInput(rudder: steered.rudder, ease: input.ease), turn: .luff, heading: luffed,
                             turnSize: abs(wrapAngle(luffed - b.heading)), refusedEarlyHold: refusedEarlyHold,
                             earlyLuff: true)
        }
        guard let heading = chosen?.heading ?? furthest?.heading else {
            // Before the gun, holding for a boat only on her plan's heading, no turn away: she holds centred, early,
            // rather than leave the helm to the plan, whose turn is onto that stopped boat (#541 fix round 3: a contact
            // ranks worse than an early cross she may still correct, #542's costs over vetoes). Not when she trips on
            // her heading: there the plan's helm isn't known to be a turn onto her.
            // Not a hold that passes her clear (fix round 4: case (b)'s water, where the plan's helm keeps her clear and
            // behind the line, and a held-early hold carried her over): only one that doesn't, s10's.
            if onPlanRefused && held.gap < clear {
                return Avoidance(input: centred, turn: .hold, heading: b.heading, refusedEarlyHold: true, heldEarly: true)
            }
            return Avoidance(refusedEarlyHold: refusedEarlyHold)
        }
        // Her helm goes as close as the search did (#541 Q2: `steer`'s own floor is the racing one).
        let steered = steer(b, toHeading: heading, view, closest: preGun ? Self.startLuffFloor(view) : nil)
        let turned = wrapAngle(heading - b.heading)
        return Avoidance(input: BoatInput(rudder: steered.rudder, ease: input.ease),
                         turn: turned * bearAway < 0 ? .luff : .bearAway, heading: heading, turnSize: abs(turned),
                         refusedEarlyHold: refusedEarlyHold, furthest: chosen == nil, preferredLuff: preferredLuff)
    }

    /// Whether a tack or gybe begun now would be a turn with a boat clearly not keeping clear of her inside the horizon
    /// (#537): one that trips `notKeepingClear` on her heading, or on the tap's heading on the other tack. A turn by
    /// hand sweeps her bow through the wind towards the water to windward, where `tapIsClear`'s straight line onto the
    /// new heading doesn't look (a bot that had borne away from a stalled boat tacked by hand back into her, before her
    /// start); she avoids her first, and turns once clear. Not for the suite's hunter racing (#537 Q1).
    func tapMeetsBoatNotKeepingClear(_ b: SeatView.OwnBoat, _ view: SeatView) -> Bool {
        guard avoidsContact, b.status == .racing || b.status == .prestart, b.penalty == nil,
              !(tactics.hunts && b.status == .racing)
        else { return false }
        // The tap's heading is looked on only for a boat on the side her bow sweeps through (one on the other side she
        // turns away from), and not for a starboard boat when she tacks off starboard onto port: on the new tack she
        // keeps clear of that one, and `tapIsClear` weighs her so (#537 fix round 1: today's rights on the new heading
        // had her hold her lane on a header beside any boat to windward on her tack).
        // Every `sweepStep` of her bow's swing to it, too: with the contact the hull's (`hullGap`), the headings
        // between hers and the tap's, through the wind, are where her bow meets a boat stalled to windward (#537 fix
        // round 2).
        let mirrored = 2 * b.windDirection - b.heading
        let sweep = wrapAngle(mirrored - b.heading)
        let steps = max(Int((abs(sweep) / Self.sweepStep).rounded(.up)), 1)
        let swing = (1...steps).map { b.heading + sweep * Double($0) / Double(steps) }
        return view.others.contains { other in
            let swept = (other.position - b.position).dot(b.forward.rightPerp) * sweep > 0
            let givesWay = b.tack == .starboard && other.tack == .starboard
            // On the headings of the turn, only a boat that can't keep clear (`.cannot`): a sailing one's response to
            // the turn can't be known before it, and `tapIsClear` weighs her.
            return notKeepingClear(other, b, view) != nil
                || swept && !givesWay && swing.contains { notKeepingClear(other, b, view, heading: $0) == .cannot }
        }
    }

    /// Whether sailing `heading` brings a boat other than seat `except` closer to her than holding her course would, at
    /// a moment within `roomLookahead` seconds when that boat is inside `roomLengths` hull lengths of her: every
    /// non-ghost boat, whatever the rules give either (#537: "never toward any boat"), both sailing on in straight lines.
    /// `turnsTowardsKeepClearBoat`'s reckoning, for one heading.
    func turnsTowards(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, except: Int) -> Bool {
        let clear = view.boatClass.hull.length * roomLengths
        let lookahead = roomLookahead
        let turned = Vec2.heading(heading) * b.speed
        let holding = b.velocity
        for other in view.others where !other.isGhost && other.seat != except {
            let offset = other.position - b.position
            guard offset.length < clear + (b.speed + other.speed) * lookahead else { continue }
            for t in stride(from: Self.roomStep, through: lookahead, by: Self.roomStep) {
                let held = (offset + (other.velocity - holding) * t).length
                let near = (offset + (other.velocity - turned) * t).length
                if near < clear && near < held { return true }
            }
        }
        return false
    }
}
