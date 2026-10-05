import RegattaCore

/// The start (#99): from wherever the start row (#35) or a takeover left her, to her spot on the line as the
/// gun goes.
///
/// Her style picks the spot (`BotStyle.startSpot`), and she starts there if she can reach it in the time left
/// (`reachableSpot`). She approaches it on starboard, from below and to the right of it: sheets let out, she
/// holds with Ease on the way, at the class's eased fraction of her polar speed, then sheets in for the run in.
/// She never waits inside the no-go zone: letting go there hands her to the autohelm, which bears her away to
/// the groove (ADR 0007, #219), and holding her there stalls her in irons. So she holds just outside it
/// (`holdMargin`), where she sails slowest, steering to the angle and centring the rudder like any other (#231).
///
/// Each decision she times the run from her class's polar, her speed and the wind at her (`secondsToLine`):
/// sheeted in once sailing at her spot at full speed would bring her bow to the line only as the gun goes
/// (`startArrival`); with Ease while that would be early and holding isn't; and while even holding would be
/// early, she bears away with Ease and lets the time run (`wait`). A spot she can't fetch on starboard she sails
/// round to first (`approachPoint`). Nothing is remembered between decisions, so she starts the same way from any
/// pre-gun state.
extension BotBrain {
    /// How far outside the no-go zone she holds with Ease: the slowest she sails with the sail drawing.
    static let holdMargin = deg2rad(3)
    /// Her aim's tolerance on the approach: the course to her spot moves as she sails it.
    static let approachTolerance = deg2rad(3)
    /// On starboard, how far inside her hold angle her spot may bear and she keeps to her approach: she fetches
    /// the line to leeward of it, rather than go round again.
    static let fetchMargin = deg2rad(25)
    /// On port, how far outside her hold angle her spot must bear for her to join her approach.
    static let joinMargin = deg2rad(12)
    /// Her setup point is where her spot bears this much further outside her hold angle again.
    static let setupMargin = deg2rad(5)
    /// Seconds after the gun she means her bow to reach the line, before her style's `timingSlack`: late
    /// rather than over.
    static let startLead = 0.6
    /// The earliest she ever means to reach it, however early her style: never before the gun.
    static let earliestLead = 0.2
    /// Seconds of hysteresis on sheeting in: once going, she lets the sheets out again only this early.
    static let goHysteresis = 0.6
    /// Seconds of run in to the line she reckons clear of traffic; beyond them she allows `trafficAllowance`
    /// seconds more for each second: a long run in crosses the boats holding nearer the line, and their wind.
    static let clearRunSeconds = 4.0
    static let trafficAllowance = 0.6
    /// Seconds a tack onto starboard takes her, on port, before she can sail at her spot.
    static let tackSeconds = 4.0
    /// Waiting along the line, how far away from it past parallel she sails.
    static let waitOffLine = deg2rad(5)
    /// Waiting deeper, her sailing angle: nearly dead downwind, so she reaches along the line far less for each
    /// second she waits, and the way back up takes the time too.
    static let deepWaitAngle = deg2rad(170)
    /// Seconds early from which she waits deeper, rather than along the line.
    static let deepWaitEarly = 1.5
    /// Metres to the right of the line she holds along to her spot she must be to wait deeper: the way back up
    /// takes her towards it.
    static let deepWaitMargin = 2.0
    /// Metres to the right of that line beyond which, waiting, she reaches along the start line towards her
    /// spot rather than deeper: across to it before the fleet gathers below the line.
    static let farFromApproach = 15.0
    /// Hull lengths of race area she leaves below her holding or waiting deeper (#82): room to turn back up.
    static let holdRoom = 4.0
    /// Seconds from her arrival after which she no longer sails round to her setup point for room to wait.
    static let repositionSeconds = 25.0
    /// Her speed reaching across to her spot's approach on port, as a share of her polar's on a beam reach:
    /// the turns and the fleet cost her the rest.
    static let positioningSpeed = 0.6
    /// Seconds more than her run in and two tacks she leaves herself, once she's reached across, for the start.
    static let positioningMargin = 10.0
    /// Seconds she allows for sailing to her setup point.
    static let setupSeconds = 10.0
    /// Metres within which another boat is one she may have to keep clear of before her start.
    static let keepClearRange = 30.0
    /// Hull lengths, centre to centre, she keeps from a boat she must keep clear of before her start.
    static let keepClearDistance = 1.3
    /// How much further than that a heading must pass it to keep her clear.
    static let keepClearMargin = 1.2
    /// The headings she weighs keeping clear before her start: her hold angle to this, every `keepClearStep`.
    static let keepClearDeepest = deg2rad(170)
    static let keepClearStep = deg2rad(10)
    /// Running back below the line, OCS, the deepest she sails: short of dead downwind, so she doesn't gybe.
    static let returnAngle = deg2rad(165)
    /// Seconds ahead she reckons her run at most: past this she's early by any reckoning.
    static let timingHorizon = 60.0
    /// The time step of her reckoning, seconds.
    static let timingStep = 0.1

