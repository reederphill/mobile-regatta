import RegattaCore

// "Avoid a boat that clearly isn't keeping clear" (#537): the right-of-way side of a bot's conduct. Holding her course
// (#228, `holdingCourse`) keeps her rudder centred rather than take room from a boat that must keep clear of her; that
// boat may not be able to keep clear at all. A boat stopped below the line, or one sailing straight on into her, is
// "clearly not keeping clear" (`notKeepingClear`: stopped, or not responding, rule 14), and once contact with her,
// hull to hull (`hullGap`), is inside the escape horizon on the courses both are sailing, the bot turns away from her: the least turn that passes her clear, never towards any boat
// (`avoidingContact`). Nothing changes before that trigger: no lane is given up early, no slowing, no keeping station
// ("no orderly bots"), and a turn away from a boat that had no escape is no 16.1 foul on the bot.
//
// Racing and before her start, for every live bot and the cautious bot; the suite's hunter only before her start
// (#537 Q1, placeholder: racing, her hunting stays as #355 has it). Internal: nothing shows it.
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
    mutating func glimpse(_ view: SeatView) {
        for other in view.others {
            if other.seat >= glimpsed.count { glimpsed += Array(repeating: nil, count: other.seat + 1 - glimpsed.count) }
            glimpsed[other.seat] = Seen(time: view.time, heading: other.heading, speed: other.speed)
        }
    }

    /// The rate `other` has been turning at since her last decision, radians a second (positive to starboard), clamped
    /// to `guardTurnRate`: 0 at a first sighting (`glimpsed`).
    func observedTurnRate(of other: SeatView.OtherBoat, _ view: SeatView) -> Double {
        guard other.seat < glimpsed.count, let last = glimpsed[other.seat], view.time > last.time else { return 0 }
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
        guard other.seat < glimpsed.count, let last = glimpsed[other.seat], view.time > last.time else { return false }
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

    /// Her input avoiding a boat clearly not keeping clear of her (#537), or nil when there is none, or no turn she may
    /// make passes her better than holding on. The nearest boat that trips `notKeepingClear` on her heading (one that
    /// trips it only on `desired`, she holds her heading for, rudder centred, so once turned clear she doesn't turn back
    /// into her): the least turn off her heading, in `clearingStep`s, that brings that boat's pass over `avoidHorizon`
    /// to `clearMarginBeams` of the beam hull to hull (`hullGap`), both in a straight line and going on turning as she
    /// has been (`track(of:)`); looked for first the way away from the side she passes on, then the other; failing
    /// that, the turn that passes her furthest. Each way only while every degree of it opens both passes between
    /// centres (`closestApproach`, `approach`), so no part of the turn is towards her (#101's invariant). Only on her
    /// own tack, out of the no-go zone and never by the lee (tacks and gybes are the tap's). Never a heading that brings
    /// any other boat closer than holding on would, inside `roomLengths` within `roomLookahead` (`turnsTowards`); that
    /// `avoidMarks` or `avoidEdges` would turn her off; or, before the gun, that would carry her over the line within
    /// `luffLineSeconds` (`crossesEarly`). Holding on already clear of her, she holds: the rudder centred. Her ease is
    /// `input`'s. Not while she owes a turn.
    func avoidingContact(_ b: SeatView.OwnBoat, _ view: SeatView, _ input: BoatInput, desired: Double) -> BoatInput? {
        // Owing a turn, her clearing for it and her wait are the penalty's (#471, #486), which weigh every boat near.
        guard avoidsContact, b.status == .racing || b.status == .prestart, b.penalty == nil else { return nil }
        func trips(_ other: SeatView.OtherBoat, heading: Double? = nil) -> Bool {
            notKeepingClear(other, b, view, heading: heading) != nil
        }
        guard let other = view.others.filter({ trips($0) }).min(by: {
            ($0.position - b.position).lengthSquared < ($1.position - b.position).lengthSquared
        }) else {
            // Clear of every such boat on her heading but not on the one her plan sails: she holds her heading, the
            // rudder centred, rather than turn into her (#537 fix round 1: a turn away here, from a boat no threat on
            // her course, was a manoeuvre the autohelm and her hands sailed apart).
            // Only a boat that can't keep clear (`.cannot`) counts on a heading she hasn't sailed yet: whether a sailing
            // boat responds to a turn of hers can't be known before she turns (rule 14, #537 fix round 2).
            guard view.others.contains(where: { notKeepingClear($0, b, view, heading: desired) == .cannot })
            else { return nil }
            return BoatInput(rudder: 0 as Int8, ease: input.ease)
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
        if held.gap >= clear { return BoatInput(rudder: 0 as Int8, ease: input.ease) }
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
        let away: Double = abs(sideways) > 1e-6 ? (sideways > 0 ? -1 : 1) : bearAway
        let closest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(5)
        func isSailable(_ heading: Double) -> Bool {
            let angle = wrapAngle(heading - b.windDirection) * side
            return angle >= closest && angle <= .pi
        }
        func isAllowed(_ heading: Double) -> Bool {
            !turnsTowards(b, view, heading: heading, except: other.seat)
                && avoidMarks(b, view, desired: heading) == nil && avoidEdges(b, view, desired: heading) == nil
                && !crossesEarly(b, view, heading: heading, within: Self.luffLineSeconds)
        }
        var furthest: (heading: Double, distance: Double)?
        var best: (heading: Double, turn: Int)?
        // Weighed every degree, so every bit of the turn opens the pass: past where it closes again she would be turning
        // towards her. Turns are taken in `clearingStep`s.
        let fine = deg2rad(1)
        let every = Int((Self.clearingStep / fine).rounded())
        for way in [away, -away] {
            var last = held
            for degree in 1...180 {
                let heading = b.heading + way * Double(degree) * fine
                guard isSailable(heading) else { break }
                let pass = passes(heading)
                guard pass.straight > last.straight, pass.turning >= last.turning else { break }
                last = pass
                let distance = pass.gap
                guard degree % every == 0 else { continue }
                let step = degree / every
                guard isAllowed(heading) else { continue }
                if distance >= clear {
                    if step < best?.turn ?? .max { best = (heading, step) }
                    break
                }
                if distance > furthest?.distance ?? held.gap { furthest = (heading, distance) }
            }
        }
        guard let heading = best?.heading ?? furthest?.heading else { return nil }
        let steered = steer(b, toHeading: heading, view)
        return BoatInput(rudder: steered.rudder, ease: input.ease)
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
