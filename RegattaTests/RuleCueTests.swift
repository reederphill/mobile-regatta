import Foundation
import RegattaCore
import Testing
import UIKit
@testable import Regatta

/// #123 acceptance: the penalty arc and Turn notice (`PenaltyReadout`), the rule-call lines (`RuleCallLines`), the
/// glows' range and fade (`GlowSelection`) and the live penalty notice (`NoticeSlot.setLive`).
@MainActor @Suite struct RuleCueTests {
    typealias Marks = PenaltyReadout.TurnMarks

    /// A turn whose clock started at tick `clock`, under start/complete windows of `start`/`complete` seconds.
    static func owed(clock: Int = 300, start: Double, complete: Double, turns: Int = 1, started: Bool = false) -> OwedPenalty {
        OwedPenalty(turnsOwed: turns, startDeadlineTick: clock + Int(start) * Race.tickRate,
                    completeDeadlineTick: clock + Int(complete) * Race.tickRate, progress: started ? 1 : 0,
                    isStarted: started)
    }

    /// The arc is what's left of the start deadline over the start window, whatever the rules say it is: 15 s
    /// (#9's) and 20 s (fleet-rules@5's) both read from the data.
    @Test(arguments: [(15.0, 30.0), (20.0, 40.0)])
    func arcFractionIsStartDeadlineRemainingOverTheStartWindow(start: Double, complete: Double) {
        let owed = Self.owed(start: start, complete: complete)
        for elapsed in [0.0, 4, 10, start - 1] {
            let tick = 300 + Int(elapsed) * Race.tickRate
            let readout = PenaltyReadout(owed: owed, tick: tick, startSeconds: start, completeSeconds: complete)
            #expect(readout.phase == .start)
            #expect(abs(readout.arcFraction - (start - elapsed) / start) < 1e-9, "\(start) s, \(elapsed) s in")
        }
        let late = PenaltyReadout(owed: owed, tick: 300 + Int(start + 2) * Race.tickRate, startSeconds: start,
                                  completeSeconds: complete)
        #expect(late.arcFraction == 0)

        // Once started, the arc counts the complete deadline over its window.
        let started = Self.owed(start: start, complete: complete, started: true)
        let turning = PenaltyReadout(owed: started, tick: 300 + 10 * Race.tickRate, startSeconds: start,
                                     completeSeconds: complete)
        #expect(turning.phase == .complete)
        #expect(abs(turning.arcFraction - (complete - 10) / complete) < 1e-9)
    }

    @Test func noticeTextFormat() {
        // 15 s / 30 s windows, 4 s after the call: #15's example.
        let owed = Self.owed(start: 15, complete: 30)
        let readout = PenaltyReadout(owed: owed, tick: 300 + 4 * Race.tickRate, startSeconds: 15, completeSeconds: 30)
        #expect(readout.noticeText == "Turn · 11s / 26s")
        // Whole seconds rounded up: a tick past 4 s still shows 11 s.
        let tickLater = PenaltyReadout(owed: owed, tick: 300 + 4 * Race.tickRate + 1, startSeconds: 15, completeSeconds: 30)
        #expect(tickLater.noticeText == "Turn · 11s / 26s")
        // Started: only the complete countdown.
        let started = PenaltyReadout(owed: Self.owed(start: 20, complete: 40, started: true), tick: 300 + 14 * Race.tickRate,
                                     startSeconds: 20, completeSeconds: 40)
        #expect(started.noticeText == "Turn · 26s")
        // Several owed.
        let two = PenaltyReadout(owed: Self.owed(start: 20, complete: 40, turns: 2), tick: 300, startSeconds: 20,
                                 completeSeconds: 40)
        #expect(two.noticeText == "Turn · 20s / 40s ×2")
        // Never below zero.
        let past = PenaltyReadout(owed: owed, tick: 300 + 60 * Race.tickRate, startSeconds: 15, completeSeconds: 30)
        #expect(past.noticeText == "Turn · 0s / 0s")
    }