    /// Her spot on the start line, from her style: 0 the pin, 1 the committee boat.
    /// She sets up for it as she reads the line (#102): her line-bias misread (`BotWeaknesses.lineBiasMisread`) has
    /// her reckon one end favoured when it isn't, and she moves her spot that way along the line, by
    /// `lineBiasShift` of it for each degree of misread: away from the spot her style chose, into the crowd at
    /// the end she wrongly favours.
    ///
    /// The tactician (#105, `Tactics.startsAtFavouredEnd`) sets up at the spot she reads the line's bias to favour
    /// instead (`favouredEndSpot`, `readLineBias`), once she has read it.
    func startPoint(_ c: CourseLayout) -> Vec2 {
        let line = c.startLine
        if let favouredEndSpot {
            return line.pin.position + (line.committee.position - line.pin.position) * favouredEndSpot
        }
        let misread = weaknesses.lineBiasMisread * style.lineBiasDraw
        let spot = min(max(style.startSpot + Self.lineBiasShift * rad2deg(misread), 0.05), 0.95)
        return line.pin.position + (line.committee.position - line.pin.position) * (misread == 0 ? style.startSpot : spot)
    }

    /// The share of the line she moves her spot for each degree she misreads its bias by.
    static let lineBiasShift = 0.04

    /// "Start at the favoured end" (#105, the tactician's, `Tactics.startsAtFavouredEnd`): she reads the start line's bias
    /// and moves her spot towards the end it favours, this share of the line for each degree of bias: the live bots'
    /// misread (`lineBiasShift`) the right way round, read off the wind rather than drawn. Internal, never shown to a
    /// player (#122: there is no line-bias cue). A tunable for #389.
    static let favouredEndShift = 0.04
    /// The nearest to either end she sets up, as a share of the line: off the mark.
    static let favouredEndInset = 0.05

    /// The tactician reads the start line's bias (#105) before the gun: the line's angle off square to the wind she sees,
    /// smoothed (`Senses.direction`), the committee end favoured when it lies up the wind. Her spot (`favouredEndSpot`) is
    /// her style's (`BotStyle.startSpot`) moved towards the favoured end by `favouredEndShift` a degree. After the gun the
    /// spot she last read stands.
    mutating func readLineBias(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard tactics.startsAtFavouredEnd, view.time < 0 else { return }
        let line = view.course.startLine
        let along = (line.committee.position - line.pin.position).normalized
        // The sine of the bias, about the angle in radians: positive when the committee end lies up the wind of square.
        let bias = along.dot(Vec2.heading(senses.direction ?? b.windDirection))
        favouredEndSpot = min(max(style.startSpot + Self.favouredEndShift * rad2deg(bias), Self.favouredEndInset),
                              1 - Self.favouredEndInset)
    }

    /// Her hold angle: `holdMargin` outside the no-go zone.
    static func holdAngle(_ view: SeatView) -> Double {
        BoatDynamics.noGoAngle(view.boatClass.polar) + holdMargin
    }

    /// Seconds from now her bow should reach the start line: `startLead` after the gun, and her style's
    /// `timingSlack` (her start risk) later still, as far as her start timing error shows it
    /// (`BotWeaknesses.startTiming`); never before the gun.
    func startArrival(_ view: SeatView) -> Double {
        -view.time + max(Self.earliestLead, Self.startLead + style.timingSlack * weaknesses.startTiming)
    }

