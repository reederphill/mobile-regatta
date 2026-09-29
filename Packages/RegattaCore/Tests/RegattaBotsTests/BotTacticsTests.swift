import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #290: a tactician reads the pressure over the race area (`SeatView.PressureMap`) and weighs it against the shift.
@Suite struct BotTacticsTests {
    /// Seat 0's view in `BotBrainTests.beatingRace`, on starboard up the first beat, with its pressure map made
    /// from `pressure`: the pressure at a place from how far right of her it is, and how far up the course, metres.
    /// No puff or lull on the water, so the pressure alone is what she reads.
    static func view(seed: UInt64 = 290, _ pressure: (_ across: Double, _ along: Double) -> Pressure) throws -> SeatView {
        let race = try BotBrainTests.beatingRace(seed: seed, offGroove: 0)
        var view = race.seatView(for: 0)
        let area = race.course.raceArea
        let columns = SeatView.PressureMap.gridColumns, rows = SeatView.PressureMap.gridRows
        let right = Vec2.heading(area.axis).rightPerp, up = Vec2.heading(area.axis)
        var nodes: [Pressure] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = SeatView.PressureMap.position(column: column, row: row, area, columns, rows) - view.own.position
                nodes.append(pressure(offset.dot(right), offset.dot(up)))
            }
        }
        view.puffs = []
        view.pressure = SeatView.PressureMap(area: area, tick: view.tick, columns: columns, rows: rows, nodes: nodes)
        return view
    }

    /// The tack `profile`'s bot beats on from starboard in `view`, the shift neutral: the wind she reads is the
    /// course's own direction, turning no way.
    static func tack(_ profile: BotProfile, _ view: SeatView) -> Tack {
        var brain = BotBrain(style: BotStyle(skill: 0.9, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1),
                             profile: profile)
        brain.observe(view.own, view)
        brain.senses.direction = view.course.axis
        brain.senses.directionRate = 0
        return brain.upwindTack(view.own, view, planned: .starboard)
    }

    /// Given a clear pressure side and a neutral shift, the tactician heads for the pressure: on starboard, sailing
    /// left, with more pressure to the right she tacks onto port; with it on the left she holds on. The baseline
    /// never reads it, and nor does she tack in even pressure.
    @Test func goesToThePressure() throws {
        let area = try BotBrainTests.beatingRace(seed: 290, offGroove: 0).course.raceArea
        let right = try Self.view { across, _ in Pressure(factor: 1 + 0.3 * across / area.halfWidth, turn: 0) }
        let left = try Self.view { across, _ in Pressure(factor: 1 - 0.3 * across / area.halfWidth, turn: 0) }
        let even = try Self.view { _, _ in Pressure(factor: 1, turn: 0) }
        #expect(Self.tack(.tactician, even) == .starboard)
        #expect(Self.tack(.tactician, right) == .port)
        #expect(Self.tack(.tactician, left) == .starboard)
        #expect(Self.tack(.baseline, right) == .starboard)
    }

    /// A pressure lane along the wind to her right, 300 m wide and as strong as the conditions draw one, its near edge
    /// 100 m off, the shift neutral: the wind in it veers on one edge and backs on the other (CONTEXT.md, "Pressure
    /// lane"). On starboard, the tactician tacks onto port to enter it when its near edge backs, lifting her on port;
    /// when that edge veers, which would head her on port, she holds on, though the lane's pressure is the same.
    @Test func takesTheLiftingEdge() throws {
        func lane(backingNearEdge: Bool) throws -> SeatView {
            try Self.view { across, _ in
                let d = (across - 250) / 150
                guard abs(d) < 1 else { return Pressure(factor: 1, turn: 0) }
                let f = (1 - d * d) * (1 - d * d)
                // The bend peaks at 6°, where f·d does, at d = 1/√5.
                let bend = deg2rad(6) * f * d / 0.2862
                return Pressure(factor: 1 + 0.15 * f, turn: backingNearEdge ? bend : -bend)
            }
        }
        let lifting = try lane(backingNearEdge: true)
        let heading = try lane(backingNearEdge: false)
        // Near edge: d < 0, so a backing (negative) turn there with `bend` as it is.
        let nearEdge = lifting.pressure!.sample(at: lifting.own.position + Vec2.heading(lifting.course.axis).rightPerp * 180)!
        #expect(nearEdge.turn < 0 && nearEdge.factor > 1)
        #expect(Self.tack(.tactician, lifting) == .port)
        #expect(Self.tack(.tactician, heading) == .starboard)
        #expect(Self.tack(.baseline, lifting) == .starboard)
    }
}