    /// A practice frame carries your keep-clear row and the rules' penalty (the default fleet-rules@7, #517: a tack and
    /// a gybe, one 40 s limit, its start window the complete one); a frame's readout reads them, and none shows for a
    /// seat that owes nothing.
    @Test func practiceFramesCarryKeepClearRowsAndTheRulesPenalty() throws {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let base = driver.currentFrame
        #expect(base.keepClear?.count == base.boats.count)
        #expect(base.keepClear?[driver.myBoatIndex] == nil)
        let penalty = try #require(base.penalty)
        #expect(penalty.turn == .tackAndGybe && penalty.start == 40 && penalty.complete == 40)
        var owed = [OwedPenalty?](repeating: nil, count: base.boats.count)
        owed[0] = Self.tackAndGybe(complete: penalty.complete)
        let frame = TickFrame(tick: 300 + 9 * Race.tickRate, boats: base.boats, standings: base.standings, wind: base.wind,
                              isOver: false, owed: owed, penalty: penalty)
        #expect(PenaltyReadout(frame: frame, seat: 0)?.noticeText == "Turn · 31s")
        #expect(PenaltyReadout(frame: frame, seat: 1) == nil)
        #expect(frame.extrapolatedBackOneTick().owed == owed)
    }

    /// A fleet-rules@6 turn (#487) whose clock started at tick `clock`: one limit, `complete` seconds.
    static func tackAndGybe(clock: Int = 300, complete: Double = 40, turns: Int = 1, tacked: Bool = false,
                            gybed: Bool = false, direction: Int = 0) -> OwedPenalty {
        let deadline = clock + Int(complete) * Race.tickRate
        return OwedPenalty(turnsOwed: turns, startDeadlineTick: deadline, completeDeadlineTick: deadline, progress: 0,
                           isStarted: tacked || gybed, hasTacked: tacked, hasGybed: gybed, direction: direction)
    }

    /// #489: under fleet-rules@6 the arc counts down the one 40 s limit from the call and the Turn notice gives that
    /// one countdown, never a "start by" part; the marks are lit as the tack and the gybe are made, the barbs pointing
    /// the turn's way. A fleet-rules@5 turn has no marks.
    @Test func tackAndGybeReadoutCountsOneLimitWithItsMarks() {
        for elapsed in [0.0, 9, 25, 39] {
            let readout = PenaltyReadout(owed: Self.tackAndGybe(), tick: 300 + Int(elapsed) * Race.tickRate,
                                         startSeconds: 40, completeSeconds: 40, turn: .tackAndGybe)
            #expect(readout.phase == .complete)
            #expect(abs(readout.arcFraction - (40 - elapsed) / 40) < 1e-9, "\(elapsed) s in")
            #expect(readout.marks == Marks(isTackLit: false, isGybeLit: false, direction: 0))
        }
        let nine = PenaltyReadout(owed: Self.tackAndGybe(), tick: 300 + 9 * Race.tickRate, startSeconds: 40,
                                  completeSeconds: 40, turn: .tackAndGybe)
        #expect(nine.noticeText == "Turn · 31s")
        let two = PenaltyReadout(owed: Self.tackAndGybe(turns: 2), tick: 300 + 9 * Race.tickRate, startSeconds: 40,
                                 completeSeconds: 40, turn: .tackAndGybe)
        #expect(two.noticeText == "Turn · 31s ×2")
        let past = PenaltyReadout(owed: Self.tackAndGybe(), tick: 300 + 60 * Race.tickRate, startSeconds: 40,
                                  completeSeconds: 40, turn: .tackAndGybe)
        #expect(past.arcFraction == 0 && past.noticeText == "Turn · 0s")

        // Tacked turning clockwise (to starboard): the tack half lit, its barb clockwise; a recross keeps it lit and
        // turns the barb round; gybed first turning anticlockwise, the gybe half.
        func marks(_ owed: OwedPenalty) -> PenaltyReadout.TurnMarks? {
            PenaltyReadout(owed: owed, tick: 400, startSeconds: 40, completeSeconds: 40, turn: .tackAndGybe).marks
        }
        #expect(marks(Self.tackAndGybe(tacked: true, direction: 1)) == Marks(isTackLit: true, isGybeLit: false, direction: 1))
        #expect(marks(Self.tackAndGybe(tacked: true, direction: -1)) == Marks(isTackLit: true, isGybeLit: false, direction: -1))
        #expect(marks(Self.tackAndGybe(gybed: true, direction: -1)) == Marks(isTackLit: false, isGybeLit: true, direction: -1))

        // Fleet-rules@5: no marks, its two countdowns as before.
        let older = PenaltyReadout(owed: Self.owed(start: 20, complete: 40), tick: 300 + 9 * Race.tickRate,
                                   startSeconds: 20, completeSeconds: 40)
        #expect(older.marks == nil && older.noticeText == "Turn · 11s / 31s")
    }