    /// Before her start: before the gun, or after it and not started yet.
    mutating func startAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        readLineBias(b, view)
        let line = view.course.startLine
        // After the gun, back below the line running (she was OCS) or bearing away, she heads up on her own tack
        // first, as turning for the other one from a run is a gybe; on port if starboard would take her past the
        // pin end. Only level with the line between its ends: beyond an end, heading up on port sails her away
        // from the line and back over its extension, and she would run down and head up again for ever (#298,
        // seed 7 of `aBotTakingOverBeforeTheGunStarts`); there she sails in behind the line (`lateStartAim`).
        if view.time >= 0, sailingAngle(b) > .pi / 2, line.side(b.position) < 0,
           nearestOnLine(b.position, line, clearOfEnds: view.boatClass.hull.length).between {
            let tack = landingRoom(b, view, hold: Self.holdAngle(view)) > 0 ? b.tack : .port
            setTack(tack, view)
            return .groove(.upwind, tack: tack, angle: grooveAngle(.upwind, b, view))
        }
        let hold = Self.holdAngle(view)
        let arrival = startArrival(view)
        let spot = reachableSpot(b, view, hold: hold, arrival: arrival)
        // Where her spot bears, as a sailing angle on starboard, and the broadest she can sail and still cross
        // the line itself, clear of the pin end. Set up where she is (`isSetUpWhereSheIs`), her spot's bearing is
        // clamped to the range the checks below read as fetched and not yet passed: from `hold - fetchMargin` (on
        // starboard, the least `joins` takes) to `.pi / 2 + waitOffLine` (the broadest the guard keeps); on port,
        // `joins` holds there anyway, since with under a tack's time left the time is short. So she holds, waits or
        // goes from there rather than sailing round to her setup point (`toSetup`).
        let bearing = wrapAngle(b.windDirection - (spot - b.position).bearing)
        let toSpot = isSetUpWhereSheIs(b, view, arrival: arrival)
            ? min(max(bearing, hold - Self.fetchMargin), .pi / 2 + Self.waitOffLine) : bearing
        let pinEnd = line.pin.position + (line.committee.position - line.pin.position).normalized * view.boatClass.hull.length
        let toPin = wrapAngle(b.windDirection - (pinEnd - b.position).bearing)
        // Sheeted in at her spot, or close-hauled if it bears closer to the wind than that.
        let go = Aim(angle: max(min(max(toSpot, grooveAngle(.upwind, b, view)), toPin), hold), tack: .starboard,
                     tolerance: Self.approachTolerance)
        // On starboard she keeps to her approach while she lands on the line, however far below her spot. On port,
        // she joins it once to the right of the line she holds along to it, or once time is short.
        let joins = b.tack == .starboard
            ? toSpot >= hold - Self.fetchMargin && landingRoom(b, view, hold: hold) > 0
            : toSpot >= hold + Self.joinMargin
                || secondsToLine(b, view, angle: go.angle, ease: false, within: arrival) + Self.tackSeconds >= arrival
        // Over the line before the gun, she runs back below it as an OCS boat would, on her own tack.
        let bow = b.position + b.forward * (view.boatClass.hull.length / 2)
        if line.side(bow) >= 0 && view.time < 0 { return returnAim(b, view) }
        guard line.side(bow) < 0, joins, toSpot <= .pi / 2 + Self.waitOffLine else {
            guard view.time < 0 else { return lateStartAim(b, view) }
            return toSetup(b, view, spot: spot, hold: hold, arrival: arrival)
        }
        // After the gun she's late: on starboard she runs in, on port she crosses as she can rather than tack.
        guard view.time < 0 else { return b.tack == .starboard ? go : lateStartAim(b, view) }
        // Further from the gun than she reckons, she's early by any reckoning.
        guard arrival < Self.timingHorizon else {
            return wait(b, view, spot: spot, hold: hold, early: .infinity, arrival: arrival)
                ?? toSetup(b, view, spot: spot, hold: hold, arrival: arrival)
        }

        let run = secondsToLine(b, view, angle: go.angle, ease: false, within: arrival) + (b.tack == .port ? Self.tackSeconds : 0)
        let needed = run + max(0, run - Self.clearRunSeconds) * Self.trafficAllowance
        let going = b.ease == false && b.tack == .starboard
        if needed >= arrival - (going ? Self.goHysteresis : 0) { return go }
        let holdAim = Aim(angle: max(min(toSpot, toPin), hold), tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        let holding = secondsToLine(b, view, angle: holdAim.angle, ease: true, within: arrival)
        if holding >= arrival { return holdAim }
        return wait(b, view, spot: spot, hold: hold, early: arrival - holding, arrival: arrival)
            ?? toSetup(b, view, spot: spot, hold: hold, arrival: arrival)
    }

    /// Hull lengths below the start line within which, late in the sequence, she is set up where she is
    /// (`isSetUpWhereSheIs`).
    static let setUpDepthLengths = 2.0

    /// Whether, before the gun, she is set up where she is: less time left than a tack takes (`tackSeconds`), too
    /// little to sail round anywhere, close below the line (`setUpDepthLengths`) and level with it between its ends.
    /// Her spot, a length or so off, swings round her as she slides along the line; wherever it bears she reads it as
    /// fetched and not yet passed (`startAim`). Reading it passed, she bore away hard for her setup point with 1.7 s to
    /// the gun and swung her stern over the line (#350, seed 4 of `aBotTakingOverBeforeTheGunStarts`). Beyond an end
    /// she isn't: there she still sails to her setup point.
    func isSetUpWhereSheIs(_ b: SeatView.OwnBoat, _ view: SeatView, arrival: Double) -> Bool {
        let line = view.course.startLine
        return view.time < 0 && arrival < Self.tackSeconds
            && -line.side(b.position) < view.boatClass.hull.length * Self.setUpDepthLengths
            && nearestOnLine(b.position, line, clearOfEnds: 0).between
    }

    /// Sailing to her setup point (`approachPoint`), sheeted in.
    mutating func toSetup(_ b: SeatView.OwnBoat, _ view: SeatView, spot: Vec2, hold: Double, arrival: Double) -> Aim {
        navigate(b, to: approachPoint(b, view, spot: spot, hold: hold, arrival: arrival), view)
    }

    /// Where she starts: her spot (`startPoint`), unless she can't reach across to its approach in the time
    /// left; then as far along towards it as she can, reaching across on port at `positioningSpeed` until she
    /// needs the rest of the time for the run in, two tacks and `positioningMargin`; never within two hull
    /// lengths of the pin.
    func reachableSpot(_ b: SeatView.OwnBoat, _ view: SeatView, hold: Double, arrival: Double) -> Vec2 {
        let c = view.course
        let line = c.startLine
        let spot = startPoint(c)
        guard view.time < 0 else { return spot }
        let direction = (line.committee.position - line.pin.position).normalized
        let joining = Vec2.heading(b.windDirection - hold - Self.joinMargin)
        let depth = max(-line.side(b.position), 0)
        // How far right of her, along the line, her spot's approach passes her depth.
        let across = (spot - joining * (depth / max(joining.dot(c.upwind), 0.3)) - b.position).dot(direction)
        let tws = b.polarWindSpeed
        let polar = view.boatClass.polar
        let reach = polar.speed(twa: .pi / 2, tws: tws) * b.speedShadow * Self.positioningSpeed
        let runIn = depth / max(polar.bestUpwind(tws: tws).vmg * b.speedShadow, 0.3)
        let spare = max(0, arrival - runIn - Self.tackSeconds * 2 - Self.positioningMargin)
        guard across > reach * spare else { return spot }
        let shifted = spot - direction * (across - reach * spare)
        let pinEnd = view.boatClass.hull.length * 2
        return (shifted - line.pin.position).dot(direction) < pinEnd ? line.pin.position + direction * pinEnd : shifted
    }