    /// #489: a served fleet-rules@6 turn lights both marks for half a second of race time, its barbs the served
    /// turn's way (kept from the frames before: the race clears a last turn's way as it serves it), over the next
    /// owed turn's countdown or alone; then the next turn shows both grey, or nothing does. Not under fleet-rules@5.
    @Test func servedTurnFlashesBothMarksForHalfASecond() throws {
        var flash = ServedTurnFlash()
        #expect(!flash.isShowing(at: 0))
        flash.follow(Self.tackAndGybe(tacked: true, direction: -1))
        flash.follow(nil)
        #expect(flash.direction == -1)
        flash.served(at: 1000)
        let window = Int((ServedTurnFlash.seconds * Double(Race.tickRate)).rounded(.up))
        #expect(!flash.isShowing(at: 999))
        #expect(flash.isShowing(at: 1000) && flash.isShowing(at: 1000 + window - 1))
        #expect(!flash.isShowing(at: 1000 + window))

        let driver = PracticeDriver(config: RaceDriverTests.config)
        let base = driver.currentFrame
        var penalty = try #require(base.penalty)
        penalty.turn = .tackAndGybe
        func frame(tick: Int, owed seat0: OwedPenalty?, penalty: RulesConfig.Penalty) -> TickFrame {
            var owed = [OwedPenalty?](repeating: nil, count: base.boats.count)
            owed[0] = seat0
            return TickFrame(tick: tick, boats: base.boats, standings: base.standings, wind: base.wind, isOver: false,
                             owed: owed, penalty: penalty)
        }
        // The last turn served: both lit alone, no countdown, then nothing.
        let alone = try #require(PenaltyReadout(frame: frame(tick: 1005, owed: nil, penalty: penalty), seat: 0, served: flash))
        #expect(alone.marks == Marks(isTackLit: true, isGybeLit: true, direction: -1))
        #expect(alone.arcFraction == 0 && alone.turnsOwed == 0)
        #expect(PenaltyReadout(frame: frame(tick: 1000 + window, owed: nil, penalty: penalty), seat: 0, served: flash) == nil)
        #expect(PenaltyReadout(frame: frame(tick: 1005, owed: nil, penalty: penalty), seat: 0) == nil)
        // Another owed: both lit over its countdown, then both grey.
        let next = Self.tackAndGybe(clock: 1000, direction: -1)
        let flashing = try #require(PenaltyReadout(frame: frame(tick: 1005, owed: next, penalty: penalty), seat: 0,
                                                   served: flash))
        #expect(flashing.marks == Marks(isTackLit: true, isGybeLit: true, direction: -1) && flashing.arcFraction > 0.99)
        let after = try #require(PenaltyReadout(frame: frame(tick: 1000 + window, owed: next, penalty: penalty), seat: 0,
                                                served: flash))
        #expect(after.marks == Marks(isTackLit: false, isGybeLit: false, direction: -1))
        // Fleet-rules@5 has no flash.
        var older = try #require(base.penalty)
        older.turn = .fullCircle
        #expect(PenaltyReadout(frame: frame(tick: 1005, owed: nil, penalty: older), seat: 0, served: flash) == nil)
        #expect(PenaltyReadout(frame: frame(tick: 1005, owed: Self.owed(clock: 1000, start: 20, complete: 40),
                                            penalty: older), seat: 0, served: flash)?.marks == nil)
    }

    private static func call(_ tick: Int, _ rule: RacingRule = .portStarboard, offender: Int = 1, victim: Int = 2) -> RuleCall {
        RuleCall(incidentId: tick, tick: tick, rule: rule, offender: offender, victim: victim, leg: 0, turnsOwed: 1,
                 startDeadlineTick: nil, completeDeadlineTick: nil)
    }

    @Test func ruleCallLinesAreTimedFadeAndCap() {
        var lines = RuleCallLines()
        lines.add(Self.call(0, .changingCourse))
        let at = { (seconds: Double) in lines.active(at: seconds, seconds: 8, fadeSeconds: 1.5) }
        #expect(at(0) == [.init(offender: 1, victim: 2, badge: "16.1", alpha: 1)])
        #expect(at(6.5).first?.alpha == 1)
        #expect(abs((at(7.25).first?.alpha ?? 0) - 0.5) < 1e-9)
        #expect(at(8).isEmpty)
        // A mark touch (no other boat) draws no line.
        lines.add(Self.call(30, .touchingMark, offender: 3, victim: 3))
        #expect(lines.calls.count == 1)
        // A call delivered again (an online resync) is recorded once.
        lines.add(Self.call(0, .changingCourse))
        #expect(lines.calls.count == 1)
        // At most four, the newest first.
        for i in 1...5 { lines.add(Self.call(i * 30, offender: i, victim: i + 1)) }
        let shown = at(6)
        #expect(shown.count == RuleCallLines.maxLines)
        #expect(shown.map(\.offender) == [5, 4, 3, 2])
    }

    @Test func glowsShowWithinRangeAndNotOnlineOrAsAGhost() {
        let positions = [Vec2(0, 0), Vec2(0, 10), Vec2(0, 40), Vec2(5, 0)]
        let relations: [RightOfWay?] = [nil, RightOfWay(keepClear: 1, rule: .portStarboard),
                                        RightOfWay(keepClear: 0, rule: .windwardLeeward), nil]
        func glows(keepClear: [RightOfWay?]? = relations, isGhost: Bool = false, rangeHulls: Double) -> [RightOfWayGlow?] {
            GlowSelection.glows(keepClear: keepClear, positions: positions, me: 0, isGhost: isGhost,
                                rangeHulls: rangeHulls, fullHulls: 1.5, hullLength: 4)
        }
        // Seat 1 is 10 m (2.5 hulls) off, between the range's edge and full; seat 2 is 40 m (10 hulls) off, past a
        // 6-hull range; seat 3 has no relation (a ghost).
        let near = glows(rangeHulls: 6)
        #expect(near.map { $0?.kind } == [nil, .hasRight, nil, nil])
        let partly = near[1]?.intensity ?? 0
        #expect(partly > 0 && partly < 1, "\(partly)")
        let wider = glows(rangeHulls: 12)
        #expect(wider.map { $0?.kind } == [nil, .hasRight, .giveWay, nil])
        #expect((wider[1]?.intensity ?? 0) > partly, "a wider range puts seat 1 further in")
        #expect(glows(keepClear: nil, rangeHulls: 12).allSatisfy { $0 == nil })
        #expect(glows(isGhost: true, rangeHulls: 12).allSatisfy { $0 == nil })
        #expect(BoatStyle.standard.glowRangeHulls == RightOfWayGlyph.defaultRangeHulls)
        #expect(BoatStyle.standard.glowFullHulls < BoatStyle.standard.glowRangeHulls)
    }

    /// Mark-room glows as right of way does (#386), and only within the glow range: the boat owing room red, the
    /// boat owed it green, nothing past the range however the umpire holds the pair.
    @Test func markRoomGlowsWithinRangeOnly() {
        let positions = [Vec2(0, 0), Vec2(0, 12), Vec2(0, 32)]
        func glows(_ keepClear: [RightOfWay?]) -> [RightOfWayGlyph?] {
            GlowSelection.glows(keepClear: keepClear, positions: positions, me: 0, isGhost: false, rangeHulls: 6,
                                fullHulls: 2, hullLength: 4).map { $0?.kind }
        }
        // Seat 1 is 3 hulls off, seat 2 8 hulls off: past a 6-hull range.
        #expect(glows([nil, RightOfWay(keepClear: 1, rule: .givingMarkRoom),
                       RightOfWay(keepClear: 2, rule: .givingMarkRoom)]) == [nil, .hasRight, nil])
        #expect(glows([nil, RightOfWay(keepClear: 0, rule: .tackingInTheZone),
                       RightOfWay(keepClear: 0, rule: .tackingInTheZone)]) == [nil, .giveWay, nil])
    }

    /// A practice fleet with seat 1 `hulls` hull lengths from you (seat 0) and the rest far off, the pair's relation
    /// `relation`, drawn by a fresh `RuleCueLayer`: the layer, and seat 1's halo as her `BoatNode` draws the glow
    /// the layer gives her (nil while hidden), as the scene sets it.
    static func cues(relation: RightOfWay, hulls: Double, style: BoatStyle = .standard)
        -> (layer: RuleCueLayer, halo: (colour: UIColor, alpha: CGFloat)?) {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let base = driver.currentFrame
        let hull = driver.boatClass.hull.length
        var boats = base.boats
        boats[1].position = boats[0].position + Vec2(0, hulls * hull)
        for seat in boats.indices.dropFirst(2) { boats[seat].position = boats[0].position + Vec2(1000 * Double(seat), 0) }
        var keepClear = [RightOfWay?](repeating: nil, count: boats.count)
        keepClear[1] = relation
        let frame = TickFrame(tick: base.tick, boats: boats, standings: base.standings, wind: base.wind, isOver: false,
                              keepClear: keepClear)
        let world = RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: 0, previous: frame,
                                current: frame, alpha: 1)
        let layer = RuleCueLayer(pointsPerMeter: 8)
        layer.update(world, calls: RuleCallLines(), style: style, px: 0.5, rotation: 0)
        let node = BoatNode(boat: boats[1], isMine: false, color: .red, boatClass: driver.boatClass, pointsPerMeter: 8,
                            style: style)
        node.setRightOfWayGlow(layer.glows[1], style: style)
        return (layer, node.shownRightOfWayHalo)
    }

    /// The node hands its colours back in a colour space of its own: compared by 8-bit components.
    static func rgb(_ colour: UIColor) -> [Int] {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    /// #517: another boat taking a penalty (21.2) glows orange to you: the right-of-way halo, shown, tinted
    /// `CuePalette.orange` (not green, not hidden); nothing else is drawn for her, no arc and no marks.
    @Test func boatTakingAPenaltyGlowsOrangeToAnotherBoat() throws {
        let (layer, shown) = Self.cues(relation: RightOfWay(keepClear: 1, rule: .takingAPenalty), hulls: 1)
        #expect(layer.glows.map { $0?.kind } == [nil, .takingAPenalty, nil, nil])
        #expect(layer.summary == "glows=1 lines=0 arc=0" && layer.marksSummary == "none")
        let halo = try #require(shown, "her halo is hidden")
        #expect(Self.rgb(halo.colour) == Self.rgb(CuePalette.orange.uiColor), "\(halo.colour)")
        #expect(Self.rgb(halo.colour) != Self.rgb(CuePalette.hasRightGreen.uiColor))
    }

    /// #517: her own view shows the other boat red, with no orange.
    @Test func boatTakingAPenaltySeesTheOtherBoatRed() throws {
        let (layer, shown) = Self.cues(relation: RightOfWay(keepClear: 0, rule: .takingAPenalty), hulls: 1)
        #expect(layer.glows.map { $0?.kind } == [nil, .giveWay, nil, nil])
        let halo = try #require(shown)
        #expect(Self.rgb(halo.colour) == Self.rgb(CuePalette.giveWayRed.uiColor), "\(halo.colour)")
        #expect(Self.rgb(halo.colour) != Self.rgb(CuePalette.orange.uiColor))
    }

    /// #517: a boat returning to start (21.1) keeps the green glow.
    @Test func returningBoatGlowsGreen() throws {
        let (layer, shown) = Self.cues(relation: RightOfWay(keepClear: 1, rule: .returningToStart), hulls: 1)
        #expect(layer.glows[1]?.kind == .hasRight)
        let halo = try #require(shown)
        #expect(Self.rgb(halo.colour) == Self.rgb(CuePalette.hasRightGreen.uiColor), "\(halo.colour)")
    }

    /// #517: the orange glow is as strong as the green one, the glow's intensity of `glowMaxAlpha`: partly there
    /// 2.5 hulls off, `glowMaxAlpha` at 1 hull, none past the range.
    @Test func orangeGlowAlphaFollowsGlowIntensity() throws {
        var style = BoatStyle.standard
        style.glowMaxAlpha = 0.6
        let penalised = RightOfWay(keepClear: 1, rule: .takingAPenalty)
        let far = Self.cues(relation: penalised, hulls: 2.5, style: style)
        let intensity = GlowSelection.fadeIn(hulls: 2.5, rangeHulls: style.glowRangeHulls, fullHulls: style.glowFullHulls)
        #expect(intensity > 0 && intensity < 1, "\(intensity)")
        #expect(abs((far.layer.glows[1]?.intensity ?? -1) - intensity) < 1e-9)
        // SpriteKit keeps alpha as a Float.
        let farHalo = try #require(far.halo, "her halo is hidden")
        #expect(abs(farHalo.alpha - CGFloat(intensity * 0.6)) < 1e-6, "\(farHalo.alpha)")
        let green = Self.cues(relation: RightOfWay(keepClear: 1, rule: .windwardLeeward), hulls: 2.5, style: style)
        #expect(green.halo?.alpha == farHalo.alpha, "as the green glow at the same distance")
        let near = try #require(Self.cues(relation: penalised, hulls: 1, style: style).halo)
        #expect(abs(near.alpha - 0.6) < 1e-6, "\(near.alpha)")
        #expect(Self.cues(relation: penalised, hulls: style.glowRangeHulls + 1, style: style).halo == nil)
    }

    /// The glow fades in from nothing at the range's edge to full at the full distance, easing at both ends, and
    /// stays full inside it.
    @Test func glowFadesInWithDistance() {
        func fade(_ hulls: Double) -> Double { GlowSelection.fadeIn(hulls: hulls, rangeHulls: 6, fullHulls: 2) }
        #expect(fade(7) == 0 && fade(6) == 0)
        #expect(fade(2) == 1 && fade(0.5) == 1)
        #expect(abs(fade(4) - 0.5) < 1e-9, "halfway is half")
        let steps = stride(from: 6.0, through: 2.0, by: -0.25).map(fade)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 }, "never dims as she nears: \(steps)")
        // A range no wider than the full distance is a switch, not a fade.
        #expect(GlowSelection.fadeIn(hulls: 3, rangeHulls: 2, fullHulls: 2) == 0)
        #expect(GlowSelection.fadeIn(hulls: 1, rangeHulls: 2, fullHulls: 2) == 1)
    }

    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// The Turn countdown is live: its text updates in place, it never expires or goes stale, a rule call replaces it
    /// for its seconds and it then shows again, and it comes down when the turn is done.
    @Test func livePenaltyNoticeUpdatesInPlaceAndReturnsAfterARuleCall() {
        var slot = NoticeSlot()
        slot.setLive(.penalty, text: "Turn · 11s / 26s", at: Self.at(0))
        let first = slot.current(at: Self.at(0))
        #expect(first?.kind == .penalty && first?.isLive == true)
        slot.setLive(.penalty, text: "Turn · 10s / 25s", at: Self.at(1))
        let updated = slot.current(at: Self.at(1))
        #expect(updated?.text == "Turn · 10s / 25s" && updated?.id == first?.id)
        #expect(slot.current(at: Self.at(60))?.kind == .penalty, "never expires while set")

        slot.post(.ruleCall, "a call", at: Self.at(61))
        #expect(slot.current(at: Self.at(61))?.kind == .ruleCall)
        slot.setLive(.penalty, text: "Turn · 5s / 20s", at: Self.at(62))
        #expect(slot.current(at: Self.at(62))?.kind == .ruleCall)
        let back = slot.current(at: Self.at(61 + NoticeTable.rule(.ruleCall).seconds + 30))
        #expect(back?.kind == .penalty && back?.text == "Turn · 5s / 20s", "waits, never stale, then shows again")

        slot.setLive(.penalty, text: nil, at: Self.at(100))
        #expect(slot.current(at: Self.at(100)) == nil)
    }
}