    /// Too early even holding with Ease, by `early` seconds: she bears away with Ease and lets the time run.
    /// A little to the right of the line she holds along to her spot, with room below her in the race area, she
    /// runs deeper; further right, or without the room, she reaches along the start line, a little away from it,
    /// towards her spot. Either takes her on towards the pin: when reaching along the line for the time she has
    /// to lose would carry her past where she can still fetch the line, and there's time to go round, she
    /// sails round to her setup point instead (nil).
    private func wait(_ b: SeatView.OwnBoat, _ view: SeatView, spot: Vec2, hold: Double, early: Double, arrival: Double) -> Aim? {
        let line = view.course.startLine
        let rightOfHold = (b.position - spot).dot(Vec2.heading(b.windDirection - hold).rightPerp)
        if early > Self.deepWaitEarly, rightOfHold > Self.deepWaitMargin, rightOfHold < Self.farFromApproach,
           maxHoldDepth(view, at: b.position) > -line.side(b.position) {
            return Aim(angle: Self.deepWaitAngle, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
        }
        let slide = wrapAngle(b.windDirection - (line.pin.position - line.committee.position).bearing) + Self.waitOffLine
        if arrival > Self.repositionSeconds, b.tack == .starboard {
            let speed = BoatDynamics.polarTarget(relativeWind: slide, boomSide: .port, tws: b.polarWindSpeed, isPlaning: false,
                                                 spinnaker: .down, boatClass: view.boatClass) * b.speedShadow * view.boatClass.ease.speedFraction
            if min(early, Self.timingHorizon) * speed > landingRoom(b, view, hold: hold) { return nil }
        }
        return Aim(angle: slide, tack: .starboard, tolerance: Self.approachTolerance, ease: true)
    }

    /// Metres along the line, from a hull length in from the pin, to where holding along from where she is
    /// would bring her: negative if it wouldn't bring her to the line clear of the pin end.
    private func landingRoom(_ b: SeatView.OwnBoat, _ view: SeatView, hold: Double) -> Double {
        let line = view.course.startLine
        let course = Vec2.heading(b.windDirection - hold)
        let rate = line.courseSideRate(course)
        guard rate > 0.05 else { return 0 }
        let landing = b.position + course * (-line.side(b.position) / rate)
        return (landing - line.pin.position).dot((line.committee.position - line.pin.position).normalized)
            - view.boatClass.hull.length
    }

    /// How deep below the start line she may hold at `p`: as deep as leaves her `holdRoom` hull lengths of
    /// race area below her (#82). The race area reaches a line's length or so below the line.
    func maxHoldDepth(_ view: SeatView, at p: Vec2) -> Double {
        let c = view.course
        let toBottom = c.raceArea.halfLength + (p - c.raceArea.centre).dot(c.upwind)
        return -c.startLine.side(p) + toBottom - view.boatClass.hull.length * Self.holdRoom
    }

    /// Her setup point, which she sails to sheeted in while she can't fetch her spot on starboard, or needs room
    /// to wait: where her spot bears `joinMargin` and `setupMargin` outside her hold angle, as deep as holding from
    /// there takes the time left but `setupSeconds`, no shallower than she is, and no deeper than the race area
    /// leaves room to hold (`maxHoldDepth`). She joins her approach on the way, with little time to wait in the
    /// crowd.
    private func approachPoint(_ b: SeatView.OwnBoat, _ view: SeatView, spot: Vec2, hold: Double, arrival: Double) -> Vec2 {
        let c = view.course
        let boatClass = view.boatClass
        let length = boatClass.hull.length
        let course = Vec2.heading(b.windDirection - hold - Self.joinMargin - Self.setupMargin)
        let holdCourse = Vec2.heading(b.windDirection - hold)
        let eased = BoatDynamics.polarTarget(relativeWind: hold, boomSide: .port, tws: b.polarWindSpeed, isPlaning: false,
                                             spinnaker: .down, boatClass: boatClass) * b.speedShadow * boatClass.ease.speedFraction
        let scheduled = eased * max(holdCourse.dot(c.upwind), 0.3) * max(0, arrival - Self.setupSeconds)
        let deepest = max(maxHoldDepth(view, at: spot), length * 2)
        let depth = min(max(-c.startLine.side(b.position), scheduled, length * 2), deepest)
        return spot - course * (depth / max(course.dot(c.upwind), 0.3))
    }

    /// Seconds until her bow reaches the start line sailing `angle` on starboard (`secondsToLine(_:_:heading:ease:within:)`).
    func secondsToLine(_ b: SeatView.OwnBoat, _ view: SeatView, angle: Double, ease: Bool, within: Double) -> Double {
        secondsToLine(b, view, heading: b.windDirection - angle, ease: ease, within: within)
    }

    /// Seconds until her bow reaches the start line sailing `heading`, sheeted in or with Ease, from her speed
    /// now: reckoned from her class's polar and momentum, in the wind at her and the current carrying her, a
    /// `timingStep` at a time as the dynamics sail it (`BoatDynamics.advance`). Infinity if not within `within`
    /// seconds and a second more, or if her course never gets there.
    func secondsToLine(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, ease: Bool, within: Double) -> Double {
        let boatClass = view.boatClass
        let line = view.course.startLine
        let course = Vec2.heading(heading)
        let rate = line.courseSideRate(course)
        let drift = line.courseSideRate(b.velocityOverGround - b.velocity)
        guard rate > 0.05 else { return .infinity }
        var depth = -line.side(b.position + course * (boatClass.hull.length / 2))
        guard depth > 0 else { return 0 }
        let relativeWind = wrapAngle(b.windDirection - heading)
        var target = BoatDynamics.polarTarget(relativeWind: relativeWind, boomSide: relativeWind >= 0 ? .port : .starboard,
                                              tws: b.polarWindSpeed, isPlaning: senses.planing, spinnaker: .down,
                                              boatClass: boatClass) * b.speedShadow
        if ease { target *= boatClass.ease.speedFraction }
        let slowing = ease ? boatClass.ease.timeConstant : boatClass.momentum.slowingDown
        let dt = Self.timingStep
        var speed = b.speed
        var t = 0.0
        while t < min(within + 1, Self.timingHorizon) {
            speed += (target - speed) * min(1, dt / (target > speed ? boatClass.momentum.speedingUp : slowing))
            depth -= (speed * rate + drift) * dt
            t += dt
            if depth <= 0 { return t }
        }
        return .infinity
    }

    /// Whether sailing `heading` with Ease would still put her bow over the start line before the gun, or within
    /// `within` seconds if that is sooner.
    func crossesEarly(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, within: Double? = nil) -> Bool {
        guard b.status == .prestart, view.time < 0, view.course.startLine.side(b.position) < 0 else { return false }
        let horizon = min(-view.time, within ?? .infinity)
        return secondsToLine(b, view, heading: heading, ease: true, within: horizon) < horizon
    }

    /// How far outside the no-go zone she luffs at most before her start (#280): inside her hold angle, so a windward
    /// boat holding there still has a luff left.
    static let startLuffMargin = deg2rad(1)
    /// The radians she luffs by at a time, weighing the least luff that keeps her clear (`startLuff`).
    static let startLuffStep = deg2rad(2)
    /// Seconds ahead a windward boat's luff before her start may not carry her over the line, with Ease: a luff is
    /// over in a few seconds, then she bears away to her hold again, so only a luff that reaches the line that soon
    /// leaves her OCS (`keepClear`).
    static let luffLineSeconds = 6.0
    /// Seconds before the gun from which a windward boat luffed to `startLuffFloor` and still not clear no longer eases
    /// to drop astern (`Evasion.dropsAstern`): later, slowed there, she starts late. #280 measured easing to the gun
    /// at on time 0.50 against the start gate's 0.60.
    static let startLuffEaseSeconds = 20.0

    /// The closest to the wind she luffs before her start (`startLuffMargin`).
    static func startLuffFloor(_ view: SeatView) -> Double {
        BoatDynamics.noGoAngle(view.boatClass.polar) + startLuffMargin
    }

    /// Whether `heading` is a windward boat's luff before her start (`startLuff`): inside her hold angle.
    func isStartLuff(_ b: SeatView.OwnBoat, _ view: SeatView, _ heading: Double) -> Bool {
        b.status == .prestart && abs(wrapAngle(heading - b.windDirection)) < Self.holdAngle(view) - 1e-9
    }

    /// Rule 11 before her start (#280): the windward boat luffs, away from the leeward one. The angle she sails, or
    /// `desired` if that is closer to the wind, if it already passes every boat near her `keepClearDistance` times
    /// `keepClearMargin` hull lengths off over `lookahead` seconds (`closestApproach`); else the least luff from there
    /// that does, every `startLuffStep`, down to `startLuffFloor`; failing that, the floor, where she eases and drops
    /// astern (`Evasion.dropsAstern`) while the gun is further off than `startLuffEaseSeconds`. She holds just outside
    /// the no-go zone (#99), so there is little luff left from her hold: never a bear-away, which only turns her
    /// towards the leeward boat. Only this luff steers closer to the wind than `steer`'s usual 5° outside the no-go
    /// zone (`Evasion.closest`).
    func startLuff(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double) -> Evasion {
        let side: Double = b.tack == .port ? 1 : -1
        let floor = Self.startLuffFloor(view)
        let near = view.others.filter { !$0.isGhost && ($0.position - b.position).length < Self.keepClearRange }
        let clear = view.boatClass.hull.length * keepClearLengths * Self.keepClearMargin
        func passes(_ heading: Double) -> Bool {
            let closest = near.map { Self.closestApproach(of: $0, to: b, heading: heading, lookahead: lookahead) }.min()
            return (closest ?? .infinity) >= clear
        }
        var angle = max(floor, min(abs(wrapAngle(desired - b.windDirection)), abs(wrapAngle(b.heading - b.windDirection))))
        while true {
            let heading = b.windDirection + side * angle
            if passes(heading) { return Evasion(heading: heading, closest: floor) }
            guard angle > floor else { break }
            angle = max(floor, angle - Self.startLuffStep)
        }
        return Evasion(heading: b.windDirection + side * floor, closest: floor,
                       dropsAstern: view.time < 0 && -view.time > Self.startLuffEaseSeconds)
    }

    /// Whether she lets the sheets out while she steers `heading` on starboard to keep clear or off a mark
    /// before the gun: when sailing it sheeted in would bring her to the line early. A windward boat luffing
    /// clear of a leeward one near the line drops back rather than luffing over it. OCS, kept from running back
    /// (her heading short of `returnAngle`), she eases and lets the boats she keeps clear of sail on past her
    /// ("Wait, then run back"): holding her speed there only keeps her in their way. Otherwise, on port, she keeps her
    /// speed to keep clear with.
    func easesKeepingClear(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double) -> Bool {
        if b.status == .ocs { return abs(wrapAngle(heading - b.windDirection)) < Self.returnAngle - Self.keepClearStep }
        guard b.status == .prestart, view.time < 0, b.tack == .starboard else { return false }
        let arrival = startArrival(view)
        return secondsToLine(b, view, heading: heading, ease: false, within: arrival) < arrival - Self.goHysteresis
    }

    /// Keeping clear before her start, in the crowd below the line where boats hold, wait and cross on every
    /// course: if her `desired` heading would bring a boat she must keep clear of (rule 21 over rules 10–13,
    /// `OtherBoat.rightOfWay`) within `keepClearDistance` hull lengths over `lookahead` seconds, the heading on
    /// her own tack nearest her desired one that passes it `keepClearMargin` further off, or failing that the
    /// one that passes furthest from it. Before the gun she weighs only headings that keep her below the line
    /// with Ease (`crossesEarly`): keeping clear by luffing over it early would leave her OCS, trapped above the
    /// boats she keeps clear of.
    func startKeepClear(_ b: SeatView.OwnBoat, _ view: SeatView, desired: Double, lookahead: Double) -> Double? {
        // OCS, she keeps clear of every boat as a returning one (rule 21.1), whatever rules 10–13 would give her
        // (`OtherBoat.rightOfWay` has only those): she is returning as soon as she heads back. The cautious bot keeps
        // clear of every boat before her start in any case (#104, `keepsClearOfEveryBoat`).
        let returning = b.status == .ocs || keepsClearOfEveryBoat
        // Not returning, she leaves out a boat she misjudges her encounter with (#280, `judgeEncounters`).
        let threats = view.others.filter { other in
            guard !other.isGhost, (other.position - b.position).length < Self.keepClearRange else { return false }
            if returning { return true }
            guard let right = other.rightOfWay, right.keepClear == view.seat else { return false }
            return !misjudges(other, right.rule)
        }
        guard !threats.isEmpty else { return nil }
        let speed = max(b.speed, 1)
        func closest(_ heading: Double) -> Double {
            let velocity = Vec2.heading(heading) * speed
            return threats.map { other in
                let offset = other.position - b.position
                let relative = other.velocity - velocity
                let vv = relative.lengthSquared
                let t = vv > 1e-6 ? (-offset.dot(relative) / vv).clamped(to: 0...lookahead) : 0
                return (offset + relative * t).length
            }.min() ?? .infinity
        }
        let clear = view.boatClass.hull.length * keepClearLengths
        guard closest(desired) < clear else { return nil }
        let hold = Self.holdAngle(view)
        let side: Double = b.tack == .starboard ? -1 : 1
        var nearest: (heading: Double, turn: Double)?
        var furthest: (heading: Double, distance: Double)?
        for step in 0...Int((Self.keepClearDeepest - hold) / Self.keepClearStep) {
            let heading = b.windDirection + side * (hold + Double(step) * Self.keepClearStep)
            if crossesEarly(b, view, heading: heading) { continue }
            // The cautious bot never turns towards a boat keeping clear of her to keep clear of another (#104).
            if caution != nil, abs(wrapAngle(heading - b.heading)) > deg2rad(2),
               turnsTowardsKeepClearBoat(b, view, turn: wrapAngle(heading - b.heading) > 0 ? 1 : -1) { continue }
            let distance = closest(heading)
            let turn = abs(wrapAngle(heading - desired))
            if distance >= clear * Self.keepClearMargin, turn < nearest?.turn ?? .infinity { nearest = (heading, turn) }
            if distance > furthest?.distance ?? -1 { furthest = (heading, distance) }
        }
        return nearest?.heading ?? furthest?.heading
    }

    /// After the gun, not yet started, and not at her spot's approach: she starts wherever she can. A boat
    /// starts only by crossing the line itself from the pre-start side, so one on the course side (she went
    /// past an end of the line) sails back below it as an OCS boat does, and one below it but beyond an end
    /// first sails in behind the line; otherwise she would loiter past the line, or keep hitting the end mark,
    /// and never start. Below the line between its ends, she sails up through it close-hauled, on her own tack
    /// if that crosses the line between its ends, or the other if that does.
    private mutating func lateStartAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        let c = view.course
        let line = c.startLine
        let clearOfEnds = view.boatClass.hull.length
        if line.side(b.position) > 0 { return returnAim(b, view) }
        let across = nearestOnLine(b.position, line, clearOfEnds: clearOfEnds)
        if !across.between { return navigate(b, to: across.point - c.upwind * clearOfEnds, view) }
        let groove = grooveAngle(.upwind, b, view)
        for tack in [b.tack, b.tack == .starboard ? Tack.port : .starboard] where crossesLine(b, view, angle: groove, tack: tack) {
            setTack(tack, view)
            return .groove(.upwind, tack: tack, angle: groove)
        }
        return navigate(b, to: across.point + c.upwind * 20, view)
    }

    /// Whether sailing `angle` on `tack` from where she is would take her across the start line between its
    /// ends, a hull length in from each.
    private func crossesLine(_ b: SeatView.OwnBoat, _ view: SeatView, angle: Double, tack: Tack) -> Bool {
        let line = view.course.startLine
        let course = Vec2.heading(tack == .starboard ? b.windDirection - angle : b.windDirection + angle)
        let rate = line.courseSideRate(course)
        guard rate > 0.05 else { return false }
        let landing = b.position + course * (-line.side(b.position) / rate)
        let along = (landing - line.pin.position).dot((line.committee.position - line.pin.position).normalized)
        let clearOfEnds = view.boatClass.hull.length
        return along > clearOfEnds && along < line.length - clearOfEnds
    }

    /// OCS (#85): back below the line, whole hull, by the shortest way: she bears away and runs down across it
    /// (or its extension) on her own tack, short of a gybe, keeping clear of the boats starting as rule 21.1 has
    /// her (`startKeepClear`: a returning boat keeps clear of every boat that isn't). Then she starts again
    /// (`startAim`).
    mutating func returnAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        plannedTack = b.tack
        return Aim(angle: Self.returnAngle, tack: b.tack, tolerance: Self.approachTolerance)
    }

    /// The point of `line` nearest `p`, at least `clearOfEnds` metres in from either end, and whether `p` is
    /// level with the line between those points.
    private func nearestOnLine(_ p: Vec2, _ line: CourseLayout.Line, clearOfEnds: Double) -> (point: Vec2, between: Bool) {
        let direction = (line.committee.position - line.pin.position).normalized
        let along = (p - line.pin.position).dot(direction)
        let inner = clearOfEnds...max(clearOfEnds, line.length - clearOfEnds)
        return (line.pin.position + direction * along.clamped(to: inner), inner.contains(along))
    }
}

